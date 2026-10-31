#!/usr/bin/env bash
# Utilidades compartidas por los arneses E2E de P4.
#
# No habilita opciones de shell ni imprime: cada script decide su `set` y su
# formato de salida. Se espera sourcear este archivo desde tests/e2e/.
#
# El script que lo sourcea debe definir, antes de llamar a las funciones que
# los usan:
#   REDIS_STREAM_KEY   stream_entries_for, stream_length, stream_delete
#   mongo_status()     wait_status
# y puede agregar archivos a COMPOSE_FILES (ver compose()).
# shellcheck shell=bash

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

if [[ -n "${P4_WORKSPACE_ROOT:-}" ]]; then
  WORKSPACE_ROOT="$P4_WORKSPACE_ROOT"
elif [[ -f "$PLATFORM_ROOT/../infra/compose/docker-compose.yml" ]]; then
  WORKSPACE_ROOT="$(cd "$PLATFORM_ROOT/.." && pwd)"
elif [[ -f "$PLATFORM_ROOT/infra/compose/docker-compose.yml" ]]; then
  WORKSPACE_ROOT="$PLATFORM_ROOT"
else
  printf '[e2e-lib] ERROR: no se encontro infra/ junto a platform-services\n' >&2
  exit 1
fi

INFRA_DIR="$WORKSPACE_ROOT/infra"
ENV_FILE="${P4_ENV_FILE:-$INFRA_DIR/.env}"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"
# BUILD_FILE y OVERRIDE_FILE los consumen los scripts que sourcean este archivo.
# shellcheck disable=SC2034
BUILD_FILE="$INFRA_DIR/compose/docker-compose.build.yml"
# shellcheck disable=SC2034
OVERRIDE_FILE="$PLATFORM_ROOT/tests/e2e/ci/compose.override.yml"
PROJECT="${P4_COMPOSE_PROJECT:-infra}"

# Imagen del cliente MinIO centralizada. `minio/mc` fue eliminada de Docker Hub
# en septiembre de 2026; se fija un digest inmutable del namespace oficial.
MC_IMAGE="${MC_IMAGE:-quay.io/minio/aistor/mc@sha256:0d52eb92083ad1e1ddbe1ba82e672a5ffde7c1c4f6dd20d5f3e198e0f4db7a11}"

# Los scripts que necesitan build/override agregan sus archivos a este array.
COMPOSE_FILES=(-f "$COMPOSE_FILE")

compose() {
  docker compose "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" -p "$PROJECT" "$@"
}

env_value() {
  local key="$1" default="${2:-}" value
  value="$(awk -v k="$key" '
    index($0, k "=") == 1 { value = substr($0, length(k) + 2) }
    END { print value }
  ' "$ENV_FILE")"
  printf '%s' "${value:-$default}"
}

# El script del contenedor va entre comillas simples a proposito: lo expande el
# `sh` remoto, no este shell.
# shellcheck disable=SC2016
redis_cli() {
  # La contrasena viaja por stdin y no por argv: asi no aparece en `ps` del host
  # (mismo criterio que infra/scripts/e2e-horizontal-scaling.sh, S6).
  env_value REDIS_STREAMS_PASSWORD | compose exec -T redis-streams sh -c '
    IFS= read -r P4_REDIS_PASSWORD || true
    if [ -r /run/secrets/redis_streams_password ]; then
      PW=$(cat /run/secrets/redis_streams_password)
    else
      PW=${P4_REDIS_PASSWORD:-$REDIS_STREAMS_PASSWORD}
    fi
    redis-cli -a "$PW" --no-auth-warning "$@"
  ' sh "$@" 2>/dev/null
}

redis_available() { redis_cli PING | grep -qx PONG; }

wait_redis() {
  local tries="${1:-60}" i
  for ((i = 1; i <= tries; i++)); do
    redis_available && return 0
    sleep 1
  done
  return 1
}

stream_entries_for() {
  local id="$1"
  redis_cli --raw XRANGE "$REDIS_STREAM_KEY" - + COUNT 10000 |
    awk -v id="$id" '
      /^[0-9]+-[0-9]+$/ { entry=$0; next }
      index($0, "\"document_id\":\"" id "\"") { print entry }
    '
}

stream_entry_for() {
  local entries
  entries="$(stream_entries_for "$1")" || return 1
  [[ -n "$entries" ]] || return 0
  printf '%s\n' "$entries" | awk 'NF { print; exit }'
}

stream_length() {
  redis_cli XLEN "$REDIS_STREAM_KEY" 2>/dev/null || echo 0
}

stream_delete() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  redis_cli XDEL "$REDIS_STREAM_KEY" "$entry" >/dev/null 2>&1 || true
}

wait_stream_entry() {
  local id="$1" tries="${2:-60}" entry="" i
  for ((i = 1; i <= tries; i++)); do
    entry="$(stream_entry_for "$id")"
    [[ -n "$entry" ]] && return 0
    sleep 1
  done
  return 1
}

wait_status() {
  local id="$1" expected="$2" tries="${3:-30}" status="" i
  for ((i = 1; i <= tries; i++)); do
    status="$(mongo_status "$id")"
    [[ "$status" == "$expected" ]] && return 0
    sleep 1
  done
  printf '  estado final: %s (esperado %s)\n' "${status:-MISSING}" "$expected" >&2
  return 1
}

wait_http() {
  local url="$1" resolve="$2" tries="${3:-60}" i
  for ((i = 1; i <= tries; i++)); do
    [[ "$(curl -sk --max-time 3 --resolve "$resolve" -o /dev/null -w '%{http_code}' "$url" || true)" == "200" ]] && return 0
    sleep 1
  done
  return 1
}

mongo_eval() {
  local js="$1" db="${P4_MONGO_DB:-${MONGO_DATABASE:-documents}}"
  # Las comillas simples son intencionales: $PW/$P4_* se expanden dentro del contenedor.
  # shellcheck disable=SC2016
  compose exec -T -e P4_JS="$js" -e P4_DB="$db" mongo sh -c '
    if [ -r /run/secrets/mongo_initdb_root_password ]; then PW=$(cat /run/secrets/mongo_initdb_root_password); else PW=$MONGO_INITDB_ROOT_PASSWORD; fi
    mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$PW" --authenticationDatabase admin "$P4_DB" --eval "$P4_JS"
  ' 2>/dev/null
}

mongo_get() {
  local id="$1" field="$2"
  mongo_eval "var d=db.documents.findOne({_id:'$id'}); print(d&&d.$field?d.$field:'')" | tail -n1
}

minio_exists() {
  local key="$1" user pass network
  local net_args=()
  [[ -n "$key" ]] || return 1
  user="$(env_value MINIO_ROOT_USER)"
  pass="$(env_value MINIO_ROOT_PASSWORD)"
  network="$(data_network || true)"
  [[ -n "$network" ]] && net_args=(--network "$network")
  require_mc_image || return 1
  MC_HOST_local="http://${user}:${pass}@minio:9000" docker run --rm "${net_args[@]}" -e MC_HOST_local "$MC_IMAGE" stat "local/${key}" >/dev/null 2>&1
}

data_network() {
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
    "$(compose ps -q minio 2>/dev/null)" 2>/dev/null | head -n1
}

minio_delete() {
  local key="$1"
  [[ -n "$key" ]] || return 0
  local user pass network
  local net_args=()
  user="$(env_value MINIO_ROOT_USER)"
  pass="$(env_value MINIO_ROOT_PASSWORD)"
  network="$(data_network || true)"
  [[ -n "$network" ]] && net_args=(--network "$network")
  # La limpieza nunca debe romper un caso, pero tampoco fallar en silencio.
  # El reconciliador puede borrar el objeto huerfano antes que nosotros; en ese
  # caso `mc` sale con error y no es un fallo de la limpieza.
  local out
  if ! out="$(MC_HOST_local="http://${user}:${pass}@minio:9000" \
    docker run --rm "${net_args[@]}" -e MC_HOST_local "$MC_IMAGE" \
    rm --force "local/${key}" 2>&1)"; then
    if [[ "$out" == *"Object does not exist"* ]]; then
      return 0
    fi
    printf '[e2e-lib] AVISO: no se pudo borrar local/%s de MinIO: %s\n' "$key" "$out" >&2
  fi
}

# Falla de forma visible si la imagen del cliente MinIO no se puede obtener.
# minio_delete descarta sus errores a proposito (es limpieza): sin este chequeo
# una imagen inexistente dejaria los tests en verde y objetos huerfanos.
require_mc_image() {
  docker image inspect "$MC_IMAGE" >/dev/null 2>&1 && return 0
  printf '[e2e-lib] descargando %s\n' "$MC_IMAGE" >&2
  if ! docker pull --quiet "$MC_IMAGE" >/dev/null; then
    printf '[e2e-lib] ERROR: no se pudo obtener la imagen de mc: %s\n' "$MC_IMAGE" >&2
    return 1
  fi
}
