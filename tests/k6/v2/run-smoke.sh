#!/usr/bin/env bash
# Smoke funcional v2: valida contrato y errores bajo concurrencia mínima.
#
# El gateway aplica un límite global ForwardAuth de rate=10/s y burst=20
# (infra/traefik/dynamic/middlewares.yml). Este smoke debe quedar por debajo
# de ese límite para que un 429 sea un fallo real. El escenario que espera 429
# es tests/k6/ratelimit/gateway.js; no se traslada esa expectativa aquí.
#
# Parámetros del escenario create (todos opcionales):
#   CREATE_RATE              llegadas por segundo (default 5; mantener < 10)
#   CREATE_DURATION          duración del escenario (default 5s para CI)
#   CREATE_PREALLOCATED_VUS  VUs reservadas para la tasa (default 2)
#   CREATE_MAX_VUS           VUs máximas (default 5)
#
# Con los valores por defecto: 5 llegadas/s durante 5s => ~25 iteraciones, con
# un margen de 2x respecto del límite de 10/s. El resumen de k6 muestra las
# iteraciones realmente ejecutadas.
#
# state y list comparten el mismo límite global del gateway. run-smoke los
# ejecuta con 1 VU durante 5s y les aplica un piso por iteración
# (SMOKE_MIN_ITERATION_DURATION, default 1200ms) para que un VU sin pausa no
# supere 10 requests/s. El mismo piso alcanza para los escenarios originales
# de 5 VUs (state) y 10 VUs (list) si se ejecutan sin --vus/--duration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
RUN_ID="${RUN_ID:-ci-$(date +%s)}"
# Traefik aplica rate-limit@file (forwardAuth, 10 rps / burst 20) a /api/v2.
# El smoke mantiene el ritmo por debajo del limite con constant-arrival-rate
# (create) y min-iteration-duration (state/list); las corridas de carga
# (run-v2.sh) no usan estos frenos.
CREATE_RATE="${CREATE_RATE:-5}"
CREATE_DURATION="${CREATE_DURATION:-5s}"
CREATE_PREALLOCATED_VUS="${CREATE_PREALLOCATED_VUS:-2}"
CREATE_MAX_VUS="${CREATE_MAX_VUS:-5}"
SMOKE_MIN_ITERATION_DURATION="${SMOKE_MIN_ITERATION_DURATION:-1200ms}"
export RUN_ID BASE_URL CREATE_RATE CREATE_DURATION CREATE_PREALLOCATED_VUS CREATE_MAX_VUS
export SMOKE_MIN_ITERATION_DURATION

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
  case "$scenario" in
    create)
      # constant-arrival-rate hace explícita la tasa y la mantiene bajo el límite.
      printf '[k6-smoke] create rate=%s/s duration=%s (gateway limit 10/s burst 20)\n' \
        "$CREATE_RATE" "$CREATE_DURATION"
      RUN_ID="${RUN_ID}-${scenario}" P95_MS=0 k6 run "$SCRIPT_DIR/create.js"
      ;;
    state|list)
      # El límite del gateway es global: frenar estas iteraciones evita 429
      # sin tocar sus escenarios ni sus thresholds.
      printf '[k6-smoke] %s min_iteration_duration=%s (gateway limit 10/s)\n' \
        "$scenario" "$SMOKE_MIN_ITERATION_DURATION"
      RUN_ID="${RUN_ID}-${scenario}" P95_MS=0 k6 run \
        --duration 5s --vus 1 \
        --min-iteration-duration "$SMOKE_MIN_ITERATION_DURATION" \
        "$SCRIPT_DIR/${scenario}.js"
      ;;
    *)
      RUN_ID="${RUN_ID}-${scenario}" P95_MS=0 k6 run \
        --duration 5s --vus 1 "$SCRIPT_DIR/${scenario}.js"
      ;;
  esac
done
