# Guía: documento atascado en PROCESSING

**Alcance:** diagnosticar y resolver un documento del pipeline v2 que quedó en
`PROCESSING` más allá del tiempo esperado, y dar una acción concreta para los
demás estados no terminales.

**Público:** operaciones de guardia, con acceso de solo lectura a Mongo, Redis y
MinIO, y capacidad de reiniciar servicios del stack.

**Disparador**

- Un documento lleva más de 20 minutos en `PROCESSING`.
- El grupo `extraction-workers` tiene lag o mensajes pendientes que no avanzan.
- Un cliente reporta que su documento no termina de procesarse.
- El reconciliador registra documentos atascados en estados intermedios.

**Objetivo:** recuperar el procesamiento sin editar Mongo a mano, sin borrar
objetos y sin perder evidencia. Si no existe una operación soportada, escalar.

## 1. Flujo real del pipeline

1. `POST /api/v2/documents` crea el documento en `PENDING_UPLOAD` y devuelve una
   URL prefirmada.
2. El cliente sube el PDF al bucket `raw-pdfs`. El objeto se guarda como
   `raw-pdfs/<document_id>.pdf`; ese valor es el `object_key`.
3. MinIO envía el webhook a `doc-service`; el documento pasa a `UPLOADED`.
4. `doc-service` valida el objeto, lo pasa a `QUEUED` y publica un mensaje en
   `stream:pdf-processing` (grupo `extraction-workers`).
5. `extraction-worker` reclama el mensaje, pasa el documento a `PROCESSING`,
   descarga el PDF, extrae el texto, sube el artefacto textual al bucket
   `extracted-txt` (en este stack, `<document_id>.md`) y, si todo sale bien, lo
   pasa a `COMPLETED`.
6. Si falla la infraestructura, el mensaje queda en la PEL y se reintenta. Si se
   agota el presupuesto, va a `stream:pdf-processing-dlq` y el documento queda en
   `EXTRACTION_FAILED`. Si el PDF es inválido, el documento queda en `REJECTED`.

Estados reales del dominio: `PENDING_UPLOAD`, `UPLOADED`, `QUEUED`,
`PROCESSING`, `RETRYING`, `EXTRACTION_FAILED`, `COMPENSATING`, `COMPLETED`,
`FAILED`, `REJECTED`, `UPLOAD_EXPIRED`. Son terminales: `COMPLETED`, `FAILED`,
`REJECTED` y `UPLOAD_EXPIRED`.

## 2. Preparación de la shell

```bash
set -euo pipefail

if [[ -f infra/compose/docker-compose.yml ]]; then
  WORKSPACE_ROOT="$PWD"
elif [[ -f ../infra/compose/docker-compose.yml ]]; then
  WORKSPACE_ROOT="$(cd .. && pwd)"
else
  echo "ERROR: ejecute desde la raíz del workspace o desde platform-services" >&2
  exit 1
fi
cd "$WORKSPACE_ROOT"

export DOCKER_GID="${DOCKER_GID:-$(stat -c '%g' /var/run/docker.sock)}"
PROJECT="${P4_COMPOSE_PROJECT:-infra}"
REDIS_STREAM_KEY="${REDIS_STREAM_KEY:-stream:pdf-processing}"

C=(docker compose \
  -f infra/compose/docker-compose.yml \
  --env-file infra/.env \
  -p "$PROJECT" \
  --profile full)

mongo_eval() {
  local js="$1"
  local db="${MONGO_DATABASE:-documents}"
  "${C[@]}" exec -T -e P4_JS="$js" -e P4_DB="$db" mongo sh -c '
    PW=$(cat /run/secrets/mongo_initdb_root_password)
    mongosh --quiet \
      -u "$MONGO_INITDB_ROOT_USERNAME" \
      -p "$PW" \
      --authenticationDatabase admin \
      "$P4_DB" \
      --eval "$P4_JS"
  '
}

redis_cli() {
  "${C[@]}" exec -T redis-streams sh -c '
    PW=$(cat /run/secrets/redis_streams_password)
    redis-cli -a "$PW" --no-auth-warning "$@"
  ' sh "$@"
}

stream_entries_for() {
  local id="$1"
  redis_cli --raw XRANGE "$REDIS_STREAM_KEY" - + COUNT 10000 |
    awk -v id="$id" '
      /^[0-9]+-[0-9]+$/ { entry=$0; next }
      index($0, "\"document_id\":\"" id "\"") { print entry }
    '
}

mc_in_minio() {
  "${C[@]}" exec -T minio sh -c '
    mc alias set local http://127.0.0.1:9000 \
      "$MINIO_ROOT_USER" "$(cat /run/secrets/minio_root_password)" >/dev/null
    mc "$@"
  ' sh "$@"
}
```

## 3. Identificar el documento y su antigüedad

### 3.1 Conteo por estado

```bash
mongo_eval '
db.documents.aggregate([
  {$group: {_id: "$status", n: {$sum: 1}}},
  {$sort: {n: -1}}
]).forEach(printjson);
'
```

### 3.2 Documentos PROCESSING con más de 20 minutos

El reconciliador considera "atascado" a partir de 30 minutos. Esta guía empieza
a mirar a los 20 para tener margen de diagnóstico.

```bash
mongo_eval '
var cutoff = Date.now() - 20 * 60 * 1000;
db.documents.find({status: "PROCESSING"}).forEach(function (d) {
  var t = d.updated_at instanceof Date
    ? d.updated_at.getTime()
    : Date.parse(d.updated_at);
  if (isFinite(t) && t < cutoff) {
    printjson({
      id: d._id,
      status: d.status,
      updated_at: d.updated_at,
      age_min: Math.round((Date.now() - t) / 60000),
      object_key: d.object_key,
      txt_ref: d.txt_ref,
      failure_reason: d.failure_reason,
      correlation_id: d.correlation_id
    });
  }
});
'
```

`updated_at` puede ser un `Date` (lo escribe `doc-service`) o un string RFC 3339
(lo escribe el worker). La consulta normaliza ambos; no compare solo con
`$lt: ISODate(...)`, porque los documentos actualizados por el worker no
coincidirían. Si encuentra un documento con el tipo que no corresponde a su
último escritor, captúrelo como evidencia para el owner; no convierta el campo a
mano.

### 3.3 Un documento concreto

```bash
DOC="DOC_ID"

mongo_eval "var d = db.documents.findOne({_id: '$DOC'});
if (!d) { print('NO_EXISTE'); } else {
  printjson({
    id: d._id,
    status: d.status,
    created_at: d.created_at,
    updated_at: d.updated_at,
    object_key: d.object_key,
    txt_ref: d.txt_ref,
    failure_reason: d.failure_reason,
    correlation_id: d.correlation_id,
    schema_version: d.schema_version,
    history: d.history,
    status_history: d.status_history
  });
}"
```

`doc-service` escribe `history`; el worker escribe `status_history`. Los dos
campos pueden coexistir. No los "arregle" a mano.

## 4. Recolectar evidencia antes de actuar

Para el documento elegido, capture:

- `document_id`, `correlation_id`, `status`, `created_at`, `updated_at`.
- `object_key` y `txt_ref`.
- `failure_reason` si existe.
- Si el mensaje está en el stream, en la PEL o en la DLQ, con `id`,
  `delivery_count` e `idle_ms`.
- Estado del worker (`healthy`, `Restarting`, logs).
- Existencia del PDF en `raw-pdfs` y del artefacto indicado por `txt_ref` en
  `extracted-txt` (en este stack puede tener extensión `.md`).

No reinicie ni borre nada hasta tener esta foto. La evidencia es lo que permite
decidir entre reintentar y escalar.

## 5. Árbol de decisión para PROCESSING

### Paso 1: ¿el worker está sano?

```bash
"${C[@]}" ps -a extraction-worker
"${C[@]}" exec -T extraction-worker curl -fsS http://localhost:8081/readyz
"${C[@]}" logs --since 30m extraction-worker | grep -F "$DOC" || true
```

- Si `/readyz` falla o el contenedor está en `Restarting`/`Exited`, vaya al caso
  **A (worker caído)**.
- Si el worker está sano, continúe con la cola.

### Paso 2: ¿dónde está el mensaje?

```bash
# Resumen de la PEL, con document_id, consumidor, idle y entregas.
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-pel

# Grupos y lag.
redis_cli XINFO GROUPS "$REDIS_STREAM_KEY"

# Entradas del stream para este documento (hasta 10000).
stream_entries_for "$DOC"

# Detalle de la PEL: id, consumidor, idle y entregas (muestra de 100).
redis_cli XPENDING "$REDIS_STREAM_KEY" extraction-workers - + 100

# Si conoce el id del mensaje, lea sus campos.
MSG_ID="$(stream_entries_for "$DOC" | head -n1)"
[[ -n "$MSG_ID" ]] && redis_cli --raw XRANGE "$REDIS_STREAM_KEY" "$MSG_ID" "$MSG_ID"

# DLQ.
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-dlq --limit 1000 |
  grep -n -B3 -A12 "\"document_id\": \"$DOC\"" || true
```

`--inspect-pel` muestrea hasta 100 entradas de la PEL. Si el documento no aparece
en esa muestra, use `XPENDING` y `XRANGE` como arriba antes de concluir que el
mensaje no existe.

Casos:

**B. Mensaje en la PEL, con un consumidor y `idle_ms` bajo**

El worker lo tiene asignado y puede estar procesándolo. Espere, pero no más de
`WORKER_JOB_TIMEOUT_SECS` (300 s por defecto). Si el `idle_ms` ya supera
`WORKER_MIN_IDLE_MS` (600001 ms en compose) o el consumidor figura inactivo,
vaya al caso **C (consumidor muerto)**.

**C. Consumidor muerto o worker reiniciado**

```bash
redis_cli XINFO CONSUMERS "$REDIS_STREAM_KEY" extraction-workers
```

Un consumidor con `pending > 0` e `idle` mayor que `WORKER_DEAD_CONSUMER_MS`
(600001 ms) es un consumidor muerto. Reinicie el worker:

```bash
"${C[@]}" restart extraction-worker
```

Al arrancar, el worker hace `XREADGROUP` y `XAUTOCLAIM`; los mensajes de la PEL
se reclaman cuando superan `WORKER_MIN_IDLE_MS`. Espere y vuelva a revisar. No
use `XACK`, `XDEL` ni `XCLAIM` manualmente.

**D. Mensaje en el stream pero nunca entregado (lag > 0)**

El worker no está leyendo o el grupo no tiene consumidores. Verifique:

```bash
"${C[@]}" logs --since 30m extraction-worker | grep -Ei 'xreadgroup|xautoclaim|redis|error' || true
redis_cli XINFO GROUPS "$REDIS_STREAM_KEY"
```

Reinicie el worker si está sano pero no consume. Si el grupo no existe o el
stream fue recreado, escale: no recree el grupo a mano.

**E. Mensaje en la DLQ**

- Si el `error_kind` es `transient` y la dependencia ya está sana, siga el
  runbook `reintentar-dlq.md`. El replay mueve el documento de `PROCESSING` a
  `RETRYING` antes de reemitir.
- Si el `error_kind` es `business` (`PDF_CORRUPT`, `PDF_ENCRYPTED`,
  `PDF_NO_TEXT`, `PDF_TOO_LARGE`, `PDF_TOO_MANY_PAGES`,
  `PDF_OUTPUT_TOO_LARGE`), no reemita. El PDF volverá a fallar. Escale para
  cerrar el caso por la vía de compensación correspondiente.
- Si el código es de contrato (`INVALID_CONTRACT`,
  `UNSUPPORTED_SCHEMA_VERSION`, `DLQ_SERIALIZE`), no reemita. Escale al
  responsable del productor o del worker.

**F. No hay mensaje en stream, PEL ni DLQ**

Es el caso de un mensaje perdido: el estado quedó en `PROCESSING`, pero no hay
trabajo reclamable. Cuando `updated_at` ya supera el umbral de 30 minutos,
ejecute una vez el reconciliador manual de la sección 6. En este stack, el
reconciliador detecta el `PROCESSING` atascado y lo pasa a `RETRYING`; después,
siga la acción de retry de la sección 6. Verifique en Mongo y en stream/PEL que
el mensaje efectivamente exista: una respuesta `"reenqueued": true` por sí sola
no demuestra que se publicó ni que el documento terminó. Si el documento sigue
en `RETRYING`, no aparece una entrada reclamable o no llega a terminal, escale al
owner del pipeline con la evidencia. El endpoint de reconcile es global y puede
actuar sobre otros documentos; revise el alcance antes de ejecutarlo. No
actualice `status` en Mongo a mano y no invente un mensaje con `XADD`.

### Paso 3: ¿el PDF y el texto existen en MinIO?

```bash
# El object_key ya incluye el prefijo raw-pdfs/.
if [[ -n "${OBJECT_KEY:-}" ]]; then
  mc_in_minio stat "local/raw-pdfs/${OBJECT_KEY}" || true
else
  echo "object_key vacío: revise el documento en Mongo"
fi

# txt_ref es el nombre del objeto en extracted-txt, sin prefijo de bucket.
if [[ -n "${TXT_REF:-}" ]]; then
  mc_in_minio stat "local/extracted-txt/${TXT_REF}" || true
else
  echo "txt_ref vacío: el documento no tiene texto registrado"
fi
```

Casos:

- **PDF ausente:** el worker no puede procesar. No hay transición soportada desde
  `PROCESSING` por objeto faltante. Escale y conserve la evidencia.
- **PDF presente y el objeto indicado por `txt_ref` presente:** la extracción
  probablemente terminó, pero la actualización de estado no se aplicó. No borre
  el artefacto ni marque el documento a mano. Capture la evidencia y escale.
- **PDF presente y el objeto indicado por `txt_ref` ausente:** consistente con un procesamiento que no
  terminó. Continúe con el diagnóstico de worker/cola.

### Paso 4: ¿Mongo está sano y la transición es posible?

```bash
mongo_eval 'printjson(db.hello())'
mongo_eval 'printjson(db.documents.getIndexes().map(i => i.name))'
```

Si Mongo no responde o el worker registra `MONGO_IO`/`MONGO_TIMEOUT`, primero
recupere Mongo. Si el documento está en un estado que no admite la transición
esperada, no fuerce el estado: escale.

### Resumen de acciones para PROCESSING

| Hallazgo | Acción | ¿Requiere escalar? |
|---|---|---|
| Worker caído o `unhealthy` | Reiniciar el worker y esperar `XAUTOCLAIM` | No, si se recupera |
| Consumidor muerto | Reiniciar el worker | No, si se recupera |
| Lag > 0, worker sano | Revisar logs y reiniciar el worker | No, si se recupera |
| Mensaje en DLQ, error transitorio | Replay de DLQ según `reintentar-dlq.md` | No |
| Mensaje en DLQ, error de negocio | No reemitir; cerrar por compensación | Sí |
| Sin mensaje en stream/PEL/DLQ y `PROCESSING` > 30 min | Reconcile una vez; si queda `RETRYING`, usar retry y verificar stream/PEL | Si no hay reencolado o terminal |
| Artefacto textual presente con estado `PROCESSING` | No borrar; investigar la actualización de estado | Sí |
| PDF ausente | No hay transición soportada | Sí |
| Mongo caído | Recuperar Mongo y reintentar el diagnóstico | No, si se recupera |

## 6. Otros estados no terminales

| Estado | Qué revisar | Acción soportada |
|---|---|---|
| `PENDING_UPLOAD` | ¿El objeto existe en `raw-pdfs`? ¿Ya pasó el TTL? | Reconciler: si el objeto existe, lo pasa a `UPLOADED`; si no, lo expira. El operador puede cancelar solo en este estado. |
| `UPLOADED` | ¿El objeto existe? | Reconciler: si existe, reencola; si no, lo pasa a `FAILED` con `OBJECT_MISSING`. |
| `QUEUED` | ¿Hay mensaje en el stream? ¿El worker lee? | Reconciler reencola sin cambiar el estado. |
| `RETRYING` | ¿Hay mensaje en el stream/PEL/DLQ? | `POST /internal/documents/:id/retry` reencola. Si está en DLQ, aplique replay. |
| `EXTRACTION_FAILED` | Código de error y dependencia | `POST /internal/documents/:id/retry` lo pasa a `RETRYING` y reencola. No reemita además la entrada vieja de la DLQ. |
| `COMPENSATING` | Logs del worker y del reconciliador | No hay endpoint de operador. Escale. |
| `COMPLETED` | ¿Existe `txt_ref` en `extracted-txt`? | Si falta, es una inconsistencia; no lo marque a mano. Escale. |
| `FAILED`, `REJECTED`, `UPLOAD_EXPIRED` | Terminal | No cambie el estado. Si el cliente necesita reprocesar, cree un documento nuevo. |

### Disparar el reconciliador

Puede ejecutarse para `PENDING_UPLOAD`, `UPLOADED`, `QUEUED` y para un
`PROCESSING` cuyo `updated_at` supere el umbral de 30 minutos. En este último
caso, compruebe la transición a `RETRYING` y continúe con la acción de retry de
abajo. La operación es global, no limitada al `DOC`, y también puede ejecutar
otros barridos; no la confunda con una acción de solo lectura. No repara
`RETRYING` ni `COMPENSATING`.

```bash
"${C[@]}" exec -T doc-service sh -c '
  TOKEN=$(cat /run/secrets/internal_token)
  wget -qO- \
    --header="X-Internal-Token: $TOKEN" \
    --post-data="" \
    http://localhost:8080/internal/reconcile
'
```

### Reintentar `RETRYING` o `EXTRACTION_FAILED`

```bash
DOC="DOC_ID"

"${C[@]}" exec -T -e P4_DOC="$DOC" doc-service sh -c '
  TOKEN=$(cat /run/secrets/internal_token)
  wget -qO- \
    --header="X-Internal-Token: $TOKEN" \
    --header="Content-Type: application/json" \
    --post-data="{}" \
    "http://localhost:8080/internal/documents/$P4_DOC/retry"
'
```

Respuestas esperadas:

- 200 con `"reenqueued": true` si el encolado no devolvió error.
- 409 si el estado no es `RETRYING` ni `EXTRACTION_FAILED`.
- 503 si la transición se aplicó pero el encolado falló. El documento queda en
  `RETRYING`; reintente la operación.

> **`reenqueued: true` no garantiza que se publicó un mensaje.** El encolado
> deduplica por documento con `SETNX` sobre `dedup:<document_id>` y TTL de
> 10 minutos (`doc-service/internal/adapters/redis/queue.go:73-85`, `DedupTTL`).
> Si la marca sigue viva, `Enqueue` devuelve nil sin hacer `XADD`, y la API
> responde `reenqueued: true`. Es el caso de un reintento dentro de los 10
> minutos posteriores al encolado original.

Después de un 200, confirme que hay una entrada del documento en el stream o en
la PEL y que alcanza un estado terminal. Si no aparece en ninguno de los dos y el
documento sigue en `RETRYING`, revise si pasaron menos de 10 minutos desde el
encolado original: espere a que expire la marca de deduplicación y repita el
retry una sola vez. Si aun así no aparece, escale; no repita el endpoint
indefinidamente ni use `XADD` manual.

### Cancelar `PENDING_UPLOAD`

Solo aplica a `PENDING_UPLOAD`; cualquier otro estado devuelve 409.

```bash
DOC="DOC_ID"

"${C[@]}" exec -T -e P4_DOC="$DOC" doc-service sh -c '
  TOKEN=$(cat /run/secrets/internal_token)
  wget -qO- \
    --header="X-Internal-Token: $TOKEN" \
    --post-data="" \
    "http://localhost:8080/internal/documents/$P4_DOC/cancel"
'
```

## 7. Cómo confirmar que se resolvió

```bash
DOC="DOC_ID"

mongo_eval "var d = db.documents.findOne({_id: '$DOC'});
printjson(d ? {
  status: d.status,
  updated_at: d.updated_at,
  txt_ref: d.txt_ref,
  failure_reason: d.failure_reason,
  history: d.history,
  status_history: d.status_history
} : null);"

"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-pel

"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-dlq --limit 20

if [[ -n "${TXT_REF:-}" ]]; then
  mc_in_minio stat "local/extracted-txt/${TXT_REF}" || true
fi
```

Criterios:

- El documento llegó a `COMPLETED` y el objeto señalado por `txt_ref` existe en
  `extracted-txt`, o
- Llegó a un terminal con causa (`FAILED`, `REJECTED`, `UPLOAD_EXPIRED`) y la
  causa está registrada.
- La PEL y la DLQ no contienen el mensaje del documento.
- El worker y `doc-service` siguen sanos.

## 8. Cuándo reintentar y cuándo escalar

**Reintentar** solo cuando:

- El error es transitorio y la dependencia ya está sana.
- El documento está en `RETRYING` o `EXTRACTION_FAILED` y se usa el endpoint de
  retry.
- Hay una entrada de DLQ de un error transitorio y se sigue el runbook de DLQ.

**Escalar** cuando:

- Después de reconcile/retry, no aparece un mensaje reclamable o el documento no
  llega a un estado terminal.
- El error es de negocio o de contrato.
- El estado y los objetos de MinIO son inconsistentes.
- El documento está en `COMPENSATING`.
- `COMPLETED` no tiene `txt_ref`.
- Mongo no permite aplicar la transición esperada.

## 9. Acciones prohibidas

- No editar `status`, `updated_at`, `history` ni `status_history` con
  `mongosh`.
- No ejecutar `XACK`, `XDEL`, `XCLAIM` ni `XAUTOCLAIM` a mano. El worker es el
  único dueño de la PEL.
- No borrar objetos de `raw-pdfs` ni `extracted-txt` para "destrabar".
- No usar `--all` en el replay de DLQ sin aprobación.
- No ejecutar `docker compose down -v`.
- No marcar un documento como `COMPLETED` si el objeto señalado por `txt_ref` no
  existe.

## 10. Registro de ensayo

| Fecha (UTC) | Autor | Entorno | Resultado | Evidencia | Firma |
|---|---|---|---|---|---|
| _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ |

## Referencias

- `docs/evidencias/S4/S4-P4-05-runbook.txt` (borrador de origen)
- `doc-service/internal/domain/document.go` (estados y campos)
- `doc-service/internal/reconciler/reconciler.go` (reconciliación)
- `doc-service/internal/api/internal.go` (`retry`, `cancel`, `history`)
- `extraction-worker/crates/worker/src/consumer/runner.rs` (PEL, XAUTOCLAIM)
- `extraction-worker/crates/worker/src/document_store.rs` (transiciones)
- `extraction-worker/docs/error-model.md` (códigos y triage)
- `infra/compose/docker-compose.yml` (servicios y umbrales)
