# Runbook: desbloquear un despliegue

**Alcance:** diagnosticar y recuperar un despliegue de `doc-service` o
`extraction-worker` que quedó a medias en el stack Docker Compose de `infra`.

**Aclaración importante:** este proyecto **no** usa Kubernetes, Swarm ni un
bloqueo distribuido de despliegue. No hay un estado persistente de "deployment
en curso". El despliegue es `docker compose` y el estado real es el de los
contenedores. `infra/scripts/deploy-doc-service.sh` fija el smoke en
`https://api.localhost:8543`; si cambió `TRAEFIK_HTTPS_PORT`, el script puede
fallar en el smoke aunque el servicio esté sano. Un "deployment bloqueado"
significa una de estas cosas:

- `infra/scripts/deploy-doc-service.sh <tag>` falló en `pull`, `up`, `healthy`
  o en el smoke de `/healthz`.
- `docker compose up -d` dejó un servicio en `Created`, `Restarting`,
  `unhealthy` o `Exited`.
- El servicio está `healthy` pero la API devuelve 404/502 a través de Traefik.
- El contenedor no arranca por un puerto ocupado, un secreto faltante o una
  imagen que no existe.
- Un workflow de GitHub Actions de build/publicación falló; eso no es un
  deployment de este stack y no se repara aquí.

**Disparador**

- El deploy de una etiqueta nueva no termina.
- Un servicio no llega a `healthy` después de `up -d`.
- El smoke del deploy falla.
- Se necesita volver a la etiqueta anterior.

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

HTTPS_PORT="$(awk -F= '/^TRAEFIK_HTTPS_PORT=/{print $2}' infra/.env)"
HTTPS_PORT="${HTTPS_PORT:-8543}"
HTTP_PORT="$(awk -F= '/^TRAEFIK_HTTP_PORT=/{print $2}' infra/.env)"
HTTP_PORT="${HTTP_PORT:-8088}"
```

## 1. Capturar el estado exacto

```bash
"${C[@]}" ps -a

for svc in mongo redis-streams minio traefik doc-service extraction-worker; do
  cid="$("${C[@]}" ps -q "$svc" 2>/dev/null || true)"
  if [[ -z "$cid" ]]; then
    printf '%-20s no creado\n' "$svc"
    continue
  fi
  docker inspect -f \
    '{{.Name}} state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} image={{.Config.Image}}' \
    "$cid"
done
```

Guarde esta salida como evidencia. No reinicie nada todavía: primero identifique
la etapa que falló.

## 2. Leer el error real

```bash
"${C[@]}" logs --tail=200 --no-color doc-service
"${C[@]}" logs --tail=200 --no-color extraction-worker
"${C[@]}" logs --tail=100 --no-color traefik
```

Clasifique el fallo:

| Síntoma | Causa probable | Acción |
|---|---|---|
| `pull access denied`, `manifest unknown`, `not found` | Etiqueta inexistente o imagen no publicada | Verifique la etiqueta y el registro; vuelva a la etiqueta anterior. |
| `port is already allocated` | Puerto ocupado en el host | Libere el puerto o cambie `TRAEFIK_HTTP_PORT`/`TRAEFIK_HTTPS_PORT`. |
| `no such file or directory` en un secreto | Falta un archivo en `infra/secrets/` | Restaure el secreto con `infra/scripts/bootstrap.sh`; no lo invente. |
| `permission denied` al socket de Docker | `DOCKER_GID` incorrecto | Exporte el GID real y recree Traefik. |
| `unhealthy` con `/healthz` fallando | Dependencia caída o configuración inválida | Revise Mongo/Redis/MinIO y los logs del servicio. |
| `Restarting` en bucle | Crash de arranque | Lea los logs; no lo deje en bucle. |
| `404` o `502` por Traefik | Ruta/label o backend no listo | Revise labels, red y salud del backend. |

## 3. Verificar la imagen y la etiqueta

```bash
grep -E '^(DOC_SERVICE_IMAGE|DOC_SERVICE_TAG|EXTRACTION_WORKER_IMAGE|EXTRACTION_WORKER_TAG)=' infra/.env

DOC_IMAGE="$(awk -F= '/^DOC_SERVICE_IMAGE=/{print $2}' infra/.env)"
DOC_IMAGE="${DOC_IMAGE:-doc-service}"
DOC_TAG="$(awk -F= '/^DOC_SERVICE_TAG=/{print $2}' infra/.env)"
DOC_TAG="${DOC_TAG:-latest}"

docker image inspect "${DOC_IMAGE}:${DOC_TAG}" >/dev/null 2>&1 && \
  echo "imagen local: ${DOC_IMAGE}:${DOC_TAG}" || \
  echo "imagen ausente: ${DOC_IMAGE}:${DOC_TAG}"
```

Si la etiqueta es de GHCR y no está local:

```bash
docker pull "${DOC_IMAGE}:${DOC_TAG}"
```

Si `DOC_SERVICE_IMAGE` es una imagen local (por ejemplo `doc-service:local`), no
ejecute `docker pull`: no existe en un registro. Use la imagen ya construida y
`up -d --no-build`.

El worker no tiene una etiqueta fija en el `.env` de este checkout; el compose
usa `ghcr.io/alejo-basile/extraction-worker:latest` por defecto. Para desplegar
una etiqueta concreta, pase la variable en el entorno del comando:

```bash
EXTRACTION_WORKER_TAG="<tag>" "${C[@]}" pull extraction-worker
EXTRACTION_WORKER_TAG="<tag>" "${C[@]}" up -d --no-deps --no-build extraction-worker
```

## 4. Verificar dependencias

Un `doc-service` sano necesita Mongo, Redis Streams y MinIO. Un worker sano
necesita Redis, Mongo y MinIO.

```bash
"${C[@]}" up -d mongo redis-streams minio

for svc in mongo redis-streams minio; do
  cid="$("${C[@]}" ps -q "$svc" 2>/dev/null || true)"
  [[ -n "$cid" ]] || { echo "$svc: no creado"; continue; }
  docker inspect -f \
    '{{.Name}} state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$cid"
done
```

Criterios:

- `mongo`: `healthy` y primario del replica set `rs0`.
- `redis-streams`: responde `PING`; si está en modo Sentinel, el maestro se
  resuelve por `myprimary`.
- `minio`: `/minio/health/live` responde 200.

Si una dependencia no está sana, corríjala antes de recrear la aplicación. Un
`up -d` de la aplicación sobre una dependencia caída solo produce otro
`unhealthy`.

## 5. Puertos y Traefik

```bash
ss -ltnp | grep -E ":(${HTTP_PORT}|${HTTPS_PORT})\b" || true
```

Si el puerto está ocupado, identifique el proceso y decida:

- Liberar el puerto, o
- Cambiar `TRAEFIK_HTTP_PORT`/`TRAEFIK_HTTPS_PORT` en `infra/.env` y recrear
  Traefik:
  ```bash
  "${C[@]}" up -d --no-deps --force-recreate traefik
  ```

Verifique el acceso a `doc-service` por Traefik:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
  --resolve "api.localhost:${HTTPS_PORT}:127.0.0.1" \
  "https://api.localhost:${HTTPS_PORT}/healthz"

curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve "api.localhost:${HTTP_PORT}:127.0.0.1" \
  "http://api.localhost:${HTTP_PORT}/healthz"
```

El primero debe ser `200`; el segundo debe ser `301` o `308` (redirección a
HTTPS). Si el primero es `404`, revise que el contenedor de `doc-service` esté
en la red `infra_internal`, que Traefik lo descubra y que las labels
`traefik.enable=true` estén presentes:

```bash
DOC_CID="$("${C[@]}" ps -q doc-service)"
docker inspect -f '{{json .NetworkSettings.Networks}}' "$DOC_CID"
docker inspect -f '{{index .Config.Labels "traefik.enable"}}' "$DOC_CID"
```

Si Traefik no puede hablar con el socket de Docker, el label no se descubre.
Compruebe el GID:

```bash
stat -c '%g' /var/run/docker.sock
TRAEFIK_CID="$("${C[@]}" ps -q traefik)"
docker inspect -f '{{json .HostConfig.GroupAdd}}' "$TRAEFIK_CID"
```

El GID del host debe estar en `GroupAdd`. Si no coincide, exporte el GID correcto
y recree Traefik con `--force-recreate`.

## 6. Recrear la aplicación

Solo después de corregir la causa:

```bash
"${C[@]}" up -d --no-deps --no-build doc-service
```

Si el contenedor quedó en un estado inconsistente o con la imagen anterior:

```bash
"${C[@]}" up -d --no-deps --no-build --force-recreate doc-service
```

Espere a `healthy`:

```bash
for _ in $(seq 1 60); do
  CID="$("${C[@]}" ps -q doc-service)"
  STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CID")"
  printf 'doc-service: %s\n' "$STATUS"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done
```

Repita para el worker:

```bash
"${C[@]}" up -d --no-deps --no-build extraction-worker

for _ in $(seq 1 60); do
  CID="$("${C[@]}" ps -q extraction-worker)"
  STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CID")"
  printf 'extraction-worker: %s\n' "$STATUS"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done
```

## 7. Verificación funcional

```bash
curl -fsS "https://api.localhost:${HTTPS_PORT}/healthz" \
  --resolve "api.localhost:${HTTPS_PORT}:127.0.0.1" -k

"${C[@]}" exec -T extraction-worker \
  curl -fsS http://localhost:8081/readyz

"${C[@]}" ps -a
```

Si el cambio tocó el camino de documentos, ejecute el smoke del proyecto desde
`platform-services`:

```bash
./tests/e2e/run.sh smoke
```

El smoke no borra volúmenes y no apaga un stack que ya estaba corriendo. Si el
test requiere un stack limpio, use `tests/e2e/ci/smoke.sh --ci` solo en un
entorno de CI o en un stack desechable.

Criterios de éxito:

- `doc-service` y `extraction-worker` están `healthy`.
- `/healthz` responde 200 por Traefik.
- `/readyz` del worker reporta `ok` para Redis, MinIO y Mongo.
- La etiqueta o el digest del contenedor corresponde a la versión desplegada.
- El smoke pasa sin errores.

## 8. Rollback

### 8.1 Volver a la etiqueta anterior de `doc-service`

```bash
PREV_TAG="<tag-anterior>"
./infra/scripts/deploy-doc-service.sh "$PREV_TAG"
```

Si la imagen anterior ya está local y no se quiere volver a hacer `pull`:

```bash
DOC_SERVICE_TAG="$PREV_TAG" "${C[@]}" up -d --no-deps --no-build doc-service
```

### 8.2 Volver a la etiqueta anterior del worker

```bash
PREV_WORKER_TAG="<tag-anterior>"
EXTRACTION_WORKER_TAG="$PREV_WORKER_TAG" "${C[@]}" up -d --no-deps --no-build extraction-worker
```

### 8.3 Revertir un cambio de configuración

Si el fallo se produjo por un cambio en `infra/.env`:

1. Restaure la línea anterior del archivo con el editor, sin imprimir secretos.
2. Recrear los servicios afectados:
   ```bash
   "${C[@]}" up -d --no-deps --force-recreate traefik doc-service extraction-worker
   ```
3. Repita la verificación de la sección 7.

No ejecute `docker compose down -v`: borra volúmenes y datos. Para detener, use
`"${C[@]}" stop` o `"${C[@]}" down` sin `-v`.

## Registro de ensayo

| Fecha (UTC) | Autor | Entorno | Resultado | Evidencia | Firma |
|---|---|---|---|---|---|
| _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ | _pendiente_ |

## Referencias

- `infra/scripts/deploy-doc-service.sh`
- `infra/compose/docker-compose.yml`
- `infra/traefik/`
- `tests/e2e/run.sh`
- `tests/e2e/ci/smoke.sh`
