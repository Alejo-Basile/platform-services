#!/usr/bin/env bash
# Ejecuta la línea base de S0-P4-02: 3 corridas por escenario.
#
# Uso:
#   ./tests/k6/baseline/run-baseline.sh
#   BASE_URL=http://127.0.0.1:8000 ./tests/k6/baseline/run-baseline.sh
#
# Requisitos: k6 instalado y el monolito accesible en BASE_URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUT_DIR="$PLATFORM_ROOT/benchmarks/baseline"
EVID_DIR="$PLATFORM_ROOT/docs/evidencias/S0"
BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"

mkdir -p "$OUT_DIR" "$EVID_DIR"

command -v k6 >/dev/null 2>&1 || {
  echo "k6 no está instalado. Instálalo antes de correr la línea base." >&2
  exit 1
}

curl -sf --max-time 5 "$BASE_URL/health" >/dev/null || {
  echo "El monolito no responde en $BASE_URL/health. Levántalo antes de medir." >&2
  exit 1
}

for scenario in health registros pdf_process; do
  echo "[baseline] $scenario warm-up (10s)"
  k6 run \
    --duration 10s \
    --vus 1 \
    "$SCRIPT_DIR/${scenario}.js" \
    > "$EVID_DIR/S0-P4-02-k6-${scenario}-warmup.txt" 2>&1

  for run in 1 2 3; do
    echo "[baseline] $scenario run $run"
    k6 run \
      --out "json=$OUT_DIR/${scenario}-run${run}.json" \
      --summary-export "$OUT_DIR/${scenario}-run${run}-summary.json" \
      "$SCRIPT_DIR/${scenario}.js" \
      > "$EVID_DIR/S0-P4-02-k6-${scenario}-run${run}.txt" 2>&1
    gzip -9 -f "$OUT_DIR/${scenario}-run${run}.json"
  done
done

echo "[baseline] listo: $OUT_DIR"
