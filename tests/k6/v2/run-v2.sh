#!/usr/bin/env bash
# Benchmark API-level v2 (S2-P4-02): 3 corridas por escenario en host fijo.
#
# Uso:
#   ./tests/k6/v2/run-v2.sh
#   BASE_URL=https://api.localhost:8543 ./tests/k6/v2/run-v2.sh
#
# No mide la cadena completa: falta worker (G-B). Mide health, creación,
# prefirma, estado y listado.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUT_DIR="$PLATFORM_ROOT/benchmarks/v2"
EVID_DIR="$PLATFORM_ROOT/docs/evidencias/S2"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
RUN_ID="${RUN_ID:-v2-$(date +%s)}"
export RUN_ID

mkdir -p "$OUT_DIR" "$EVID_DIR"

command -v k6 >/dev/null 2>&1 || {
  printf 'k6 no esta instalado.\n' >&2
  exit 1
}

curl -sk --max-time 5 "$BASE_URL/healthz" >/dev/null || {
  printf 'doc-service no responde en %s/healthz.\n' "$BASE_URL" >&2
  exit 1
}

failures=0
for scenario in health list create state; do
  # Regla congelada: p95 <= 1,2x baseline. `list` tiene baseline equivalente
  # (`/registros`, 210,5 ms -> 252,6 ms). `health` queda condicionado a la
  # decision de P1 sobre Traefik: exportar P4_HEALTH_P95_MS=44.52 para activarlo.
  # `create`/`state` no tienen baseline equivalente y no aplican p95.
  case "$scenario" in
    list) p95_ms="252.6" ;;
    health) p95_ms="${P4_HEALTH_P95_MS:-0}" ;;
    *) p95_ms="0" ;;
  esac

  printf '[v2] %s warm-up (10s)\n' "$scenario"
  RUN_ID="${RUN_ID}-${scenario}-warmup" P95_MS=0 k6 run \
    --no-thresholds \
    --duration 10s \
    --vus 1 \
    "$SCRIPT_DIR/${scenario}.js" \
    > "$EVID_DIR/S2-P4-02-k6-${scenario}-warmup.txt" 2>&1

  for run in 1 2 3; do
    printf '[v2] %s run %s (p95_ms=%s)\n' "$scenario" "$run" "$p95_ms"
    RUN_ID="${RUN_ID}-${scenario}-${run}" P95_MS="$p95_ms" k6 run \
      --out "json=$OUT_DIR/${scenario}-run${run}.json" \
      --summary-export "$OUT_DIR/${scenario}-run${run}-summary.json" \
      "$SCRIPT_DIR/${scenario}.js" \
      > "$EVID_DIR/S2-P4-02-k6-${scenario}-run${run}.txt" 2>&1 \
      || failures=$((failures + 1))
    gzip -9 -f "$OUT_DIR/${scenario}-run${run}.json"
  done
done

if ((failures > 0)); then
  printf '[v2] %s corrida(s) incumplieron thresholds\n' "$failures" >&2
  exit 1
fi

printf '[v2] listo: %s\n' "$OUT_DIR"
