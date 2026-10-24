#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317,SC2329
# E2E de caminos de error (S2-P4-01).
#
# Uso:
#   tests/e2e/errors/run.sh             # casos sin caos (stack local/CI ya arriba)
#   tests/e2e/errors/run.sh --chaos     # incluye MinIO/Redis/Mongo caidos
#
# Requiere el stack `full` sin monolito: mongo, redis-streams, minio, traefik,
# doc-service y minio-notify-init. No levanta ni baja el stack; el workflow lo
# hace. Los casos de worker (PDF corrupto/cifrado/sin texto) quedan BLOQUEADOS
# hasta G-B.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [[ -n "${P4_WORKSPACE_ROOT:-}" ]]; then
  WORKSPACE_ROOT="$P4_WORKSPACE_ROOT"
elif [[ -f "$PLATFORM_ROOT/../infra/compose/docker-compose.yml" ]]; then
  WORKSPACE_ROOT="$(cd "$PLATFORM_ROOT/.." && pwd)"
elif [[ -f "$PLATFORM_ROOT/infra/compose/docker-compose.yml" ]]; then
  WORKSPACE_ROOT="$PLATFORM_ROOT"
else
  echo "[errors] ERROR: no se encontro infra/ junto a platform-services" >&2
  exit 1
fi

INFRA_DIR="$WORKSPACE_ROOT/infra"
ENV_FILE="${P4_ENV_FILE:-$INFRA_DIR/.env}"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"
BUILD_FILE="$INFRA_DIR/compose/docker-compose.build.yml"
OVERRIDE_FILE="$PLATFORM_ROOT/tests/e2e/ci/compose.override.yml"
PROJECT="${P4_COMPOSE_PROJECT:-infra}"
CHAOS=0
[[ "${1:-}" == "--chaos" ]] && CHAOS=1

log()   { printf '[errors] %s\n' "$*"; }
pass()  { printf '  [PASS] %s\n' "$*"; }
bad()   { printf '  [FAIL] %s\n' "$*"; }
block() { printf '  [BLOCKED] %s\n' "$*"; }

compose() {
  docker compose -f "$COMPOSE_FILE" -f "$BUILD_FILE" -f "$OVERRIDE_FILE" \
    --env-file "$ENV_FILE" -p "$PROJECT" "$@"
}

env_value() {
  awk -v k="$1" '
    index($0, k "=") == 1 { value = substr($0, length(k) + 2) }
    END { print value }
  ' "$ENV_FILE"
}

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT)"
HTTPS_PORT="${HTTPS_PORT:-8543}"
API_BASE="https://api.localhost:${HTTPS_PORT}"
S3_BASE="https://s3.localhost:${HTTPS_PORT}"
MONGO_DATABASE="$(env_value MONGO_DATABASE)"
MONGO_DATABASE="${MONGO_DATABASE:-documents}"
REDIS_STREAM_KEY="$(env_value REDIS_STREAM_KEY)"
REDIS_STREAM_KEY="${REDIS_STREAM_KEY:-stream:pdf-processing}"
MAX_PDF="$(env_value MAX_PDF_BYTES)"
MAX_PDF="${MAX_PDF:-26214400}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VALID_PDF="$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf"
NOT_PDF="$TMP_DIR/not-a-pdf.txt"
OVERSIZE="$TMP_DIR/oversize.bin"
printf 'esto no es un PDF\n' > "$NOT_PDF"
if ! [[ -f "$OVERSIZE" ]]; then
  # Archivo disperso: suficiente para que MinIO aplique content-length-range.
  truncate -s "$((MAX_PDF + 1048576))" "$OVERSIZE"
fi

CURRENT_DOC=""
CURRENT_KEY=""
STOPPED=()
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_BLOCKED=0

mongo_eval() {
  local js="$1"
  compose exec -T -e P4_JS="$js" -e P4_DB="$MONGO_DATABASE" mongo sh -c '
    if [ -r /run/secrets/mongo_initdb_root_password ]; then
      PW=$(cat /run/secrets/mongo_initdb_root_password)
    else
      PW=$MONGO_INITDB_ROOT_PASSWORD
    fi
    mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$PW" \
      --authenticationDatabase admin "$P4_DB" --eval "$P4_JS"
  ' 2>/dev/null
}

mongo_status() {
  local id="$1"
  mongo_eval "var d=db.documents.findOne({_id:'$id'}); print(d?d.status:'')" | tail -n1
}

mongo_reason() {
  local id="$1"
  mongo_eval "var d=db.documents.findOne({_id:'$id'}); print(d&&d.failure_reason?d.failure_reason:'')" | tail -n1
}

mongo_delete() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  mongo_eval "db.documents.deleteOne({_id:'$id'})" >/dev/null 2>&1 || true
}

redis_cli() {
  compose exec -T redis-streams sh -c '
    if [ -r /run/secrets/redis_streams_password ]; then
      PW=$(cat /run/secrets/redis_streams_password)
    else
      PW=$REDIS_STREAMS_PASSWORD
    fi
    redis-cli -a "$PW" --no-auth-warning "$@"
  ' sh "$@" 2>/dev/null
}

redis_available() { redis_cli PING | grep -qx PONG; }

stream_entry_for() {
  local id="$1"
  redis_cli --raw XRANGE "$REDIS_STREAM_KEY" - + COUNT 10000 |
    awk -v id="$id" '
      /^[0-9]+-[0-9]+$/ { entry=$0; next }
      index($0, "\"document_id\":\"" id "\"") { print entry; exit }
    '
}

stream_delete() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  redis_cli XDEL "$REDIS_STREAM_KEY" "$entry" >/dev/null 2>&1 || true
}

minio_delete() {
  local key="$1"
  [[ -n "$key" ]] || return 0
  local user pass
  user="$(env_value MINIO_ROOT_USER)"
  pass="$(env_value MINIO_ROOT_PASSWORD)"
  MC_HOST_local="http://${user}:${pass}@minio:9000" \
    docker run --rm --network infra_data --entrypoint mc \
    -e MC_HOST_local bitnamilegacy/minio-client:2025.7.21 \
    rm --force "local/${key}" >/dev/null 2>&1 || true
}

wait_http() {
  local url="$1" resolve="$2" tries="${3:-60}"
  for ((i = 1; i <= tries; i++)); do
    [[ "$(curl -sk --max-time 3 --resolve "$resolve" -o /dev/null -w '%{http_code}' "$url" || true)" == "200" ]] && return 0
    sleep 1
  done
  return 1
}

wait_status() {
  local id="$1" expected="$2" tries="${3:-30}" status=""
  for ((i = 1; i <= tries; i++)); do
    status="$(mongo_status "$id")"
    [[ "$status" == "$expected" ]] && return 0
    sleep 1
  done
  printf '  estado final: %s (esperado %s)\n' "${status:-MISSING}" "$expected" >&2
  return 1
}

post_create() {
  local id="$1" size="$2" body_file="$3" hdr_file="$4"
  local body
  body="$(jq -n --arg ik "$id" --argjson sz "$size" \
    '{idempotency_key:$ik, size_bytes:$sz}')"
  curl -sk --max-time 45 --resolve "api.localhost:${HTTPS_PORT}:127.0.0.1" \
    -X POST "$API_BASE/api/v2/documents" \
    -H 'Content-Type: application/json' -H "X-Correlation-Id: err-${id}" \
    -d "$body" -D "$hdr_file" -o "$body_file" -w '%{http_code}' || true
}

upload_pdf() {
  local create_json="$1" file="$2" ctype="$3"
  local url key
  url="$(jq -r '.upload_url // empty' "$create_json")"
  key="$(jq -r '.form_fields.key // empty' "$create_json")"
  [[ -n "$url" && -n "$key" ]] || return 1
  CURRENT_KEY="$key"
  local form_args=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && form_args+=(-F "$k=$v")
  done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' "$create_json")

  curl -sk --max-time 60 --resolve "s3.localhost:${HTTPS_PORT}:127.0.0.1" \
    -X POST "$url" "${form_args[@]}" -F "file=@${file};type=${ctype}" \
    -o /dev/null -w '%{http_code}' || true
}

cleanup_current() {
  local entry=""
  mongo_delete "$CURRENT_DOC"
  minio_delete "$CURRENT_KEY"
  entry="$(stream_entry_for "$CURRENT_DOC" 2>/dev/null || true)"
  stream_delete "$entry"
  CURRENT_DOC=""
  CURRENT_KEY=""
}

restore_services() {
  local svc
  for svc in "${STOPPED[@]:-}"; do
    if [[ -n "$svc" ]]; then
      compose start "$svc" >/dev/null 2>&1 || true
    fi
  done
  STOPPED=()
}
trap 'restore_services; cleanup_current; rm -rf "$TMP_DIR"' EXIT

stop_service() {
  local svc="$1"
  compose stop "$svc" >/dev/null
  STOPPED+=("$svc")
}

run_case() {
  local name="$1" fn="$2" rc=0
  log "$name"
  "$fn" || rc=1
  cleanup_current
  if ((rc == 0)); then
    pass "$name"
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    bad "$name"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}

blocked_case() {
  local name="$1" reason="$2"
  log "$name"
  block "$reason"
  TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
}

case_oversize_declared() {
  local id body hdr code
  id="err-oversize-$(date +%s)-$RANDOM"
  body="$TMP_DIR/oversize.json"
  hdr="$TMP_DIR/oversize.hdr"
  code="$(post_create "$id" "$((MAX_PDF + 1))" "$body" "$hdr")"
  [[ "$code" == "400" ]] || { bad "HTTP $code (esperado 400)"; return 1; }
  [[ "$(mongo_status "$id")" == "" ]] || { bad "se persistio un documento invalido"; return 1; }
  pass "400 validation y sin documento persistido"
}

case_fake_mime() {
  local id body hdr code upload
  id="err-mime-$(date +%s)-$RANDOM"
  body="$TMP_DIR/mime.json"
  hdr="$TMP_DIR/mime.hdr"
  code="$(post_create "$id" "$(wc -c < "$NOT_PDF" | tr -d ' ')" "$body" "$hdr")"
  [[ "$code" == "201" ]] || { bad "create HTTP $code"; return 1; }
  CURRENT_DOC="$id"
  upload="$(upload_pdf "$body" "$NOT_PDF" "application/pdf")"
  [[ "$upload" =~ ^2[0-9][0-9]$ ]] || { bad "upload HTTP $upload"; return 1; }
  wait_status "$id" "REJECTED" 30 || return 1
  [[ "$(mongo_reason "$id")" == "NOT_A_PDF" ]] || { bad "failure_reason distinto de NOT_A_PDF"; return 1; }
  if redis_available; then
    [[ -z "$(stream_entry_for "$id")" ]] || { bad "un PDF invalido llego al stream"; return 1; }
  else
    log "aviso: Redis no autentica; se omite el aserto de stream"
  fi
  pass "REJECTED/NOT_A_PDF y sin mensaje en Redis"
}

case_never_upload() {
  local id body hdr code
  id="err-pending-$(date +%s)-$RANDOM"
  body="$TMP_DIR/pending.json"
  hdr="$TMP_DIR/pending.hdr"
  code="$(post_create "$id" 1024 "$body" "$hdr")"
  [[ "$code" == "201" ]] || { bad "create HTTP $code"; return 1; }
  CURRENT_DOC="$id"
  sleep 3
  [[ "$(mongo_status "$id")" == "PENDING_UPLOAD" ]] || { bad "no quedo PENDING_UPLOAD"; return 1; }
  if redis_available; then
    [[ -z "$(stream_entry_for "$id")" ]] || { bad "un documento sin subir llego al stream"; return 1; }
  fi
  pass "PENDING_UPLOAD sin mensaje en Redis (ventana corta; TTL no esperado)"
}

case_oversize_upload() {
  local id body hdr code upload
  id="err-big-$(date +%s)-$RANDOM"
  body="$TMP_DIR/big.json"
  hdr="$TMP_DIR/big.hdr"
  code="$(post_create "$id" 1024 "$body" "$hdr")"
  [[ "$code" == "201" ]] || { bad "create HTTP $code"; return 1; }
  CURRENT_DOC="$id"
  upload="$(upload_pdf "$body" "$OVERSIZE" "application/pdf")"
  [[ "$upload" == "400" || "$upload" == "413" ]] \
    || { bad "upload HTTP $upload (esperado 400/413 EntityTooLarge)"; return 1; }
  [[ "$(mongo_status "$id")" == "PENDING_UPLOAD" ]] \
    || { bad "el documento no quedo PENDING_UPLOAD"; return 1; }
  pass "MinIO rechazo por content-length-range ($upload) y el documento sigue PENDING_UPLOAD"
}

case_minio_down() {
  local id body hdr code upload
  id="err-minio-$(date +%s)-$RANDOM"
  body="$TMP_DIR/minio.json"
  hdr="$TMP_DIR/minio.hdr"
  stop_service minio
  code="$(post_create "$id" 1024 "$body" "$hdr")"
  if [[ "$code" == "201" ]]; then
    CURRENT_DOC="$id"
    upload="$(upload_pdf "$body" "$NOT_PDF" "application/pdf")"
    [[ "$upload" == "000" || "$upload" =~ ^5 ]] \
      || { bad "upload con MinIO caido devolvio $upload"; return 1; }
    [[ "$(mongo_status "$id")" == "PENDING_UPLOAD" ]] \
      || { bad "el documento no quedo PENDING_UPLOAD"; return 1; }
  else
    [[ "$code" =~ ^5 ]] || { bad "create con MinIO caido devolvio $code"; return 1; }
  fi
  compose start minio >/dev/null
  wait_http "$S3_BASE/minio/health/live" "s3.localhost:${HTTPS_PORT}:127.0.0.1" 60 \
    || { bad "MinIO no volvio"; return 1; }
  restore_services
  pass "fallo controlado con MinIO caido y recuperacion"
}

case_redis_down() {
  local id body hdr code upload
  id="err-redis-$(date +%s)-$RANDOM"
  body="$TMP_DIR/redis.json"
  hdr="$TMP_DIR/redis.hdr"
  stop_service redis-streams
  code="$(post_create "$id" "$(wc -c < "$VALID_PDF" | tr -d ' ')" "$body" "$hdr")"
  [[ "$code" == "201" ]] || { bad "create con Redis caido devolvio $code"; return 1; }
  CURRENT_DOC="$id"
  upload="$(upload_pdf "$body" "$VALID_PDF" "application/pdf")"
  [[ "$upload" =~ ^2[0-9][0-9]$ ]] || { bad "upload HTTP $upload"; return 1; }
  wait_status "$id" "UPLOADED" 30 || return 1
  compose start redis-streams >/dev/null
  wait_http "$S3_BASE/minio/health/live" "s3.localhost:${HTTPS_PORT}:127.0.0.1" 1 >/dev/null || true
  for ((i = 1; i <= 30; i++)); do redis_available && break; sleep 1; done
  restore_services
  pass "webhook registro UPLOADED con Redis caido; relay no pudo encolar"
}

case_mongo_down() {
  local id body hdr code start
  id="err-mongo-$(date +%s)-$RANDOM"
  body="$TMP_DIR/mongo.json"
  hdr="$TMP_DIR/mongo.hdr"
  stop_service mongo
  start=$SECONDS
  code="$(post_create "$id" 1024 "$body" "$hdr")"
  log "create con Mongo caido: HTTP ${code:-000} en $((SECONDS - start))s"
  [[ "$code" =~ ^5 ]] || { bad "create con Mongo caido devolvio $code"; return 1; }
  compose start mongo >/dev/null
  for ((i = 1; i <= 60; i++)); do
    [[ "$(mongo_eval 'db.runCommand({ping:1}).ok' 2>/dev/null | tail -n1)" == "1" ]] && break
    sleep 1
  done
  restore_services
  pass "create devolvio 5xx con Mongo caido"
}

for tool in docker curl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || { bad "falta $tool"; exit 1; }
done
[[ -f "$ENV_FILE" ]] || { bad "falta $ENV_FILE"; exit 1; }
[[ -f "$VALID_PDF" ]] || { bad "falta el fixture $VALID_PDF"; exit 1; }
[[ -f "$OVERRIDE_FILE" ]] || { bad "falta $OVERRIDE_FILE"; exit 1; }

log "API_BASE=$API_BASE proyecto=$PROJECT"
curl -sk --max-time 5 --resolve "api.localhost:${HTTPS_PORT}:127.0.0.1" \
  "$API_BASE/healthz" >/dev/null || { bad "doc-service no responde"; exit 1; }

run_case "oversize declarado" case_oversize_declared
run_case "MIME falso (no PDF)" case_fake_mime
run_case "cliente que nunca sube" case_never_upload
run_case "PDF mayor al maximo en MinIO" case_oversize_upload

if ((CHAOS == 1)); then
  run_case "MinIO caido" case_minio_down
  run_case "Redis caido" case_redis_down
  run_case "Mongo caido" case_mongo_down
else
  blocked_case "MinIO/Redis/Mongo caidos" "requiere --chaos y un stack aislado"
fi

blocked_case "PDF corrupto" "requiere worker real (G-B)"
blocked_case "PDF cifrado" "requiere worker real (G-B)"
blocked_case "PDF sin texto" "requiere worker real (G-B)"

echo
log "resumen: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL BLOCKED=$TOTAL_BLOCKED"
if ((TOTAL_FAIL > 0)); then
  exit 1
fi
exit 0
