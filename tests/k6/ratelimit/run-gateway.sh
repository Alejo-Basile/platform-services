#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://127.0.0.1:8543}"
HOST_HEADER="${HOST_HEADER:-api.localhost}"
TARGET_PATH="${TARGET_PATH:-/api/v2/documents}"

export BASE_URL HOST_HEADER TARGET_PATH

# Preflight
code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${HOST_HEADER}" "${BASE_URL}/healthz" || true)
if [ "${code}" != "200" ]; then
  echo "Preflight failed: ${BASE_URL}/healthz returned ${code}" >&2
  exit 1
fi

sleep 3

EVIDENCE_DIR="docs/evidencias/S7"
mkdir -p "${EVIDENCE_DIR}"
EVIDENCE_FILE="${EVIDENCE_DIR}/S7-P4-k6-gateway.txt"

{
  echo "UTC date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "command: k6 run tests/k6/ratelimit/gateway.js"
  echo "BASE_URL: ${BASE_URL}"
  echo "TARGET_PATH: ${TARGET_PATH}"
  echo "---"
  k6 run tests/k6/ratelimit/gateway.js
} | tee "${EVIDENCE_FILE}"

# propagate k6 exit code (pipefail already set)
