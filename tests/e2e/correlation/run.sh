#!/usr/bin/env bash
# E2E de trazabilidad por correlation_id (S3-P4-02).
#
# Uso:
#   tests/e2e/correlation/run.sh            # una corrida
#   tests/e2e/correlation/run.sh --runs 3   # tres corridas
#
# Requiere el stack `full` con extraction-worker (G-B cerrado). No levanta ni
# baja el stack: el workflow o el operador se encargan.
#
# DoD (pasos-iniciales.md S3-P4-02): "Subir un documento y comprobar que su
# correlation_id aparece en los logs de los 3 componentes. El test falla si el
# correlation_id no aparece en todos".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

RUNS=1
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  case "$arg" in
    --runs) j=$((i + 1)); RUNS="${!j:-1}"; i=$j ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      printf '[correlation] argumento desconocido: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '[correlation] %s\n' "$*"; }
pass() { printf '  [PASS] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; }
block() { printf '  [BLOCKED] %s\n' "$*"; }

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT)"
HTTPS_PORT="${HTTPS_PORT:-8543}"
API_BASE="https://api.localhost:${HTTPS_PORT}"
RESOLVE="api.localhost:${HTTPS_PORT}:127.0.0.1"
FIXTURE="$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf"

for tool in docker curl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || { bad "falta $tool"; exit 1; }
done
[[ -f "$ENV_FILE" ]] || { bad "falta $ENV_FILE"; exit 1; }
[[ -f "$FIXTURE" ]] || { bad "falta el fixture $FIXTURE"; exit 1; }

container_of() {
  compose ps -q "$1" 2>/dev/null | head -n1
}

# logs_contain <servicio> <texto> <epoch-desde>
logs_contain() {
  local svc="$1" needle="$2" since="$3" cid
  cid="$(container_of "$svc")"
  [[ -n "$cid" ]] || return 1
  docker logs --since "$since" "$cid" 2>&1 | grep -Fq -- "$needle"
}

# Los logs de los 3 componentes no se escriben en el mismo instante en que
# Mongo ya muestra COMPLETED; se reintenta con una ventana corta y acotada.
logs_contain_eventually() {
  local svc="$1" needle="$2" since="$3" tries="${4:-20}" i
  for ((i = 1; i <= tries; i++)); do
    logs_contain "$svc" "$needle" "$since" && return 0
    sleep 1
  done
  return 1
}

check_worker() {
  compose --profile full ps --services --status running 2>/dev/null \
    | grep -qx "extraction-worker"
}

run_once() {
  local n="$1" corr doc_id body upload status start
  corr="corr-$n-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
  doc_id="corr-$(date +%s)-$(openssl rand -hex 6)"
  body="$(jq -n --arg ik "$doc_id" --argjson sz "$(wc -c <"$FIXTURE" | tr -d ' ')" \
    '{idempotency_key:$ik, size_bytes:$sz}')"

  # Un segundo de margen: `docker logs --since` compara por timestamp de linea.
  start="$(( $(date +%s) - 1 ))"
  local create upload_url form_args=()
  create="$(curl -sk --fail-with-body --max-time 45 --resolve "$RESOLVE" \
    -X POST "$API_BASE/api/v2/documents" \
    -H 'Content-Type: application/json' -H "X-Correlation-Id: $corr" \
    -d "$body" 2>/dev/null)" || { bad "run $n: POST create fallo"; return 1; }

  upload_url="$(jq -r '.upload_url // empty' <<<"$create")"
  [[ -n "$upload_url" ]] || { bad "run $n: respuesta sin upload_url"; return 1; }
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && form_args+=(-F "$k=$v")
  done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' <<<"$create")

  upload="$(curl -sk --max-time 90 --resolve "$RESOLVE" -X POST "$upload_url" \
    "${form_args[@]}" -F "file=@${FIXTURE};type=application/pdf" \
    -o /dev/null -w '%{http_code}' || true)"
  [[ "$upload" =~ ^2[0-9][0-9]$ ]] || { bad "run $n: subida HTTP $upload"; return 1; }

  if wait_status "$doc_id" "COMPLETED" 30; then
    status="COMPLETED"
  else
    status="$(mongo_status "$doc_id")"
  fi
  [[ "$status" == "COMPLETED" ]] || { bad "run $n: estado final $status (esperado COMPLETED)"; return 1; }

  local missing=()
  [[ "$(mongo_get "$doc_id" correlation_id)" == "$corr" ]] || missing+=("mongo")
  logs_contain_eventually traefik "$corr" "$start" || missing+=("traefik")
  logs_contain_eventually doc-service "$corr" "$start" || missing+=("doc-service")
  logs_contain_eventually extraction-worker "$corr" "$start" || missing+=("extraction-worker")

  mongo_delete "$doc_id"
  if ((${#missing[@]} > 0)); then
    bad "run $n: correlation_id ausente en ${missing[*]}"
    return 1
  fi
  pass "run $n: $corr rastreado en mongo, traefik, doc-service y worker"
}

log "Trazabilidad S3-P4-02 (API_BASE=$API_BASE, proyecto=$PROJECT)"
if ! curl -sk --max-time 5 --resolve "$RESOLVE" "$API_BASE/healthz" >/dev/null; then
  bad "doc-service no responde"
  exit 1
fi
if ! check_worker; then
  block "extraction-worker no levantado (G-B requerido)"
  exit 2
fi

failures=0
for ((n = 1; n <= RUNS; n++)); do
  run_once "$n" || failures=$((failures + 1))
done

echo
if ((failures > 0)); then
  bad "$failures/$RUNS corridas sin trazabilidad completa"
  exit 1
fi
log "OK $RUNS/$RUNS"
