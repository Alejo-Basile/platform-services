#!/usr/bin/env bash
# shellcheck disable=SC2016
# Smoke de Gate A para el E2E de P4.
#
# Uso:
#   tests/e2e/ci/smoke.sh          # valida el stack local ya levantado
#   tests/e2e/ci/smoke.sh --ci     # levanta el stack efimero y valida
#
# No borra volumenes: el workflow de CI se encarga del `down -v`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [[ -n "${P4_WORKSPACE_ROOT:-}" ]]; then
  WORKSPACE_ROOT="$P4_WORKSPACE_ROOT"
elif [[ -f "$PLATFORM_ROOT/../infra/compose/docker-compose.yml" ]]; then
  WORKSPACE_ROOT="$(cd "$PLATFORM_ROOT/.." && pwd)"
elif [[ -f "$PLATFORM_ROOT/infra/compose/docker-compose.yml" ]]; then
  WORKSPACE_ROOT="$PLATFORM_ROOT"
else
  echo "[smoke] ERROR: no se encontro infra/ junto a platform-services" >&2
  exit 1
fi

INFRA_DIR="$WORKSPACE_ROOT/infra"
ENV_FILE="${P4_ENV_FILE:-$INFRA_DIR/.env}"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"
BUILD_FILE="$INFRA_DIR/compose/docker-compose.build.yml"
PROJECT="${P4_COMPOSE_PROJECT:-infra}"
MODE="local"
if [[ "${1:-}" == "--ci" || "${CI:-}" == "true" ]]; then
  MODE="ci"
fi

log()  { printf '[smoke] %s\n' "$*"; }
fail() { printf '[smoke] ERROR: %s\n' "$*" >&2; exit 1; }

compose() {
  docker compose -f "$COMPOSE_FILE" -f "$BUILD_FILE" \
    --env-file "$ENV_FILE" -p "$PROJECT" "$@"
}

env_value() {
  awk -v k="$1" '
    index($0, k "=") == 1 { value = substr($0, length(k) + 2) }
    END { print value }
  ' "$ENV_FILE"
}

wait_http() {
  local label="$1" url="$2" resolve="$3" tries="${4:-90}" code=""
  for ((i = 1; i <= tries; i++)); do
    code="$(curl -sk --max-time 3 --resolve "$resolve" -o /dev/null \
      -w '%{http_code}' "$url" || true)"
    if [[ "$code" == "200" ]]; then
      log "$label: 200"
      return 0
    fi
    sleep 2
  done
  return 1
}

for tool in docker curl openssl; do
  command -v "$tool" >/dev/null 2>&1 || fail "falta $tool"
done
[[ -f "$ENV_FILE" ]] || fail "falta $ENV_FILE; ejecuta tests/e2e/ci/prepare-env.sh"
[[ -f "$BUILD_FILE" ]] || fail "falta $BUILD_FILE"
[[ -s "$INFRA_DIR/secrets/mongo_initdb_root_password.txt" ]] \
  || fail "faltan secretos; ejecuta tests/e2e/ci/prepare-env.sh"

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT)"
HTTPS_PORT="${HTTPS_PORT:-8543}"
API_BASE="https://api.localhost:${HTTPS_PORT}"
S3_BASE="https://s3.localhost:${HTTPS_PORT}"

if [[ ! -s "$INFRA_DIR/compose/mongo/keyfile" ]]; then
  log "generando keyfile de Mongo para el entorno efimero"
  (umask 077; openssl rand -base64 756 > "$INFRA_DIR/compose/mongo/keyfile")
  chmod 600 "$INFRA_DIR/compose/mongo/keyfile"
  docker run --rm -v "$INFRA_DIR/compose/mongo/keyfile:/keyfile" \
    --entrypoint chown mongo:7.0 999:999 /keyfile >/dev/null
fi

if [[ ! -s "$INFRA_DIR/traefik/certs/api.localhost.pem" ]]; then
  log "generando certificados locales"
  "$INFRA_DIR/scripts/gen-certs.sh" >/dev/null
fi

compose config -q || fail "docker compose config invalido"
log "compose config: OK"

if [[ "$MODE" == "ci" ]]; then
  log "levantando servicios del E2E (sin monolito ni observabilidad)"
  compose up -d --build \
    mongo mongo-init redis-streams redis-ratelimit minio minio-init \
    traefik doc-service minio-notify-init
fi

wait_http "doc-service /healthz" "$API_BASE/healthz" \
  "api.localhost:${HTTPS_PORT}:127.0.0.1" 90 \
  || fail "doc-service no respondio /healthz"
compose exec -T doc-service wget -qO- http://localhost:8080/readyz \
  | grep -q '"status":"ready"' || fail "doc-service /readyz no esta listo"
log "doc-service /readyz: ready"
wait_http "MinIO health" "$S3_BASE/minio/health/live" \
  "s3.localhost:${HTTPS_PORT}:127.0.0.1" 90 \
  || fail "MinIO no respondio health"

compose exec -T mongo sh -c '
  if [ -r /run/secrets/mongo_initdb_root_password ]; then
    PW=$(cat /run/secrets/mongo_initdb_root_password)
  else
    PW=$MONGO_INITDB_ROOT_PASSWORD
  fi
  mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$PW" \
    --authenticationDatabase admin --eval "db.hello().isWritablePrimary"
' | grep -q true || fail "Mongo no es PRIMARY"
log "Mongo: PRIMARY"

if compose exec -T redis-streams sh -c '
  if [ -r /run/secrets/redis_streams_password ]; then
    PW=$(cat /run/secrets/redis_streams_password)
  else
    PW=$REDIS_STREAMS_PASSWORD
  fi
  redis-cli -a "$PW" --no-auth-warning ping
' | grep -q PONG; then
  log "Redis Streams: PONG"
elif [[ "$MODE" == "ci" ]]; then
  fail "Redis Streams no responde PONG"
else
  log "AVISO: Redis local usa credenciales previas; se omite el auth check"
fi

log "Gate A smoke: OK"
