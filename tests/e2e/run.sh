#!/usr/bin/env bash
# Arnés E2E de P4 — S0-P4-05 (smoke) y S1-P4-04 (happy).
#
# Uso:
#   ./tests/e2e/run.sh smoke
#   ./tests/e2e/run.sh happy
#   ./tests/e2e/run.sh happy --runs 10 --keep-stack
#
# `smoke` valida gateway, monolito legacy, Mongo y MinIO.
# `happy` valida el camino v2 hasta UPLOADED y el mensaje en Redis Streams.
# El worker de extracción no existe todavía: no se valida COMPLETED y el DoD
# de S1-P4-04 queda BLOQUEADO (se registra en la evidencia).
#
# Seguridad de datos:
#   - Usa el proyecto Compose `infra` (o `P4_COMPOSE_PROJECT`).
#   - Si el stack ya estaba corriendo, NO lo apaga.
#   - Si el script lo levanta, al terminar hace `stop` (nunca `down -v`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

KEEP_STACK=0
RUNS=10
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  case "$arg" in
    --keep-stack) KEEP_STACK=1 ;;
    --runs)
      j=$((i + 1))
      RUNS="${!j:-10}"
      i=$j
      ;;
  esac
done

log()  { printf '[e2e] %s\n' "$*"; }
fail() { printf '[e2e] ERROR: %s\n' "$*" >&2; exit 1; }

compose_full() {
  compose --profile full "$@"
}

preflight() {
  command -v docker >/dev/null 2>&1 || fail "docker no está instalado"
  docker compose version >/dev/null 2>&1 || fail "docker compose v2 no está disponible"
  [[ -f "$COMPOSE_FILE" ]] || fail "no existe $COMPOSE_FILE"
  [[ -f "$ENV_FILE" ]] || fail "falta $ENV_FILE: copia infra/.env.example y genera credenciales (nunca lo commitees)"
  [[ -f "$INFRA_DIR/compose/mongo/keyfile" ]] || fail "falta infra/compose/mongo/keyfile: ejecuta infra/scripts/bootstrap.sh"
  [[ -f "$INFRA_DIR/traefik/certs/api.localhost.pem" ]] || fail "faltan certs locales: ejecuta infra/scripts/gen-certs.sh"
  [[ -f "$INFRA_DIR/traefik/certs/s3.localhost.pem" ]] || fail "faltan certs locales: ejecuta infra/scripts/gen-certs.sh"
}

http_code() {
  curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true
}

was_running=0
started=0
STARTED_SERVICES=()
INIT_SERVICES=()

cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    log "el arnés falló; logs recientes:"
    compose logs --no-color --tail=40 doc-service minio-notify-init 2>/dev/null || true
  fi
  if (( started == 1 && KEEP_STACK == 0 )); then
    log "deteniendo los servicios levantados por el arnés (sin borrar volúmenes)"
    compose stop "${STARTED_SERVICES[@]}" >/dev/null 2>&1 || true
  elif (( KEEP_STACK == 1 )); then
    log "--keep-stack: el stack queda levantado"
  fi
  exit "$rc"
}
trap cleanup EXIT

start_if_needed() {
  local required=("$@")
  local running
  running="$(compose_full ps --status running --services 2>/dev/null || true)"

  local missing=0
  for svc in "${required[@]}"; do
    grep -qx "$svc" <<<"$running" || missing=1
  done

  if (( missing == 0 )); then
    was_running=1
    log "stack ya estaba corriendo; no se apagará al terminar"
    return 0
  fi

  started=1
  STARTED_SERVICES=("${required[@]}" "${INIT_SERVICES[@]}")
  log "levantando servicios: ${STARTED_SERVICES[*]}"
  compose_full up -d "${STARTED_SERVICES[@]}"
}

wait_jobs() {
  local jobs=("$@")
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local pending=0 svc state code
    for svc in "${jobs[@]}"; do
      read -r state code < <(compose_full ps -a --format json 2>/dev/null \
        | jq -r --arg s "$svc" 'select(.Service==$s) | "\(.State) \(.ExitCode)"' \
        | tail -n1)
      if [[ "$state" != "exited" || "$code" != "0" ]]; then
        pending=1
      fi
    done
    (( pending == 0 )) && return 0
    sleep 1
  done
  return 1
}

mongo_status() {
  local id="$1"
  compose exec -T mongo mongosh --quiet \
    -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" \
    --authenticationDatabase "$MONGO_DATABASE" "$MONGO_DATABASE" \
    --eval "var d=db.documents.findOne({_id:'$id'}); print(d?d.status:'MISSING')" \
    2>/dev/null || true
}

mongo_delete() {
  local id="$1"
  compose exec -T mongo mongosh --quiet \
    -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" \
    --authenticationDatabase "$MONGO_DATABASE" "$MONGO_DATABASE" \
    --eval "db.documents.deleteOne({_id:'$id'})" >/dev/null 2>&1 || true
}

smoke() {
  preflight
  local required=(mongo minio traefik monolito)
  INIT_SERVICES=(mongo-init minio-init)
  start_if_needed "${required[@]}"

  local https_port http_port api_base s3_base
  https_port="$(env_value TRAEFIK_HTTPS_PORT 443)"
  http_port="$(env_value TRAEFIK_HTTP_PORT 80)"
  api_base="https://api.localhost:${https_port}"
  s3_base="https://s3.localhost:${https_port}"

  log "esperando gateway y monolito en ${api_base}/health"
  wait_http "${api_base}/health" "api.localhost:${https_port}:127.0.0.1" 60 \
    || fail "el monolito no respondió 200 en /health"
  wait_http "${s3_base}/minio/health/live" "s3.localhost:${https_port}:127.0.0.1" 60 \
    || fail "MinIO no respondió 200 en /minio/health/live"

  local health ready s3 redirect registros
  health="$(curl -sk --max-time 5 "${api_base}/health")"
  grep -q '"status":"healthy"' <<<"$health" || fail "respuesta inesperada de /health: $health"
  log "health: OK"

  ready="$(http_code "${api_base}/health/ready")"
  [[ "$ready" == "200" ]] || fail "/health/ready devolvió $ready"
  log "ready: OK"

  s3="$(http_code "${s3_base}/minio/health/live")"
  [[ "$s3" == "200" ]] || fail "MinIO health devolvió $s3"
  log "minio: OK"

  redirect="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://api.localhost:${http_port}/health" || true)"
  [[ "$redirect" == "301" || "$redirect" == "308" ]] || fail "HTTP no redirige a HTTPS (código $redirect)"
  log "redirect HTTP->HTTPS: OK ($redirect)"

  registros="$(http_code "${api_base}/registros?page=1&page_size=1")"
  [[ "$registros" == "200" ]] || fail "/registros devolvió $registros (¿Mongo listo?)"
  log "mongo vía /registros: OK"

  if (( was_running == 0 )); then
    log "smoke completado; el stack se detendrá (los volúmenes se conservan)"
  else
    log "smoke completado sobre el stack existente"
  fi
}

happy_once() {
  local n="$1"
  local fixture="$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf"
  [[ -f "$fixture" ]] || { log "falta el fixture $fixture"; return 1; }

  local doc_id corr
  doc_id="p4-$(date +%s)-$(openssl rand -hex 8)"
  corr="p4-e2e-$(printf '%02d' "$n")-$(date -u +%Y%m%dT%H%M%SZ)"
  local size create_body create_resp upload_url object_key
  size="$(wc -c <"$fixture" | tr -d ' ')"
  create_body="$(jq -n --arg ik "$doc_id" --argjson sz "$size" '{idempotency_key:$ik, size_bytes:$sz}')"

  create_resp="$(curl -sk --fail-with-body --max-time 20 -X POST "$API_BASE/api/v2/documents" \
    -H 'Content-Type: application/json' -H "X-Correlation-Id: $corr" -d "$create_body" 2>/dev/null)" || {
    log "run $n: POST create falló"
    mongo_delete "$doc_id"
    return 1
  }

  upload_url="$(jq -r '.upload_url // empty' <<<"$create_resp")"
  object_key="$(jq -r '.form_fields.key // empty' <<<"$create_resp")"
  [[ -n "$upload_url" && -n "$object_key" ]] || {
    log "run $n: respuesta de create incompleta"
    mongo_delete "$doc_id"
    return 1
  }

  local form_args=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && form_args+=(-F "$k=$v")
  done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' <<<"$create_resp")

  local upload_code
  upload_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$upload_url" \
    "${form_args[@]}" -F "file=@${fixture};type=application/pdf" || true)"
  if [[ ! "$upload_code" =~ ^2[0-9][0-9]$ ]]; then
    log "run $n: subida prefirmada devolvió $upload_code"
    mongo_delete "$doc_id"
    minio_delete "$object_key"
    return 1
  fi

  local status="" i
  for ((i = 1; i <= 30; i++)); do
    status="$(mongo_status "$doc_id")"
    [[ "$status" == "UPLOADED" ]] && break
    sleep 1
  done
  if [[ "$status" != "UPLOADED" ]]; then
    log "run $n: estado final $status (se esperaba UPLOADED)"
    mongo_delete "$doc_id"
    minio_delete "$object_key"
    return 1
  fi

  local entry="" xlen
  for ((i = 1; i <= 30; i++)); do
    entry="$(stream_entry_for "$doc_id")"
    [[ -n "$entry" ]] && break
    sleep 1
  done
  xlen="$(stream_length)"
  if [[ -z "$entry" ]]; then
    log "run $n: no se encontró el mensaje en $REDIS_STREAM_KEY"
    mongo_delete "$doc_id"
    minio_delete "$object_key"
    return 1
  fi

  log "run $n: OK document_id=$doc_id status=UPLOADED stream=$entry XLEN=$xlen"

  mongo_delete "$doc_id"
  minio_delete "$object_key"
  stream_delete "$entry"
  return 0
}

happy() {
  preflight
  for tool in jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || fail "falta la herramienta: $tool"
  done

  local https_port api_base
  https_port="$(env_value TRAEFIK_HTTPS_PORT 443)"
  api_base="https://api.localhost:${https_port}"
  API_BASE="$api_base"

  MONGO_APP_USER="$(env_value MONGO_APP_USER)"
  MONGO_APP_PASSWORD="$(env_value MONGO_APP_PASSWORD)"
  MONGO_DATABASE="$(env_value MONGO_DATABASE documents)"
  REDIS_STREAMS_PASSWORD="$(env_value REDIS_STREAMS_PASSWORD)"
  REDIS_STREAM_KEY="$(env_value REDIS_STREAM_KEY stream:pdf-processing)"
  export MONGO_APP_USER MONGO_APP_PASSWORD REDIS_STREAMS_PASSWORD REDIS_STREAM_KEY

  local required=(mongo redis-streams redis-ratelimit minio traefik monolito doc-service)
  INIT_SERVICES=(mongo-init minio-init minio-notify-init)
  start_if_needed "${required[@]}"

  wait_http "$api_base/healthz" "api.localhost:${https_port}:127.0.0.1" 90 \
    || fail "doc-service no respondió 200 en /healthz"
  wait_http "https://s3.localhost:${https_port}/minio/health/live" \
    "s3.localhost:${https_port}:127.0.0.1" 60 || fail "MinIO no respondió"

  if (( started == 1 )); then
    log "esperando jobs de inicialización (mongo-init, minio-init, minio-notify-init)"
    wait_jobs mongo-init minio-init minio-notify-init \
      || fail "los jobs de inicialización no terminaron con exit 0"
  fi

  log "S1-P4-04 parcial: worker no implementado; se valida hasta UPLOADED y Redis Streams"
  local failures=0
  for ((n = 1; n <= RUNS; n++)); do
    if happy_once "$n"; then
      :
    else
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    log "happy: $failures/$RUNS ejecuciones fallaron"
    return 1
  fi
  log "happy: $RUNS/$RUNS ejecuciones OK (COMPLETED no validado: S1-P3-02 pendiente)"
  return 0
}

usage() {
  cat <<'EOF'
Uso: ./tests/e2e/run.sh <comando> [opciones]

  smoke   Valida gateway, monolito legacy, Mongo y MinIO (S0-P4-05).
  happy   Valida el camino v2 hasta UPLOADED y Redis Streams (S1-P4-04).
          Opciones: --runs N (default 10), --keep-stack
EOF
}

case "${1:-}" in
  smoke) smoke ;;
  happy) happy ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
