#!/usr/bin/env bash
# Prueba de concurrencia de S1-P4-02.
# Requiere el wrapper ratelimitd escuchando en BASE_URL y Redis accesible.
#
# Uso:
#   ./tests/k6/ratelimit/run.sh
#   BASE_URL=http://127.0.0.1:8090 ./tests/k6/ratelimit/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EVID_DIR="$PLATFORM_ROOT/docs/evidencias/S1"
BASE_URL="${BASE_URL:-http://127.0.0.1:8090}"
RUN_ID="${RUN_ID:-$(date +%s)}"

mkdir -p "$EVID_DIR"

command -v k6 >/dev/null 2>&1 || {
  echo "k6 no está instalado." >&2
  exit 1
}

curl -sf --max-time 3 "$BASE_URL/healthz" >/dev/null || {
  echo "ratelimitd no responde en $BASE_URL/healthz." >&2
  exit 1
}

OUT="$EVID_DIR/S1-P4-02-lua-concurrency.txt"
{
  echo "# S1-P4-02 — 100 clientes concurrentes"
  echo "# Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# BASE_URL=$BASE_URL RUN_ID=$RUN_ID"
  echo "# Comando: k6 run tests/k6/ratelimit/concurrency.js"
  echo
  BASE_URL="$BASE_URL" RUN_ID="$RUN_ID" k6 run "$SCRIPT_DIR/concurrency.js"
} 2>&1 | tee "$OUT"

echo "[ratelimit] evidencia: $OUT"
