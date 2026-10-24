#!/usr/bin/env bash
# Prepara un entorno efimero para el E2E de P4.
#
# Uso:
#   tests/e2e/ci/prepare-env.sh            # completa secretos faltantes desde infra/.env
#   tests/e2e/ci/prepare-env.sh --ci       # crea infra/.env y secretos aleatorios
#
# En modo local NO pisa infra/.env ni los secretos existentes. En modo CI
# genera todos los valores con openssl y los escribe en infra/.env (ignorado
# por git). Nunca imprime valores secretos.
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
  echo "[prepare-env] ERROR: no se encontro infra/ junto a platform-services" >&2
  exit 1
fi
INFRA_DIR="$WORKSPACE_ROOT/infra"
ENV_FILE="${P4_ENV_FILE:-$INFRA_DIR/.env}"
SECRETS_DIR="${P4_SECRETS_DIR:-$INFRA_DIR/secrets}"

MODE="local"
if [[ "${1:-}" == "--ci" || "${CI:-}" == "true" ]]; then
  MODE="ci"
fi

fail() { printf '[prepare-env] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[prepare-env] %s\n' "$*"; }

command -v openssl >/dev/null 2>&1 || fail "falta openssl"
[[ -f "$INFRA_DIR/.env.example" ]] || fail "falta $INFRA_DIR/.env.example"
mkdir -p "$SECRETS_DIR"

rand_hex() { openssl rand -hex "$1"; }

env_value() {
  local key="$1"
  awk -v k="$key" '
    index($0, k "=") == 1 { value = substr($0, length(k) + 2) }
    END { print value }
  ' "$ENV_FILE"
}

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" '
      index($0, k "=") == 1 { print k "=" v; next }
      { print }
    ' "$ENV_FILE" > "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

if [[ "$MODE" == "ci" ]]; then
  cp "$INFRA_DIR/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  set_env MINIO_ROOT_USER "p4minio$(rand_hex 4)"
  set_env MINIO_ROOT_PASSWORD "$(rand_hex 16)"
  set_env SVC_DOCSERVICE_ACCESS_KEY "$(rand_hex 10)"
  set_env SVC_DOCSERVICE_SECRET_KEY "$(rand_hex 20)"
  set_env SVC_WORKER_ACCESS_KEY "$(rand_hex 10)"
  set_env SVC_WORKER_SECRET_KEY "$(rand_hex 20)"
  set_env REDIS_STREAMS_PASSWORD "$(rand_hex 16)"
  set_env REDIS_RATELIMIT_PASSWORD "$(rand_hex 16)"
  set_env MONGO_INITDB_ROOT_USERNAME "root"
  set_env MONGO_INITDB_ROOT_PASSWORD "$(rand_hex 16)"
  set_env MONGO_DATABASE "documents"
  set_env MONGO_APP_USER "docservice"
  set_env MONGO_APP_PASSWORD "$(rand_hex 16)"
  set_env MONGO_WORKER_USER "worker"
  set_env MONGO_WORKER_PASSWORD "$(rand_hex 16)"
  set_env MONOLITO_MONGO_USER "monolito"
  set_env MONOLITO_MONGO_PASSWORD "$(rand_hex 16)"
  set_env MINIO_WEBHOOK_SECRET "$(rand_hex 24)"
  set_env INTERNAL_TOKEN "$(rand_hex 24)"
  set_env GRAFANA_ADMIN_PASSWORD "$(rand_hex 16)"
  set_env MINIO_PUBLIC_ENDPOINT "https://s3.localhost:8543"
  set_env DOC_SERVICE_IMAGE "doc-service"
  set_env DOC_SERVICE_TAG "local"
  set_env DOC_SERVICE_BUILD_CONTEXT "../../doc-service"
  set_env REDIS_STREAM_KEY "stream:pdf-processing"
  set_env REDIS_CONSUMER_GROUP "extraction-workers"
  set_env REDIS_DLQ_KEY "stream:pdf-processing-dlq"
  set_env TRAEFIK_HTTP_PORT "8088"
  set_env TRAEFIK_HTTPS_PORT "8543"
  log "infra/.env efimero generado"
else
  [[ -f "$ENV_FILE" ]] || fail "falta $ENV_FILE; copia .env.example y completa los valores"
fi

write_secret() {
  local file="$1" key="$2" value
  value="$(env_value "$key")"
  [[ -n "$value" && "$value" != "changeme" ]] || fail "$key vacio o con placeholder en $ENV_FILE"
  if [[ "$MODE" == "local" && -s "$SECRETS_DIR/$file" ]]; then
    return 0
  fi
  printf '%s' "$value" > "$SECRETS_DIR/$file"
  chmod 600 "$SECRETS_DIR/$file"
}

write_secret mongo_initdb_root_password.txt MONGO_INITDB_ROOT_PASSWORD
write_secret mongo_app_password.txt MONGO_APP_PASSWORD
write_secret mongo_worker_password.txt MONGO_WORKER_PASSWORD
write_secret redis_streams_password.txt REDIS_STREAMS_PASSWORD
write_secret redis_ratelimit_password.txt REDIS_RATELIMIT_PASSWORD
write_secret minio_root_password.txt MINIO_ROOT_PASSWORD
write_secret minio_webhook_secret.txt MINIO_WEBHOOK_SECRET
write_secret internal_token.txt INTERNAL_TOKEN
write_secret grafana_admin_password.txt GRAFANA_ADMIN_PASSWORD
write_secret svc_docservice_access_key.txt SVC_DOCSERVICE_ACCESS_KEY
write_secret svc_docservice_secret_key.txt SVC_DOCSERVICE_SECRET_KEY
write_secret svc_worker_access_key.txt SVC_WORKER_ACCESS_KEY
write_secret svc_worker_secret_key.txt SVC_WORKER_SECRET_KEY

REDIS_STREAMS_PASSWORD="$(env_value REDIS_STREAMS_PASSWORD)"
if [[ "$MODE" == "ci" || ! -s "$SECRETS_DIR/redis_streams_password.json" ]]; then
  printf '{"redis_password": "%s"}' "$REDIS_STREAMS_PASSWORD" \
    > "$SECRETS_DIR/redis_streams_password.json"
  chmod 600 "$SECRETS_DIR/redis_streams_password.json"
fi

count="$(find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.gitkeep' | wc -l | tr -d ' ')"
log "secretos listos en infra/secrets ($count archivos; valores no impresos)"
