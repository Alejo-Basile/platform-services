#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EVID_DIR="$PLATFORM_ROOT/docs/evidencias/S5"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
RUN_ID="${RUN_ID:-p4-06-gateway-$(date +%s)-$$}"
OUT="$EVID_DIR/S5-P4-06-k6-ratelimit-gateway.txt"

mkdir -p "$EVID_DIR"

for command_name in curl jq k6; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s no está instalado.\n' "$command_name" >&2
    exit 1
  }
done

curl -sk --max-time 5 "$BASE_URL/healthz" >/dev/null || {
  printf 'doc-service no responde en %s/healthz.\n' "$BASE_URL" >&2
  exit 1
}

# La clave del middleware actual es compartida; dejar que el bucket se reponga.
sleep 3

create_payload="$(jq -n --arg idempotency_key "$RUN_ID" --argjson size_bytes 1 \
  '{idempotency_key: $idempotency_key, size_bytes: $size_bytes}')"
create_response="$(curl -sk --fail-with-body --max-time 20 \
  -X POST "$BASE_URL/api/v2/documents" \
  -H 'Content-Type: application/json' \
  -H "X-Correlation-Id: $RUN_ID" \
  -d "$create_payload")" || {
  printf 'No se pudo crear el documento de prueba.\n' >&2
  exit 1
}

document_id="$(jq -r '.document_id // empty' <<<"$create_response")"
[[ -n "$document_id" ]] || {
  printf 'La respuesta de creación no incluyó document_id.\n' >&2
  exit 1
}

under_limit_status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
  "$BASE_URL/api/v2/documents/$document_id")"
[[ "$under_limit_status" == "200" ]] || {
  printf 'La petición bajo el límite devolvió HTTP %s, esperado 200.\n' "$under_limit_status" >&2
  exit 1
}

{
  printf '# P4-06 — rate-limit del gateway\n'
  printf '# Fecha UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# RUN_ID=%s\n' "$RUN_ID"
  printf '# Petición bajo el límite: HTTP %s\n\n' "$under_limit_status"
  cd "$PLATFORM_ROOT"
  BASE_URL="$BASE_URL" DOC_ID="$document_id" k6 run tests/k6/ratelimit/gateway.js
} 2>&1 | tee "$OUT"

printf '[ratelimit-gateway] evidencia: %s\n' "$OUT"
