#!/usr/bin/env bash
# Orquestador carga S5-P4-01
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOCS="${DOCS:-1000}"
VUS="${VUS:-20}"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
OUT_DIR="$PLATFORM_ROOT/docs/evidencias/S5"
mkdir -p "$OUT_DIR"

log(){ printf '[load] %s\n' "$*"; }
fail(){ printf '[load] ERROR: %s\n' "$*" >&2; exit 1; }

command -v k6 >/dev/null 2>&1 || fail "falta k6"

RUN_ID="s5-p4-01-$(date +%s)"
export RUN_ID
export BASE_URL
export PRE_VUS="$VUS"
export MAX_VUS=$((VUS*2))
export RATE_TARGET=$((DOCS/60))
export RAMP_DURATION="15m"
EXPECTED_TERMINAL="${EXPECTED_TERMINAL:-4}"
export EXPECTED_TERMINAL
export FIXTURE="${FIXTURE:-$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf}"
SUMMARY_JSON="$OUT_DIR/S5-P4-01-k6-summary.json"

SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export P4_LOAD_SINCE="$SINCE"

log "Iniciando carga $DOCS docs (target ~${RATE_TARGET}/s) con VUs $VUS"
k6 run \
  --out "json=$OUT_DIR/S5-P4-01-k6.json" \
  --summary-export "$SUMMARY_JSON" \
  "$SCRIPT_DIR/pipeline.js" 2>&1 | tee "$OUT_DIR/S5-P4-01-k6-run.txt"
K6_EXIT=${PIPESTATUS[0]}
set +e
TERMINAL=0
if [ -f "$SUMMARY_JSON" ]; then
  TERMINAL=$(jq -r '(.metrics.terminal_documents.values.count // .metrics.terminal_documents.count) // 0' "$SUMMARY_JSON" 2>/dev/null || echo 0)
fi
printf '[load] terminal=%s/%s\n' "$TERMINAL" "$EXPECTED_TERMINAL"
if [ "$K6_EXIT" -ne 0 ]; then fail "k6 finalizo con exit=$K6_EXIT"; fi
if [ "$TERMINAL" -lt "$EXPECTED_TERMINAL" ]; then fail "solo $TERMINAL/$EXPECTED_TERMINAL documentos alcanzaron estado terminal"; fi
set -e

log "Generando reporte Mongo"
"$SCRIPT_DIR/report.sh" "$OUT_DIR/S5-P4-01-k6.json" 2>&1 | tee "$OUT_DIR/S5-P4-01-report-gen.txt"

log "Listo. Ver: $OUT_DIR/S5-P4-01-report.md"
