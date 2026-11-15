#!/usr/bin/env bash
# Verificación de límite del gateway (S7-P4-04 / spec S4).
#
# Dispara TOTAL_REQUESTS peticiones en ráfaga por corrida y comprueba que
# exactamente el límite esperado pase (200) y el resto se rechace (429).
# Ejecuta RUNS corridas y reporta desviaciones por corrida y total; con los
# defaults (RUNS=10) evalúa el DoD "0 desviaciones en 10 ejecuciones".
#
# Uso:
#   ./tests/k6/ratelimit/run-limit-verification.sh
#   RUNS=1 TOTAL_REQUESTS=100 ./tests/k6/ratelimit/run-limit-verification.sh
#   ./tests/k6/ratelimit/run-limit-verification.sh --help
#
# Interfaz (variables de entorno):
#   BASE_URL            default https://api.localhost:8543
#   SCENARIO_PATH       ruta bajo el límite (default /api/v2/documents)
#   DOC_ID              opcional; si falta se crea un documento de prueba
#   RUN_ID              prefijo de trazabilidad (default p4-04-<epoch>-<pid>)
#   RUNS                corridas a ejecutar (default 10)
#   TOTAL_REQUESTS      peticiones por corrida (default 100)
#   VUS                 VUs concurrentes (default = TOTAL_REQUESTS)
#   EXPECTED_RATE       rps del límite (default 10)
#   EXPECTED_BURST      burst del límite (default 20)
#   EXPECTED_WINDOW_MS  si se fija, ignora la ventana medida por k6
#   REFILL_WAIT_S       espera para rellenar el bucket antes de cada corrida
#                       (default 3)
#   OUT_DIR             directorio de evidencia (default docs/evidencias/S7)
#
# Salida: bloque por corrida (allowed/denied/unexpected/ventana/desviación) +
# resumen total. Exit 0 si el total de desvíos es 0; exit 1 si alguna corrida
# se desvió o falta una herramienta. El detalle crudo de k6 queda en
# $OUT_DIR/S7-P4-04-k6-limit-verification-k6.log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/limits.sh
source "$SCRIPT_DIR/lib/limits.sh"

usage() {
  printf 'Uso: %s [--help]\n\n' "$(basename "$0")"
  printf 'Variables de entorno (todas opcionales):\n'
  printf '  BASE_URL=%s\n' "https://api.localhost:8543"
  printf '  SCENARIO_PATH=%s\n' '/api/v2/documents'
  printf '  DOC_ID=<opcional; se crea si falta>\n'
  printf '  RUNS=%s\n' '10'
  printf '  TOTAL_REQUESTS=%s\n' '100'
  printf '  VUS=<default TOTAL_REQUESTS>\n'
  printf '  EXPECTED_RATE=%s\n' '10'
  printf '  EXPECTED_BURST=%s\n' '20'
  printf '  EXPECTED_WINDOW_MS=<opcional; default ventana medida>\n'
  printf '  REFILL_WAIT_S=%s\n' '3'
  printf '  OUT_DIR=%s\n' 'docs/evidencias/S7'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '') ;;
  *)
    printf 'Argumento no reconocido: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

BASE_URL="${BASE_URL:-https://api.localhost:8543}"
SCENARIO_PATH="${SCENARIO_PATH:-/api/v2/documents}"
DOC_ID="${DOC_ID:-}"
RUN_ID="${RUN_ID:-p4-04-$(date +%s)-$$}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-100}"
VUS="${VUS:-$TOTAL_REQUESTS}"
RUNS="${RUNS:-10}"
EXPECTED_RATE="${EXPECTED_RATE:-10}"
EXPECTED_BURST="${EXPECTED_BURST:-20}"
EXPECTED_WINDOW_MS="${EXPECTED_WINDOW_MS:-}"
REFILL_WAIT_S="${REFILL_WAIT_S:-3}"
OUT_DIR="${OUT_DIR:-$PLATFORM_ROOT/docs/evidencias/S7}"

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  RUNS=10
fi
if ! [[ "$TOTAL_REQUESTS" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL_REQUESTS=100
fi
if ! [[ "$VUS" =~ ^[1-9][0-9]*$ ]]; then
  VUS="$TOTAL_REQUESTS"
fi

for command_name in awk curl jq k6; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s no está instalado.\n' "$command_name" >&2
    exit 1
  }
done

curl -sk --max-time 5 "$BASE_URL/healthz" >/dev/null || {
  printf 'doc-service no responde en %s/healthz.\n' "$BASE_URL" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/S7-P4-04-k6-limit-verification.txt"
RAW="$OUT_DIR/S7-P4-04-k6-limit-verification-k6.log"
: > "$RAW"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

create_document() {
  local payload response document_id
  payload="$(jq -n --arg key "${RUN_ID}-doc" --argjson size 1 \
    '{idempotency_key: $key, size_bytes: $size}')"
  response="$(curl -sk --fail-with-body --max-time 20 \
    -X POST "$BASE_URL/api/v2/documents" \
    -H 'Content-Type: application/json' \
    -H "X-Correlation-Id: $RUN_ID" \
    -d "$payload")" || return 1
  document_id="$(jq -r '.document_id // empty' <<<"$response")"
  [[ -n "$document_id" ]] || return 1
  printf '%s' "$document_id"
}

if [[ -z "$DOC_ID" ]]; then
  printf '[limit-verification] rellenando bucket antes de crear documento...\n' >&2
  sleep "$REFILL_WAIT_S"
  DOC_ID="$(create_document)" || {
    printf 'No se pudo crear el documento de prueba.\n' >&2
    exit 1
  }
fi

total_deviations=0
deviating_runs=''

{
  printf '# S7-P4-04 — verificación de límite del gateway\n'
  printf '# Fecha UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# RUN_ID=%s RUNS=%s TOTAL_REQUESTS=%s VUS=%s\n' \
    "$RUN_ID" "$RUNS" "$TOTAL_REQUESTS" "$VUS"
  printf '# Límite esperado: rate=%s/s burst=%s (REFILL_WAIT_S=%s)\n' \
    "$EXPECTED_RATE" "$EXPECTED_BURST" "$REFILL_WAIT_S"
  printf '# BASE_URL=%s SCENARIO_PATH=%s DOC_ID=%s\n\n' \
    "$BASE_URL" "$SCENARIO_PATH" "$DOC_ID"

  for ((run = 1; run <= RUNS; run++)); do
    printf '[limit-verification] corrida %d/%d (relleno %ss)\n' \
      "$run" "$RUNS" "$REFILL_WAIT_S" >&2
    sleep "$REFILL_WAIT_S"

    summary="$tmp_dir/run-${run}-summary.json"
    k6_rc=0
    RUN_ID="${RUN_ID}-run${run}" \
      BASE_URL="$BASE_URL" SCENARIO_PATH="$SCENARIO_PATH" DOC_ID="$DOC_ID" \
      TOTAL_REQUESTS="$TOTAL_REQUESTS" VUS="$VUS" \
      k6 run --summary-export "$summary" "$SCRIPT_DIR/limit-verification.js" \
      >> "$RAW" 2>&1 || k6_rc=$?

    summary_values=''
    if [[ -s "$summary" ]]; then
      summary_values="$(jq -r '[
        (.metrics.allowed_total.values.count // -1 | floor),
        (.metrics.denied_total.values.count // -1 | floor),
        (.metrics.unexpected_status_total.values.count // -1 | floor),
        (.metrics.request_start_offset_ms.values.min // 0),
        (.metrics.request_end_offset_ms.values.max // 0)
      ] | @tsv' "$summary" 2>/dev/null || true)"
    fi
    [[ -n "$summary_values" ]] || summary_values=$'-1\t-1\t-1\t0\t0'
    IFS=$'\t' read -r allowed denied unexpected start_min end_max <<<"$summary_values"

    allowed="$(limits_integer_or "$allowed" -1)"
    denied="$(limits_integer_or "$denied" -1)"
    unexpected="$(limits_integer_or "$unexpected" -1)"
    window_ms="$(awk -v a="$start_min" -v b="$end_max" \
      'BEGIN { ms = b - a; if (ms < 0) ms = 0; printf "%d", ms }')"
    if [[ "$EXPECTED_WINDOW_MS" =~ ^[0-9]+$ ]]; then
      window_ms="$EXPECTED_WINDOW_MS"
    fi

    expected_allowed="$(limits_expected_allowed \
      "$EXPECTED_BURST" "$EXPECTED_RATE" "$window_ms" "$TOTAL_REQUESTS")"
    expected_denied=$((TOTAL_REQUESTS - expected_allowed))
    deviation="$(limits_deviation \
      "$allowed" "$expected_allowed" "$denied" "$expected_denied" "$unexpected")"
    if ((k6_rc != 0)); then
      deviation=1
    fi

    total_deviations=$((total_deviations + deviation))
    if [[ "$deviation" != '0' ]]; then
      deviating_runs="${deviating_runs:+$deviating_runs,}$run"
    fi

    printf 'run %d/%d allowed=%s expected_allowed=%s denied=%s expected_denied=%s unexpected=%s window_ms=%s k6_rc=%s deviation=%s\n' \
      "$run" "$RUNS" "$allowed" "$expected_allowed" "$denied" \
      "$expected_denied" "$unexpected" "$window_ms" "$k6_rc" "$deviation"
  done

  printf '\ntotal_runs=%s total_deviations=%s\n' "$RUNS" "$total_deviations"
  printf 'deviating_runs=%s\n' "${deviating_runs:-ninguna}"
} > "$OUT"

cat "$OUT"
printf '\n[limit-verification] evidencia: %s\n' "$OUT"
printf '[limit-verification] k6 crudo: %s\n' "$RAW"

if ((total_deviations > 0)); then
  printf '[limit-verification] %s corrida(s) con desviación.\n' "$total_deviations" >&2
  exit 1
fi

printf '[limit-verification] 0 desviaciones en %s corrida(s).\n' "$RUNS"
