#!/usr/bin/env bash
# Arnés E2E cadena real (S3-P4-01) — F3 Worker
#
# Flujo: crear -> prefirmar -> subir a MinIO -> webhook -> relay -> worker -> .txt -> COMPLETED -> descarga
# Requiere: G-B (worker real + servicio extraction-worker)
#
# Uso:
#   tests/e2e/chain/run.sh --runs 10
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

RUNS=10
for ((i=1;i<=$#;i++)); do
  arg="${!i}"
  case "$arg" in
    --runs) j=$((i+1)); RUNS="${!j:-10}"; i=$j ;;
  esac
done

log(){ printf '[chain] %s\n' "$*"; }
fail(){ printf '[chain] ERROR: %s\n' "$*" >&2; exit 1; }
pass(){ printf '  [PASS] %s\n' "$*"; }
bad(){ printf '  [FAIL] %s\n' "$*"; }
block(){ printf '  [BLOCKED] %s\n' "$*"; }

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT)"; HTTPS_PORT="${HTTPS_PORT:-8543}"
API_BASE="https://api.localhost:${HTTPS_PORT}"
MONGO_DATABASE="$(env_value MONGO_DATABASE)"; MONGO_DATABASE="${MONGO_DATABASE:-documents}"

for tool in jq openssl curl docker mongosh mc; do
  command -v "$tool" >/dev/null 2>&1 || fail "falta herramienta: $tool"
done
require_mc_image || fail "no se pudo obtener imagen mc ($MC_IMAGE)"

export P4_MONGO_DB="$MONGO_DATABASE"

check_worker(){
  # Verificar si hay servicio worker levantado
  if compose ps --services --status running 2>/dev/null | grep -qx "extraction-worker"; then
    return 0
  fi
  return 1
}

run_once(){
  local n="$1" fixture="$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf"
  [[ -f "$fixture" ]] || { bad "falta fixture $fixture"; return 1; }
  
  if ! check_worker; then
    block "extraction-worker no levantado (G-B requerido)"
    return 2
  fi
  
  local doc_id corr size create_body resp upload_url object_key
  doc_id="chain-$(date +%s)-$(openssl rand -hex 6)"
  corr="chain-$n-$(date -u +%Y%m%dT%H%M%SZ)"
  size="$(wc -c <"$fixture" | tr -d ' ')"
  create_body="$(jq -n --arg ik "$doc_id" --argjson sz "$size" '{idempotency_key:$ik,size_bytes:$sz}')"
  
  resp="$(curl -sk --fail-with-body --max-time 30 -X POST "$API_BASE/api/v2/documents" -H 'Content-Type: application/json' -H "X-Correlation-Id: $corr" -d "$create_body" 2>/dev/null)" || { bad "POST create falló"; return 1; }
  upload_url="$(jq -r '.upload_url // empty' <<<"$resp")"
  object_key="$(jq -r '.form_fields.key // empty' <<<"$resp")"
  [[ -n "$upload_url" && -n "$object_key" ]] || { bad "respuesta incompleta"; return 1; }
  
  local form_args=()
  while IFS=$'\t' read -r k v; do [[ -n "$k" ]] && form_args+=(-F "$k=$v"); done < <(jq -r '.form_fields | to_entries[] | [.key,.value]|@tsv' <<<"$resp")
  
  local uc
  uc="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$upload_url" "${form_args[@]}" -F "file=@${fixture};type=application/pdf" || true)"
  [[ "$uc" =~ ^2[0-9][0-9]$ ]] || { bad "subida $uc"; return 1; }
  
  # Esperar COMPLETED
  local status="" txt_ref="" i
  for ((i=1;i<=180;i++)); do
    status="$(mongo_get "$doc_id" status)"
    txt_ref="$(mongo_get "$doc_id" txt_ref)"
    [[ "$status" == "COMPLETED" && -n "$txt_ref" ]] && break
    sleep 2
  done
  [[ "$status" == "COMPLETED" ]] || { bad "estado $status (esperado COMPLETED)"; return 1; }
  [[ -n "$txt_ref" ]] || { bad "txt_ref vacío"; return 1; }
  
  # Verificar .txt existe
  minio_exists "$txt_ref" || { bad ".txt no existe: $txt_ref"; return 1; }
  
  # Verificar descarga
  local dl
  dl="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$API_BASE/api/v2/documents/$doc_id/download" || true)"
  [[ "$dl" == "200" ]] || { bad "download $dl"; return 1; }
  
  pass "run $n: $doc_id COMPLETED txt=$txt_ref"
  mongo_eval "db.documents.deleteOne({_id:'$doc_id'})" >/dev/null 2>&1 || true
  minio_delete "$object_key" 2>/dev/null || true
  minio_delete "$txt_ref" 2>/dev/null || true
  return 0
}

log "Cadena real S3-P4-01 (requiere G-B)"
failures=0 blocked=0
for ((n=1;n<=RUNS;n++)); do
  if run_once "$n"; then :; else
    rc=$?
    if [[ $rc -eq 2 ]]; then blocked=$((blocked+1)); break; fi
    failures=$((failures+1))
  fi
done

if ((blocked>0)); then block "BLOQUEADO: extraction-worker ausente (G-B)"; exit 2; fi
if ((failures>0)); then bad "$failures fallos"; exit 1; fi
log "OK $RUNS/$RUNS"
