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
#
# Desde S11 de infra el stack core/full monta secretos de Consul (CA, tokens
# ACL y htpasswd de la UI) aunque el perfil `discovery` no se levante. En modo
# CI se materializan para que Docker Compose no falle con "bind source path
# does not exist"; en modo local se avisa que faltan.
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
[[ "${1:-}" == "--ci" ]] && MODE="ci"

fail() { printf '[prepare-env] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[prepare-env] %s\n' "$*"; }

command -v openssl >/dev/null 2>&1 || fail "falta openssl"
[[ -f "$INFRA_DIR/.env.example" ]] || fail "falta $INFRA_DIR/.env.example"
mkdir -p "$SECRETS_DIR"
# Los archivos son 0444 (los lee el usuario no-root de cada contenedor por bind
# mount individual); la carpeta queda 0700 para que otros usuarios del host no
# puedan listarla ni abrirlos.
chmod 0700 "$SECRETS_DIR"

# Mongo exige keyFile para auth+replicaSet. No se versiona: en cada checkout
# limpio hay que generarlo con dueño 999 (UID de mongod) y modo 400.
ensure_mongo_keyfile() {
  local keyfile="$INFRA_DIR/compose/mongo/keyfile"
  [[ -s "$keyfile" ]] && return 0
  command -v docker >/dev/null 2>&1 || fail "falta docker para generar $keyfile"
  mkdir -p "$(dirname "$keyfile")"
  log "generando keyfile de Mongo"
  docker run --rm -u 0 -v "$(dirname "$keyfile"):/mnt" --entrypoint sh mongo:7.0 -c \
    'umask 077; openssl rand -base64 756 > /mnt/keyfile; chown 999:999 /mnt/keyfile; chmod 400 /mnt/keyfile'
}
ensure_mongo_keyfile

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

# Traefik corre como usuario no-root y necesita el GID del grupo del socket
# Docker. Compose interpola la variable aunque el perfil `full` no se levante,
# asi que debe existir aun para `docker compose config` del smoke.
if [[ -z "$(env_value DOCKER_GID)" ]]; then
  docker_gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
  if [[ -z "$docker_gid" ]]; then
    docker_gid="$(getent group docker | cut -d: -f3 || true)"
  fi
  [[ -n "$docker_gid" ]] || fail "no se pudo resolver el GID del grupo docker"
  set_env DOCKER_GID "$docker_gid"
  log "DOCKER_GID=$docker_gid agregado a $ENV_FILE"
fi

# --- Material de Consul (infra S11) -------------------------------------------
# infra declara secretos de Consul que doc-service, ratelimitd,
# extraction-worker y traefik montan por bind mount aunque el perfil
# `discovery` no se levante en el E2E. Docker Compose rechaza el `up` si el
# archivo fuente no existe ("bind source path does not exist"), asi que hay que
# materializarlos antes del smoke.
if [[ "$MODE" == "ci" ]]; then
  [[ -x "$INFRA_DIR/scripts/consul-dev-secrets.sh" ]] \
    || fail "falta $INFRA_DIR/scripts/consul-dev-secrets.sh (requerido por infra S11)"
  # Genera gossip key, CA y material de servidor. Idempotente: no pisa archivos.
  "$INFRA_DIR/scripts/consul-dev-secrets.sh" >/dev/null
  log "material TLS/gossip de Consul generado"

  # Tokens ACL por servicio: el E2E no levanta Consul, asi que configkv degrada
  # y el token nunca se valida contra el servidor. Se generan placeholders para
  # satisfacer el bind mount; el bootstrap real corre contra Consul vivo con
  # infra/scripts/consul-bootstrap-acl.sh.
  for token_file in consul_doc_service_token.txt consul_ratelimitd_token.txt \
                    consul_worker_token.txt consul_prometheus_token.txt; do
    [[ -s "$SECRETS_DIR/$token_file" ]] && continue
    printf '%s' "$(rand_hex 16)" > "$SECRETS_DIR/$token_file"
    chmod 0644 "$SECRETS_DIR/$token_file"
  done
  log "tokens ACL de Consul listos (placeholders para el E2E)"

  # Traefik monta el htpasswd de la UI de Consul y hoy infra no lo genera en
  # ningun script versionado: sin el archivo, el contenedor ni siquiera arranca.
  # La password entra por stdin (no por argv) y el hash se valida antes de
  # escribir para no dejar un archivo malformado que el guard `-s` nunca regenere.
  if [[ ! -s "$SECRETS_DIR/consul_ui_users.txt" ]]; then
    ui_password="$(rand_hex 16)"
    ui_hash="$(printf '%s\n' "$ui_password" | openssl passwd -apr1 -stdin)"
    unset ui_password
    [[ "$ui_hash" == "\$apr1\$"* ]] \
      || fail "openssl no genero un hash apr1 para el htpasswd de la UI de Consul"
    printf 'consul:%s\n' "$ui_hash" > "$SECRETS_DIR/consul_ui_users.txt"
    chmod 0644 "$SECRETS_DIR/consul_ui_users.txt"
  fi
  log "htpasswd de la UI de Consul listo"
else
  missing=()
  for required in consul_ca_cert.pem consul_doc_service_token.txt \
                  consul_ratelimitd_token.txt consul_worker_token.txt \
                  consul_prometheus_token.txt consul_ui_users.txt; do
    [[ -s "$SECRETS_DIR/$required" ]] || missing+=("$required")
  done
  if (( ${#missing[@]} > 0 )); then
    log "AVISO: infra S11 requiere ${missing[*]} en $SECRETS_DIR"
    log "       corre infra/scripts/consul-dev-secrets.sh y, con Consul arriba,"
    log "       infra/scripts/consul-bootstrap-acl.sh (crea los tokens ACL)"
    log "       consul_ui_users.txt es el htpasswd de la UI (usuario:hash apr1)"
  fi
fi

write_secret() {
  local file="$1" key="$2" value
  value="$(env_value "$key")"
  [[ -n "$value" && "$value" != "changeme" ]] || fail "$key vacio o con placeholder en $ENV_FILE"
  if [[ "$MODE" == "local" && -s "$SECRETS_DIR/$file" ]]; then
    chmod 0444 "$SECRETS_DIR/$file"
    return 0
  fi
  rm -f "$SECRETS_DIR/$file"
  printf '%s' "$value" > "$SECRETS_DIR/$file"
  chmod 0444 "$SECRETS_DIR/$file"
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
  rm -f "$SECRETS_DIR/redis_streams_password.json"
  printf '{"redis_password": "%s"}' "$REDIS_STREAMS_PASSWORD" \
    > "$SECRETS_DIR/redis_streams_password.json"
  chmod 0444 "$SECRETS_DIR/redis_streams_password.json"
elif [[ "$MODE" == "local" ]]; then
  chmod 0444 "$SECRETS_DIR/redis_streams_password.json"
fi

count="$(find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.gitkeep' | wc -l | tr -d ' ')"
log "secretos listos en infra/secrets ($count archivos; valores no impresos)"
