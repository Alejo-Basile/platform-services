#!/usr/bin/env bash
# Verificación de límite del gateway (S7-P4-04 / spec S4).
#
# Dispara peticiones a una tasa pautada durante una ventana fija y comprueba
# que pasen (200) exactamente las que permite el límite GCRA (burst + rate *
# duración) y el resto se rechace (429). Ejecuta RUNS corridas y reporta
# desviaciones por corrida y total; con los defaults (RUNS=10) evalúa el DoD
# "0 desviaciones en 10 ejecuciones".
#
# Uso:
#   ./tests/k6/ratelimit/run-limit-verification.sh
#   RUNS=1 ATTACK_RATE=20 DURATION_MS=10000 ./tests/k6/ratelimit/run-limit-verification.sh
#   ./tests/k6/ratelimit/run-limit-verification.sh --help
#
# Interfaz (variables de entorno):
#   BASE_URL            default https://api.localhost:8543
#   SCENARIO_PATH       ruta bajo el límite (default /api/v2/documents)
#   DOC_ID              opcional; si falta se crea un documento de prueba
#   RUN_ID              prefijo de trazabilidad (default p4-04-<epoch>-<pid>)
#   RUNS                corridas a ejecutar (default 10)
#   ATTACK_RATE         arribos por segundo que dispara k6 (default 20)
#   DURATION_MS         ventana del escenario en ms (default 10000)
#   TOTAL_REQUESTS      tope de peticiones esperadas (default ATTACK_RATE*DURATION/1000)
#   PRE_VUS             VUs preasignados (default max(20, ATTACK_RATE*3))
#   EXPECTED_RATE       rps del límite (default 10)
#   EXPECTED_BURST      burst del límite (default 20)
#   TOLERANCE           sub-aprobación admitida en tokens (default 3); la
#                       sobre-aprobación del límite nunca se tolera
#   REFILL_WAIT_S       espera para rellenar el bucket antes de cada corrida
#                       (default 3)
#   OUT_DIR             directorio de evidencia (default docs/evidencias/S7)
#
# La carga es pautada (constant-arrival-rate) a ATTACK_RATE durante
# DURATION_MS: el máximo teórico que pasa es burst + rate * duración. Así el
# esperado no depende de cuándo el gateway alcanzó a evaluar cada petición.
#
# Salida: bloque por corrida (allowed/denied/unexpected/dropped/desviación) +
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
  printf '  ATTACK_RATE=%s\n' '20'
  printf '  DURATION_MS=%s\n' '10000'
  printf '  TOTAL_REQUESTS=<default ATTACK_RATE*DURATION/1000>\n'
  printf '  PRE_VUS=<default max(20, ATTACK_RATE*3)>\n'
  printf '  EXPECTED_RATE=%s\n' '10'
  printf '  EXPECTED_BURST=%s\n' '20'
  printf '  TOLERANCE=%s\n' '3'
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
ATTACK_RATE="${ATTACK_RATE:-20}"
DURATION_MS="${DURATION_MS:-10000}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-$((ATTACK_RATE * DURATION_MS / 1000))}"
PRE_VUS="${PRE_VUS:-$((ATTACK_RATE * 3 > 20 ? ATTACK_RATE * 3 : 20))}"
RUNS="${RUNS:-10}"
EXPECTED_RATE="${EXPECTED_RATE:-10}"
EXPECTED_BURST="${EXPECTED_BURST:-20}"
TOLERANCE="${TOLERANCE:-3}"
REFILL_WAIT_S="${REFILL_WAIT_S:-3}"
OUT_DIR="${OUT_DIR:-$PLATFORM_ROOT/docs/evidencias/S7}"

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  RUNS=10
fi
if ! [[ "$ATTACK_RATE" =~ ^[1-9][0-9]*$ ]]; then
  ATTACK_RATE=20
fi
if ! [[ "$DURATION_MS" =~ ^[1-9][0-9]*$ ]]; then
  DURATION_MS=10000
fi
if ! [[ "$TOTAL_REQUESTS" =~ ^[1-9][0-9]*$ ]]; then
  TOTAL_REQUESTS=$((ATTACK_RATE * DURATION_MS / 1000))
fi
if ! [[ "$PRE_VUS" =~ ^[1-9][0-9]*$ ]]; then
  PRE_VUS=20
fi
if ! [[ "$TOLERANCE" =~ ^[0-9]+$ ]]; then
  TOLERANCE=3
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
  printf '# RUN_ID=%s RUNS=%s ATTACK_RATE=%s/s DURATION_MS=%s TOTAL_REQUESTS=%s PRE_VUS=%s\n' \
    "$RUN_ID" "$RUNS" "$ATTACK_RATE" "$DURATION_MS" "$TOTAL_REQUESTS" "$PRE_VUS"
  printf '# Límite esperado: rate=%s/s burst=%s TOLERANCE=%s (REFILL_WAIT_S=%s)\n' \
    "$EXPECTED_RATE" "$EXPECTED_BURST" "$TOLERANCE" "$REFILL_WAIT_S"
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
      ATTACK_RATE="$ATTACK_RATE" DURATION="${DURATION_MS}ms" PRE_VUS="$PRE_VUS" \
      k6 run --summary-export "$summary" "$SCRIPT_DIR/limit-verification.js" \
      >> "$RAW" 2>&1 || k6_rc=$?

    # k6 v2 exporta los contadores planos (.count); versiones viejas los
    # anidaban en .values.count. Soportar ambos evita el -1 silencioso.
    summary_values=''
    if [[ -s "$summary" ]]; then
      summary_values="$(jq -r '[
        (.metrics.allowed_total.count // .metrics.allowed_total.values.count // -1 | floor),
        (.metrics.denied_total.count // .metrics.denied_total.values.count // -1 | floor),
        (.metrics.unexpected_status_total.count // .metrics.unexpected_status_total.values.count // -1 | floor),
        (.metrics.dropped_iterations.count // .metrics.dropped_iterations.values.count // 0 | floor)
      ] | @tsv' "$summary" 2>/dev/null || true)"
    fi
    [[ -n "$summary_values" ]] || summary_values=$'-1\t-1\t-1\t0'
    IFS=$'\t' read -r allowed denied unexpected dropped <<<"$summary_values"

    allowed="$(limits_integer_or "$allowed" -1)"
    denied="$(limits_integer_or "$denied" -1)"
    unexpected="$(limits_integer_or "$unexpected" -1)"
    dropped="$(limits_integer_or "$dropped" 0)"

    # k6 emite un arribo por período más el inicial (rate*duración + 1), así
    # que el total observado es la referencia para el esperado de denied.
    observed_total=$((allowed + denied + unexpected))
    if ((observed_total <= 0)); then
      observed_total="$TOTAL_REQUESTS"
    fi
    expected_allowed="$(limits_expected_paced \
      "$EXPECTED_BURST" "$EXPECTED_RATE" "$DURATION_MS" "$observed_total")"
    expected_denied=$((observed_total - expected_allowed))
    deviation="$(limits_deviation_tolerant \
      "$allowed" "$expected_allowed" "$denied" "$expected_denied" "$unexpected" "$TOLERANCE")"
    if ((k6_rc != 0 || dropped != 0)); then
      deviation=1
    fi

    total_deviations=$((total_deviations + deviation))
    if [[ "$deviation" != '0' ]]; then
      deviating_runs="${deviating_runs:+$deviating_runs,}$run"
    fi

    printf 'run %d/%d allowed=%s expected_allowed=%s denied=%s expected_denied=%s unexpected=%s dropped=%s tolerance=%s k6_rc=%s deviation=%s\n' \
      "$run" "$RUNS" "$allowed" "$expected_allowed" "$denied" \
      "$expected_denied" "$unexpected" "$dropped" "$TOLERANCE" "$k6_rc" "$deviation"
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
