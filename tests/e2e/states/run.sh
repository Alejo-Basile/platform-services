#!/usr/bin/env bash
# shellcheck disable=SC2329
# Matriz de estados alcanzables (S3-P4-03).
#
# Uso:
#   tests/e2e/states/run.sh
#
# Requiere el stack `full` con extraction-worker (G-B cerrado). No levanta ni
# baja el stack.
#
# DoD (pasos-iniciales.md S3-P4-03): forzar los caminos de fallo y comprobar
# que ningun documento queda en un estado no terminal tras el ciclo completo:
# todos terminan en COMPLETED, FAILED, REJECTED o UPLOAD_EXPIRED.
#
# Limitacion explicita: el paso PENDING_UPLOAD -> UPLOAD_EXPIRED se fuerza por
# el endpoint operativo interno `/internal/documents/:id/cancel` (S4-P2-05),
# que aplica la misma transicion terminal que el reconciliador. El TTL real de
# 15 minutos queda cubierto por los tests unitarios del reconciliador y por
# `S5`; esperarlo aqui haria el E2E inviable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

log() { printf '[states] %s\n' "$*"; }
pass() { printf '  [PASS] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; }
block() { printf '  [BLOCKED] %s\n' "$*"; }

TERMINAL="COMPLETED FAILED REJECTED UPLOAD_EXPIRED"
HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT)"
HTTPS_PORT="${HTTPS_PORT:-8543}"
API_BASE="https://api.localhost:${HTTPS_PORT}"
RESOLVE="api.localhost:${HTTPS_PORT}:127.0.0.1"
S3_RESOLVE="s3.localhost:${HTTPS_PORT}:127.0.0.1"
# El token del stack en ejecucion manda: `prepare-env.sh` en modo local no pisa
# secretos existentes, asi que .env puede haber divergido del secreto montado.
internal_token() {
  local token=""
  token="$(compose exec -T doc-service sh -c 'cat /run/secrets/internal_token 2>/dev/null || printenv INTERNAL_TOKEN' 2>/dev/null | tr -d '\r\n')"
  [[ -n "$token" ]] || token="$(env_value INTERNAL_TOKEN)"
  printf '%s' "$token"
}

VALID_PDF="$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf"
INVALID_DIR="$PLATFORM_ROOT/tests/fixtures/pdf/invalid"
TMP_DIR="$(mktemp -d)"
CREATED=()
TOTAL_PASS=0
TOTAL_FAIL=0

trap 'rm -rf "$TMP_DIR"' EXIT

is_terminal() {
  local status="$1" candidate
  for candidate in $TERMINAL; do
    [[ "$status" == "$candidate" ]] && return 0
  done
  return 1
}

doc_field() {
  local id="$1" field="$2"
  mongo_eval "var d=db.documents.findOne({_id:'$id'}); print(d&&d.$field?d.$field:'')" | tail -n1
}

create_document() {
  # create_document <prefijo> <tamano>
  local prefix="$1" size="$2" id body
  id="${prefix}-$(date +%s)-$(openssl rand -hex 4)"
  body="$(jq -n --arg ik "$id" --argjson sz "$size" '{idempotency_key:$ik, size_bytes:$sz}')"
  local resp
  resp="$(curl -sk --fail-with-body --max-time 45 --resolve "$RESOLVE" \
    -X POST "$API_BASE/api/v2/documents" \
    -H 'Content-Type: application/json' -H "X-Correlation-Id: state-$id" \
    -d "$body" 2>/dev/null)" || return 1
  NEW_ID="$id"
  CREATE_JSON="$resp"
  CREATED+=("$id")
}

upload_file() {
  # upload_file <create-json> <archivo> <content-type>
  local create="$1" file="$2" ctype="$3" url form_args=()
  url="$(jq -r '.upload_url // empty' <<<"$create")"
  [[ -n "$url" ]] || return 1
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && form_args+=(-F "$k=$v")
  done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' <<<"$create")
  UPLOAD_CODE="$(curl -sk --max-time 90 --resolve "$S3_RESOLVE" -X POST "$url" \
    "${form_args[@]}" -F "file=@${file};type=${ctype}" \
    -o /dev/null -w '%{http_code}' || true)"
}

expect_terminal() {
  # expect_terminal <id> <estado-esperado> <campo> <valor-esperado>
  local id="$1" expected="$2" field="${3:-}" value="${4:-}" status
  if wait_status "$id" "$expected" 40; then
    status="$expected"
  else
    status="$(mongo_status "$id")"
  fi
  if ! is_terminal "$status"; then
    bad "estado $status no es terminal (esperado $expected)"
    return 1
  fi
  [[ "$status" == "$expected" ]] || { bad "estado $status (esperado $expected)"; return 1; }
  if [[ -n "$field" ]]; then
    [[ "$(doc_field "$id" "$field")" == "$value" ]] \
      || { bad "$field=$(doc_field "$id" "$field") (esperado $value)"; return 1; }
  fi
  return 0
}

run_case() {
  local name="$1" fn="$2"
  log "$name"
  if "$fn"; then
    pass "$name"
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    bad "$name"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}

case_completed() {
  local create id upload
  create_document state-happy "$(wc -c <"$VALID_PDF" | tr -d ' ')" || return 1
  id="$NEW_ID"
  upload_file "$CREATE_JSON" "$VALID_PDF" application/pdf
  upload="$UPLOAD_CODE"
  [[ "$upload" =~ ^2[0-9][0-9]$ ]] || { bad "subida HTTP $upload"; return 1; }
  expect_terminal "$id" COMPLETED || return 1
  # Contrato vigente: el worker cierra con `md_ref` (clave desnuda `<id>.md`) y
  # sube el objeto a `extracted-md`; `txt_ref` queda como compatibilidad legacy (D5).
  local ref bucket
  ref="$(doc_field "$id" md_ref)"
  bucket="extracted-md"
  if [[ -z "$ref" ]]; then
    ref="$(doc_field "$id" txt_ref)"
    bucket="extracted-txt"
  fi
  [[ -n "$ref" ]] || { bad "COMPLETED sin md_ref ni txt_ref"; return 1; }
  minio_exists "$bucket/$ref" || { bad "falta $bucket/$ref"; return 1; }
  return 0
}

case_not_a_pdf() {
  local create id upload file="$TMP_DIR/not-a-pdf.txt"
  printf 'esto no es un PDF\n' > "$file"
  create_document state-notpdf "$(wc -c <"$file" | tr -d ' ')" || return 1
  id="$NEW_ID"
  upload_file "$CREATE_JSON" "$file" application/pdf
  upload="$UPLOAD_CODE"
  [[ "$upload" =~ ^2[0-9][0-9]$ ]] || { bad "subida HTTP $upload"; return 1; }
  expect_terminal "$id" REJECTED failure_reason NOT_A_PDF
}

case_worker_reject() {
  # case_worker_reject <fixture> <error_cause>
  local fixture="$1" cause="$2" create id upload
  create_document "state-$(basename "$fixture" .pdf)" "$(wc -c <"$fixture" | tr -d ' ')" || return 1
  id="$NEW_ID"
  upload_file "$CREATE_JSON" "$fixture" application/pdf
  upload="$UPLOAD_CODE"
  [[ "$upload" =~ ^2[0-9][0-9]$ ]] || { bad "subida HTTP $upload"; return 1; }
  expect_terminal "$id" REJECTED error_cause "$cause"
}

case_upload_expired() {
  local create id resp
  create_document state-expired 1024 || return 1
  id="$NEW_ID"
  [[ "$(mongo_status "$id")" == "PENDING_UPLOAD" ]] \
    || { bad "no quedo PENDING_UPLOAD"; return 1; }
  local token
  token="$(internal_token)"
  resp="$(compose exec -T doc-service wget -qO- \
    --header="X-Internal-Token: ${token}" \
    --post-data='' "http://localhost:8080/internal/documents/$id/cancel" 2>/dev/null || true)"
  [[ -n "$resp" ]] || { bad "el endpoint interno /cancel no respondio"; return 1; }
  expect_terminal "$id" UPLOAD_EXPIRED failure_reason CANCELLED_BY_OPERATOR
}

case_corrupt() { case_worker_reject "$INVALID_DIR/corrupt.pdf" PDF_CORRUPT; }
case_encrypted() { case_worker_reject "$INVALID_DIR/encrypted.pdf" PDF_ENCRYPTED; }
case_no_text() { case_worker_reject "$INVALID_DIR/no-text.pdf" PDF_NO_TEXT; }

sweep() {
  local id status failures=0
  log "barrido final: ningun documento no terminal"
  for id in "${CREATED[@]}"; do
    status="$(mongo_status "$id")"
    if [[ -z "$status" ]]; then
      bad "$id desaparecio sin estado terminal"
      failures=$((failures + 1))
    elif ! is_terminal "$status"; then
      bad "$id quedo en $status (no terminal)"
      failures=$((failures + 1))
    fi
  done
  if ((failures > 0)); then
    return 1
  fi
  pass "${#CREATED[@]} documentos terminaron en estado terminal"
}

cleanup() {
  local id entry
  for id in "${CREATED[@]}"; do
    entry="$(stream_entry_for "$id" 2>/dev/null || true)"
    stream_delete "$entry"
    minio_delete "raw-pdfs/$id.pdf"
    mongo_delete "$id"
  done
}

for tool in docker curl jq openssl wget; do
  command -v "$tool" >/dev/null 2>&1 || { bad "falta $tool"; exit 1; }
done
[[ -f "$ENV_FILE" ]] || { bad "falta $ENV_FILE"; exit 1; }
[[ -f "$VALID_PDF" ]] || { bad "falta el fixture $VALID_PDF"; exit 1; }
for fixture in corrupt encrypted no-text; do
  [[ -f "$INVALID_DIR/$fixture.pdf" ]] || { bad "falta el fixture $INVALID_DIR/$fixture.pdf"; exit 1; }
done
require_mc_image || exit 1

log "Matriz de estados S3-P4-03 (API_BASE=$API_BASE, proyecto=$PROJECT)"
if ! curl -sk --max-time 5 --resolve "$RESOLVE" "$API_BASE/healthz" >/dev/null; then
  bad "doc-service no responde"
  exit 1
fi
if ! compose --profile full ps --services --status running 2>/dev/null | grep -qx extraction-worker; then
  block "extraction-worker no levantado (G-B requerido)"
  exit 2
fi

run_case "camino feliz -> COMPLETED" case_completed
run_case "no-PDF -> REJECTED/NOT_A_PDF" case_not_a_pdf
run_case "PDF corrupto -> REJECTED/PDF_CORRUPT" case_corrupt
run_case "PDF cifrado -> REJECTED/PDF_ENCRYPTED" case_encrypted
run_case "PDF sin texto -> REJECTED/PDF_NO_TEXT" case_no_text
run_case "PENDING_UPLOAD -> UPLOAD_EXPIRED" case_upload_expired
run_case "barrido de estados terminales" sweep

cleanup

echo
log "resumen: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
if ((TOTAL_FAIL > 0)); then
  exit 1
fi
exit 0
