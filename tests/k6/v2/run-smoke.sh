#!/usr/bin/env bash
# Smoke de carga para CI: no compara con la baseline; solo detecta errores
# funcionales bajo concurrencia mínima.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
RUN_ID="${RUN_ID:-ci-$(date +%s)}"
export RUN_ID BASE_URL

command -v k6 >/dev/null 2>&1 || {
  printf 'k6 no esta instalado.\n' >&2
  exit 1
}

curl -sk --max-time 5 "$BASE_URL/healthz" >/dev/null || {
  printf 'doc-service no responde en %s/healthz.\n' "$BASE_URL" >&2
  exit 1
}

for scenario in health create state list; do
  printf '[k6-smoke] %s\n' "$scenario"
  RUN_ID="${RUN_ID}-${scenario}" k6 run --duration 5s --vus 1 "$SCRIPT_DIR/${scenario}.js"
done
