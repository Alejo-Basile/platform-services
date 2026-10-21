#!/usr/bin/env bash
# Fuzzing de contrato (S1-P4-03) con Schemathesis fijado por versión.
#
# Uso:
#   python3 -m venv .venv && . .venv/bin/activate
#   python3 -m pip install -r tests/contract/requirements.txt
#   ./tests/contract/run.sh
#
# Variables:
#   BASE_URL  URL del gateway (default: https://api.localhost:8543)
#   CASES     Casos por operación; 4 operaciones x 250 = 1000 (default: 250)
#   OUT       Archivo de salida de texto
#   REPORT    Archivo JSON del reporte
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPEC="$ROOT/openapi/documents.yaml"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
CASES="${CASES:-250}"
SEED="${SEED:-20261021}"
OUT="${OUT:-$ROOT/docs/evidencias/S1/S1-P4-03-fuzz.txt}"
REPORT="${REPORT:-$ROOT/docs/evidencias/S1/S1-P4-03-fuzz-report.json}"

command -v schemathesis >/dev/null 2>&1 || {
  echo "ERROR: falta schemathesis. Instala: python3 -m pip install -r tests/contract/requirements.txt" >&2
  exit 2
}

INSTALLED="$(schemathesis --version 2>/dev/null | head -n1 || true)"
case "$INSTALLED" in
  *4.32.2*) ;;
  *) echo "AVISO: versión instalada '$INSTALLED' != 4.32.2; la evidencia puede no ser comparable" >&2 ;;
esac

mkdir -p "$(dirname "$OUT")" "$(dirname "$REPORT")"
schemathesis run "$SPEC" \
  --url "$BASE_URL" \
  --tls-verify false \
  --checks not_a_server_error \
  --phases fuzzing \
  -n "$CASES" \
  --seed "$SEED" \
  --generation-deterministic \
  --max-failures 5 \
  --report json \
  --report-json-path "$REPORT" \
  --no-color 2>&1 | tee "$OUT"
