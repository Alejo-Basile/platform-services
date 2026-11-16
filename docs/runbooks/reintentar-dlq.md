# Runbook: reintentar mensajes de la DLQ

**Alcance:** inspeccionar la DLQ de `extraction-worker`, decidir si un mensaje
es reintentable y reemitirlo de forma controlada con `--replay-dlq`.

**Disparador**

- `XLEN stream:pdf-processing-dlq` mayor que 0 o alerta de DLQ no vacía.
- `--inspect-dlq` muestra mensajes acumulados.
- Un documento quedó en `EXTRACTION_FAILED` o `REJECTED` y se necesita saber si
  corresponde reintentar.

**No usar este runbook para**

- Errores de negocio del PDF (`PDF_CORRUPT`, `PDF_ENCRYPTED`, `PDF_NO_TEXT`,
  `PDF_TOO_LARGE`, `PDF_TOO_MANY_PAGES`, `PDF_OUTPUT_TOO_LARGE`). Reemitirlos
  produce el mismo fallo. Corrija el archivo o el límite, o cierre el caso.
- Mensajes con contrato inválido (`INVALID_CONTRACT`,
  `UNSUPPORTED_SCHEMA_VERSION`, `DLQ_SERIALIZE`). Corrija el productor o el
  worker; no reemita a ciegas.
- Borrar la DLQ o editar Mongo a mano.

## Preparación de la shell

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
```

El worker debe estar corriendo y con sus variables materializadas por el
entrypoint. **No** invoque el binario directamente con `docker compose exec`:
saltea el entrypoint y faltan `REDIS_URL`/`MONGO_WORKER_URI`. Use siempre
`sh /entrypoint.sh /usr/local/bin/extraction-worker ...`.

## 1. Inspeccionar la DLQ

```bash
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-dlq --limit 20
```

La salida incluye `stream`, `depth`, `oldest_age_secs`, `count_sampled` y
`entries`. Los campos relevantes de cada entrada son:

- `id`: id de la entrada en la DLQ.
- `document_id`, `object_key`, `correlation_id`.
- `error_code`, `error_kind`, `error_message`.
- `delivery_count`, `failed_at`.

El límite de inspección se recorta a 1000; use `--limit 1000` si necesita una
muestra mayor. Para una entrada concreta, filtre la salida:

```bash
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-dlq --limit 1000 |
  grep -n -B3 -A12 '"document_id": "DOC_ID"'
```

## 2. Consultar el documento en Mongo

```bash
DOC="DOC_ID"

mongo_eval "const d = db.documents.findOne({_id: '$DOC'});
printjson(d ? {
  status: d.status,
  failure_reason: d.failure_reason,
  object_key: d.object_key,
  txt_ref: d.txt_ref,
  updated_at: d.updated_at,
  history: d.history,
  status_history: d.status_history
} : null);"
```

Nota: `doc-service` escribe `history`; el worker escribe `status_history`. La
guía muestra ambos porque conviven en el documento. No "normalice" el campo a
mano.

## 3. Decidir

| Señal | Acción |
|---|---|
| `error_kind: transient` con dependencia ya recuperada (`MONGO_IO`, `MONGO_TIMEOUT`, `S3_IO`, `S3_TIMEOUT`, `REDIS_IO`, `REDIS_TIMEOUT`, `JOB_TIMEOUT`, `TMP_CREATE`) | Reintentar con `--replay-dlq` después de verificar la dependencia. |
| `MAX_ATTEMPTS_EXCEEDED` | Verificar la causa base; si ya está corregida, reintentar. |
| `error_kind: business` (`PDF_CORRUPT`, `PDF_ENCRYPTED`, `PDF_NO_TEXT`, `PDF_TOO_LARGE`, `PDF_TOO_MANY_PAGES`, `PDF_OUTPUT_TOO_LARGE`) | No reintentar. Corregir el PDF o el límite, o cerrar el caso. |
| `INVALID_CONTRACT`, `UNSUPPORTED_SCHEMA_VERSION`, `DLQ_SERIALIZE` | No reintentar. Corregir el productor o el worker. |
| `S3_CONFIG`, `S3_AUTH`, `MONGO_CONFIG`, `MONGO_AUTH`, `REDIS_CONFIG`, `REDIS_PROTOCOL`, `CONTRACT_TRANSITION` | No reintentar hasta corregir credenciales, permisos o el bug. |
| Documento en `PROCESSING` | Replay directo: el comando lo pasa a `RETRYING` antes de reemitir. |
| Documento en `QUEUED` o `RETRYING` | Replay directo: ya es reclamable. |
| Documento en `EXTRACTION_FAILED` | No reemitir la entrada de DLQ. Use el endpoint de retry de `doc-service` (sección 5), que lo pasa a `RETRYING` y lo encola. |
| Documento en `REJECTED`, `FAILED`, `COMPLETED` o `UPLOAD_EXPIRED` | No reemitir: es terminal. Triage manual; si el cliente necesita reprocesar, cree un documento nuevo. |
| Documento en `COMPENSATING` | No reemitir: el replay lo omite. Escale y revise la compensación. |

Regla práctica: si el mismo PDF volvería a fallar por su contenido, el replay no
es la herramienta. El replay sirve para un fallo transitorio de infraestructura
o para un mensaje que se perdió después de un reset de estado.

## 4. Replay controlado

### 4.1 Ensayo sin escritura

```bash
DOC="DOC_ID"

"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --replay-dlq \
  --document-id "$DOC" \
  --dry-run \
  --by "${USER:-operador}"
```

Criterios:

- `dry_run: true`.
- `processed` mayor que 0 para el documento elegido.
- Cada resultado es `would_replay` si el mensaje cumple el contrato, o
  `skipped` si el mensaje no se puede deserializar o el schema no es soportado.
- El `--dry-run` **no** consulta Mongo: no valida el estado del documento. La
  validación de estado se hace en la sección 2 y en la tabla de la sección 3
  antes del replay real. Si el estado no es reclamable, el replay real lo
  informará como `skipped` con `reason: "estado_no_reclamable"`.

### 4.2 Replay real

```bash
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --replay-dlq \
  --document-id "$DOC" \
  --by "${USER:-operador}"
```

El comando es atómico en Redis: agrega la entrada al stream principal, elimina
la entrada de la DLQ, registra el id en el hash de idempotencia y escribe la
auditoría. Si el reset de Mongo ocurre pero Redis falla, la entrada sigue en la
DLQ y el documento queda en `RETRYING`; repetir el comando lo recupera.

Opciones válidas:

- `--document-id <id>`: alcance por documento.
- `--error-code <CODE>`: alcance por código (por ejemplo, solo
  `MAX_ATTEMPTS_EXCEEDED`).
- `--limit <n>`: máximo de entradas procesadas; se recorta a 10000.
- `--by <nombre>`: queda en la auditoría.
- `--all`: reemite todo lo que coincida. **No usar sin aprobación explícita y
  una ventana definida**; puede reemitir errores de negocio.
- `--no-reset-state`: omite el reset de estado. No es la ruta normal; puede
  reemitir mensajes cuyo documento ya no es reclamable. No usar sin revisar el
  caso.

## 5. Caso especial: documento en EXTRACTION_FAILED

El replay omite documentos que no sean `PROCESSING`, `QUEUED` o `RETRYING`.
Para un documento en `EXTRACTION_FAILED`, use el endpoint interno de retry:

```bash
DOC="DOC_ID"

"${C[@]}" exec -T -e P4_DOC="$DOC" doc-service sh -c '
  wget -qO- \
    --header="X-Internal-Token: $INTERNAL_TOKEN" \
    --header="Content-Type: application/json" \
    --post-data="{}" \
    "http://localhost:8080/internal/documents/$P4_DOC/retry"
'
```

El endpoint acepta `EXTRACTION_FAILED → RETRYING` y reencola; si el documento ya
está en `RETRYING`, solo reencola. No aplica a `PROCESSING` (responde 409). La
entrada antigua de la DLQ queda como evidencia; no la reemita después del retry
para evitar un duplicado.

## 6. Verificar

```bash
DOC="DOC_ID"

# La profundidad de la DLQ debe bajar.
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-dlq --limit 20

# El documento debe avanzar.
mongo_eval "const d = db.documents.findOne({_id: '$DOC'});
printjson({status: d.status, txt_ref: d.txt_ref, updated_at: d.updated_at});"

# El nuevo mensaje debe estar en el stream o en la PEL.
"${C[@]}" exec -T extraction-worker \
  sh /entrypoint.sh /usr/local/bin/extraction-worker \
  --inspect-pel
```

Criterios de éxito:

- `depth` baja en la cantidad reemitida.
- El documento sale de `RETRYING` y llega a `PROCESSING` y luego a `COMPLETED`
  (o a un estado terminal con causa).
- Si termina en `COMPLETED`, `txt_ref` apunta a un objeto existente en
  `extracted-txt`.
- La auditoría registra la operación:

```bash
"${C[@]}" exec -T redis-streams sh -c '
  PW=$(cat /run/secrets/redis_streams_password)
  redis-cli -a "$PW" --no-auth-warning \
    XREVRANGE stream:pdf-processing-dlq-replay + - COUNT 5
'
```

## Rollback

El replay no se "deshace": el mensaje ya está en el stream principal. Si el
replay fue un error:

1. No borre la entrada de auditoría ni el hash de idempotencia.
2. Si el documento quedó en `RETRYING` y no debe procesarse, use el cancel de
   `doc-service` solo si el estado lo permite; `cancel` únicamente acepta
   `PENDING_UPLOAD`. Para otros estados, escale.
3. Si el reprocesamiento vuelve a fallar, el worker lo devolverá a la DLQ. No
   fuerce un bucle de replays: dos intentos fallidos con el mismo código son
   evidencia suficiente para escalar.

## Registro de ensayo

| Fecha (UTC) | Autor | Entorno | Resultado | Evidencia | Firma |
|---|---|---|---|---|---|
| _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ |

## Referencias

- `extraction-worker/docs/error-model.md`
- `extraction-worker/crates/worker/src/consumer/cli.rs`
- `extraction-worker/crates/worker/src/consumer/replay.rs`
- `extraction-worker/crates/worker/src/document_store.rs`
- `doc-service/internal/api/internal.go` (`retry`, `cancel`)
