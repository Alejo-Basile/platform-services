# Runbook: restaurar MongoDB

**Alcance:** restaurar la base `documents` del stack `infra` desde un backup
`mongodump` verificado, sin tocar usuarios, contraseñas ni la configuración del
replica set.

**Disparador**

- Pérdida o corrupción de la base `documents` (volumen `infra_mongo-data`).
- Necesidad de volver a un punto anterior por una migración o un cambio fallido.
- Ensayo periódico de restore solicitado por operaciones.

**No usar este runbook para**

- Cambiar usuarios o roles de MongoDB. Para eso use `infra/scripts/bootstrap.sh`
  o el `init.js` del replica set.
- Restaurar `admin` o `local`: el backup contiene usuarios y el oplog. Un restore
  selectivo de `documents.*` evita sobrescribir credenciales.

## Seguridad y precondiciones

1. Detenga `doc-service` y `extraction-worker` antes de escribir en el primario.
   Son los únicos escritores de estado. El worker también escribe `.txt` en
   MinIO: no lo deje corriendo durante la ventana.
2. Verifique que el backup exista, tenga tamaño distinto de cero y se pueda
   restaurar en un contenedor limpio antes de tocar el primario.
3. No comparta ni imprima contraseñas. Los comandos leen las contraseñas desde
   `/run/secrets/` dentro de los contenedores.
4. Coordine una ventana breve: durante el restore, los documentos no avanzan y
   las subidas nuevas pueden quedar en `PENDING_UPLOAD` o `UPLOADED` hasta que
   `doc-service` vuelva.
5. No ejecute `--drop` sobre la base completa. Use `--nsInclude="documents.*"`.

## Preparación de la shell

Ejecute desde la raíz del workspace que contiene `infra/`, `doc-service/` y
`extraction-worker/`. Si abre la shell en `platform-services`, el bloque detecta
el directorio padre.

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

# El compose exige DOCKER_GID para el grupo del socket de Docker.
export DOCKER_GID="${DOCKER_GID:-$(stat -c '%g' /var/run/docker.sock)}"

PROJECT="${P4_COMPOSE_PROJECT:-infra}"
# El compose fija el nombre de la red de datos; no derive el nombre del proyecto.
DATA_NETWORK="${P4_DATA_NETWORK:-infra_data}"

C=(docker compose \
  -f infra/compose/docker-compose.yml \
  --env-file infra/.env \
  -p "$PROJECT" \
  --profile full)

# Verificación de que el stack está disponible.
"${C[@]}" ps --services
```

Helper de consulta a Mongo con la contraseña root desde el secreto del
contenedor:

```bash
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

## Procedimiento A: validar el backup en un contenedor limpio

Esta es la ruta recomendada para un ensayo. No escribe en el primario.

### A.1 Crear el backup

```bash
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="/tmp/mongo-backup-${STAMP}.archive"
BACKUP_HOST="/tmp/$(basename "$ARCHIVE")"

"${C[@]}" exec -T -e P4_ARCHIVE="$ARCHIVE" mongo sh -c '
  set -eu
  umask 077
  printf "uri: mongodb://%s@localhost:27017/?authSource=admin\npassword: %s\n" \
    "$MONGO_INITDB_ROOT_USERNAME" \
    "$(cat /run/secrets/mongo_initdb_root_password)" > /tmp/dump.yml
  mongodump \
    --config=/tmp/dump.yml \
    --oplog \
    --gzip \
    --archive="$P4_ARCHIVE"
  rm -f /tmp/dump.yml
'

"${C[@]}" cp "mongo:${ARCHIVE}" "$BACKUP_HOST"
ls -lh "$BACKUP_HOST"
```

El `--oplog` produce un backup consistente con el replica set. El archivo queda
en `/tmp` del host; muévalo a un almacenamiento seguro o bórrelo al terminar el
ensayo.

### A.2 Restaurar en un contenedor limpio

```bash
RESTORE_CONTAINER="infra-mongo-restore-test"
RESTORE_VOLUME="${PROJECT}_mongo-restore-test"
RESTORE_IMAGE="mongo:7.0"

docker volume create "$RESTORE_VOLUME" >/dev/null
docker network inspect "$DATA_NETWORK" >/dev/null

# Si quedó un contenedor de un ensayo anterior, retírelo primero.
if docker container inspect "$RESTORE_CONTAINER" >/dev/null 2>&1; then
  docker container rm -f "$RESTORE_CONTAINER" >/dev/null
fi

docker run -d \
  --name "$RESTORE_CONTAINER" \
  --network "$DATA_NETWORK" \
  -v "${RESTORE_VOLUME}:/data/db" \
  "$RESTORE_IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$RESTORE_CONTAINER" mongosh --quiet \
      --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1; then
    break
  fi
  sleep 1
done

docker cp "$BACKUP_HOST" "${RESTORE_CONTAINER}:/tmp/restore.archive"

docker exec "$RESTORE_CONTAINER" mongorestore \
  --gzip \
  --archive=/tmp/restore.archive \
  --oplogReplay
```

### A.3 Comparar el restore con el primario

En el contenedor de ensayo:

```bash
docker exec "$RESTORE_CONTAINER" mongosh --quiet --eval '
const c = db.getSiblingDB("documents").documents;
print("documentos=" + c.countDocuments({}));
printjson(c.aggregate([
  {$group: {_id: "$status", n: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
printjson(c.getIndexes().map(i => ({name: i.name, key: i.key})));
'
```

En el primario:

```bash
mongo_eval '
print("documentos=" + db.documents.countDocuments({}));
printjson(db.documents.aggregate([
  {$group: {_id: "$status", n: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
printjson(db.documents.getIndexes().map(i => ({name: i.name, key: i.key})));
'
```

Criterios de éxito:

- `documentos=` coincide entre el backup y el primario al momento del dump.
- La distribución por `status` coincide.
- Los índices incluyen `_id`, `status_1`, `updated_at_1` y `expires_at_1` (TTL).
- `mongorestore` termina con código 0 y sin errores de oplog.

### A.4 Limpiar el ensayo

```bash
docker container rm -f "$RESTORE_CONTAINER"
docker volume rm "$RESTORE_VOLUME"
rm -f "$BACKUP_HOST"
```

`docker volume rm` y `docker container rm` aquí solo afectan el ensayo, nunca el
volumen `infra_mongo-data`. No use `docker compose down -v`.

## Procedimiento B: recuperar el primario

Use esta ruta solo después de que el Procedimiento A haya validado el archivo y
exista una aprobación para la ventana.

### B.1 Detener escritores y crear un backup previo

```bash
"${C[@]}" stop doc-service extraction-worker

# Backup de seguridad del estado actual, por si el restore debe revertirse.
SAFETY_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFETY_ARCHIVE="/tmp/mongo-safety-${SAFETY_STAMP}.archive"
"${C[@]}" exec -T -e P4_ARCHIVE="$SAFETY_ARCHIVE" mongo sh -c '
  set -eu
  umask 077
  printf "uri: mongodb://%s@localhost:27017/?authSource=admin\npassword: %s\n" \
    "$MONGO_INITDB_ROOT_USERNAME" \
    "$(cat /run/secrets/mongo_initdb_root_password)" > /tmp/dump.yml
  mongodump --config=/tmp/dump.yml --oplog --gzip --archive="$P4_ARCHIVE"
  rm -f /tmp/dump.yml
'
"${C[@]}" cp "mongo:${SAFETY_ARCHIVE}" "/tmp/$(basename "$SAFETY_ARCHIVE")"
```

### B.2 Copiar y restaurar el backup elegido

```bash
RESTORE_FILE="/tmp/$(basename "$ARCHIVE")"
"${C[@]}" cp "$RESTORE_FILE" "mongo:/tmp/restore.archive"

"${C[@]}" exec -T mongo sh -c '
  set -eu
  umask 077
  printf "uri: mongodb://%s@localhost:27017/?authSource=admin\npassword: %s\n" \
    "$MONGO_INITDB_ROOT_USERNAME" \
    "$(cat /run/secrets/mongo_initdb_root_password)" > /tmp/restore.yml
  mongorestore \
    --config=/tmp/restore.yml \
    --gzip \
    --archive=/tmp/restore.archive \
    --nsInclude="documents.*" \
    --drop
  rm -f /tmp/restore.yml /tmp/restore.archive
'
```

`--nsInclude="documents.*"` restaura solo las colecciones de la base
`documents`. `--drop` elimina cada colección incluida antes de restaurarla; no
toca `admin`, `local` ni usuarios.

### B.3 Reiniciar servicios y reconciliar

```bash
"${C[@]}" start doc-service extraction-worker
"${C[@]}" ps -a

# Espere a que doc-service esté healthy.
for _ in $(seq 1 60); do
  STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$("${C[@]}" ps -q doc-service)")"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done
printf 'doc-service: %s\n' "$STATUS"

# Dispara una pasada del reconciliador.
"${C[@]}" exec -T doc-service sh -c '
  wget -qO- \
    --header="X-Internal-Token: $INTERNAL_TOKEN" \
    --post-data="" \
    http://localhost:8080/internal/reconcile
'
```

### B.4 Verificar

```bash
mongo_eval '
print("documentos=" + db.documents.countDocuments({}));
printjson(db.documents.aggregate([
  {$group: {_id: "$status", n: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
'

"${C[@]}" exec -T doc-service wget -qO- http://localhost:8080/healthz
"${C[@]}" exec -T extraction-worker curl -fsS http://localhost:8081/readyz
```

Criterios de éxito:

- `doc-service` queda `healthy` y `/healthz` responde 200.
- El worker responde `{"status":"ok"}` en `/readyz`.
- Los conteos y estados son los esperados para el punto de restauración.
- Los documentos `UPLOADED` o `QUEUED` atascados avanzan tras el reconcile, o
  quedan con una causa registrada en `failure_reason`.

## Procedimiento C: volumen nuevo o vacío

Use esta ruta solo si el volumen `infra_mongo-data` no existe o está vacío. Si
el volumen tiene datos, use el Procedimiento B.

```bash
"${C[@]}" stop doc-service extraction-worker

# Crea el volumen vacío si no existe y arranca mongod sin replica set inicializado.
"${C[@]}" up -d mongo

# Inicializa el replica set rs0 y los usuarios de aplicación.
# `mongo-init` usa MONGO_INITDB_ROOT_PASSWORD de .env; debe coincidir con
# infra/secrets/mongo_initdb_root_password.txt, que es el que usa mongod.
"${C[@]}" run --rm --no-deps mongo-init

# Espere a que el primario esté healthy.
for _ in $(seq 1 90); do
  CID="$("${C[@]}" ps -q mongo)"
  STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CID")"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done
printf 'mongo: %s\n' "$STATUS"

# Luego aplique el Procedimiento B.2 y B.3.
```

No borre un volumen existente para "empezar limpio". Si el volumen está
corrupto y `mongod` no arranca, deténgase y escale; la recuperación destructiva
requiere aprobación explícita y un backup verificado.

## Rollback

Si el restore del Procedimiento B deja el estado incorrecto:

1. Detenga otra vez `doc-service` y `extraction-worker`.
2. Restaure el backup de seguridad creado en B.1 con el mismo comando de B.2,
   apuntando `RESTORE_FILE` al archivo `mongo-safety-*.archive`.
3. Reinicie servicios y ejecute el reconcile de B.3.
4. Verifique conteos y estados.

Si `mongorestore` falla a mitad de la restauración, no reinicie escritores. El
backup de seguridad es la vía de vuelta.

## Registro de ensayo

Complete esta tabla solo después de ejecutar el runbook en un entorno de
pruebas. No invente fechas ni firmas.

| Fecha (UTC) | Autor | Entorno | Resultado | Evidencia | Firma |
|---|---|---|---|---|---|
| _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ |

## Referencias

- `infra/runbooks/restore-mongo.md`
- `infra/compose/docker-compose.yml` (servicios `mongo`, `mongo-init`, volúmenes)
- `infra/compose/mongo/init.js`
- `doc-service/internal/reconciler/reconciler.go` (`POST /internal/reconcile`)
