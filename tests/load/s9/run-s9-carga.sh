#!/usr/bin/env bash
# S9-P1-CARGA — carga final del stack nuevo (plan-S9-P1.md §4.4).
#
# Reutiliza los escenarios k6 ya existentes (tests/k6/v2, tests/k6/ratelimit,
# tests/e2e/load) pero escribe TODO su salida bajo benchmarks/s9/<RUN_ID>/, para
# no sobrescribir la evidencia archivada de S1, S2 y S5 que esos arneses
# originales escriben en sus propios directorios.
#
# Modos (se ejecutan en este orden; `all` los corre todos):
#   precheck    stack + readyz + short smoke de /healthz
#   run1        matriz v2: health, list, create, state (warm-up + 3 corridas c/u)
#   run2        pipeline E2E: create -> upload -> poll hasta estado terminal
#   run3        rate limit en el borde: ForwardAuth + 429 + Retry-After
#   run1-scenario  repite un escenario solo (SCENARIO=, TAG=, REPEAT=) para
#               reintentar una corrida roja por un evento transitorio
#   postcheck   conteos por estado, no terminales, DLQ y alertas Prometheus
#   metrics     tabla de metricas por cada *-summary.json bajo OUT_DIR (recursivo)
#
# Uso:
#   BASE_URL=https://api.localhost:8543 ./tests/load/s9/run-s9-carga.sh run1
#   DOCS=1000 VUS=20 ./tests/load/s9/run-s9-carga.sh run2
#
# Volumen de run2: DOCS es el volumen acordado para la corrida y RATE_TARGET
# deriva de el (DOCS/60). DOCS/60 asume una ventana de 60s, pero el pipeline
# rampa a lo largo de PIPELINE_RAMP (default 15m); se puede sobreescribir con
# RATE_TARGET=1.1 y RATE_START para mantener la primera etapa bajo el limite
# del edge. El numero real de documentos creados se mide y se registra tal cual;
# no se presenta como equivalente al volumen nominal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
K6_DIR="$PLATFORM_ROOT/tests/k6"
E2E_DIR="$PLATFORM_ROOT/tests/e2e"
BASE_URL="${BASE_URL:-https://api.localhost:8543}"
RUN_ID="${RUN_ID:-s9-carga-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_DIR="${OUT_DIR:-$PLATFORM_ROOT/benchmarks/s9/$RUN_ID}"
MODE="${1:-all}"

DOCS="${DOCS:-1000}"
VUS="${VUS:-20}"
PIPELINE_RAMP="${PIPELINE_RAMP:-15m}"
EXPECTED_TERMINAL="${EXPECTED_TERMINAL:-4}"
FIXTURE="${FIXTURE:-$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf}"
P4_HEALTH_P95_MS="${P4_HEALTH_P95_MS:-0}"

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"

log() { printf '[s9-carga] %s\n' "$*" | tee -a "$LOG"; }
fail() { printf '[s9-carga] ERROR: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

command -v k6 >/dev/null 2>&1 || fail "k6 no esta instalado"
command -v jq >/dev/null 2>&1 || fail "jq no esta instalado"

# shellcheck source=../../e2e/lib.sh
source "$E2E_DIR/lib.sh"
COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

precheck() {
  log "precheck: stack"
  compose ps >>"$LOG" 2>&1
  local ready code
  ready="$(docker exec infra-doc-service-1 wget -qO- http://localhost:8080/readyz 2>&1 || true)"
  log "readyz: $ready"
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/healthz" || true)"
  log "GET $BASE_URL/healthz -> $code"
  [[ "$code" == "200" ]] || fail "el stack no responde en $BASE_URL/healthz"
}

# Parametros por escenario de la matriz v2: umbral p95 y pausa por iteracion.
# El ForwardAuth del borde (rate=10/s, burst=20) comparte un unico bucket para
# /api/v2/*. list y state corren a decenas de rps con el codigo actual, asi que
# sin pausa el 429 del limitador -que es intencional- tumba los thresholds de la
# matriz. La pausa deja la matriz por debajo del limite del borde: mide latencia
# de la aplicacion, no shedding. run3 mide el 429. create queda sin pausa: usa
# constant-arrival-rate a 5/s por defecto.
scenario_params() {
  case "$1" in
    list) SC_P95_MS="252.6"; SC_SLEEP="${S9_LIST_SLEEP:-1.5}" ;;
    state) SC_P95_MS="0"; SC_SLEEP="${S9_STATE_SLEEP:-1.5}" ;;
    health) SC_P95_MS="$P4_HEALTH_P95_MS"; SC_SLEEP=0 ;;
    *) SC_P95_MS="0"; SC_SLEEP=0 ;;
  esac
}

run1() {
  log "run1: matriz v2 BASE_URL=$BASE_URL OUT_DIR=$OUT_DIR/v2"
  mkdir -p "$OUT_DIR/v2"
  curl -sk --max-time 5 "$BASE_URL/healthz" >/dev/null || fail "doc-service no responde"
  local failures=0 scenario p95_ms sleep_s run
  for scenario in health list create state; do
    scenario_params "$scenario"
    p95_ms="$SC_P95_MS"; sleep_s="$SC_SLEEP"
    log "run1 $scenario warm-up (10s)"
    RUN_ID="$RUN_ID-$scenario-warmup" P95_MS=0 SMOKE_SLEEP="$sleep_s" k6 run \
      --no-thresholds --duration 10s --vus 1 \
      "$K6_DIR/v2/${scenario}.js" \
      >"$OUT_DIR/v2/${scenario}-warmup.txt" 2>&1 || true
    for run in 1 2 3; do
      log "run1 $scenario run $run (p95_ms=$p95_ms sleep_s=$sleep_s)"
      RUN_ID="$RUN_ID-$scenario-$run" P95_MS="$p95_ms" SMOKE_SLEEP="$sleep_s" k6 run \
        --summary-export "$OUT_DIR/v2/${scenario}-run${run}-summary.json" \
        "$K6_DIR/v2/${scenario}.js" \
        >"$OUT_DIR/v2/${scenario}-run${run}.txt" 2>&1 || failures=$((failures + 1))
    done
  done
  log "run1 fallos de threshold: $failures"
  (( failures == 0 )) || return 1
}

# Repite un solo escenario de la matriz con el mismo perfil y umbral, bajo un
# tag propio, para reintentar una corrida roja por un evento transitorio del
# backend (5xx trazable) sin reescribir la corrida original. La corrida
# original queda archivada como evidencia del evento.
run1_scenario() {
  local scenario="${SCENARIO:?SCENARIO es obligatorio (health|list|create|state)}"
  local tag="${TAG:-retry}"
  local repeat="${REPEAT:-3}"
  local p95_ms sleep_s run failures=0
  mkdir -p "$OUT_DIR/v2"
  scenario_params "$scenario"
  p95_ms="$SC_P95_MS"; sleep_s="$SC_SLEEP"
  log "run1-scenario: $scenario tag=$tag repeat=$repeat p95_ms=$p95_ms sleep_s=$sleep_s"
  RUN_ID="$RUN_ID-$scenario-$tag-warmup" P95_MS=0 SMOKE_SLEEP="$sleep_s" k6 run \
    --no-thresholds --duration 10s --vus 1 \
    "$K6_DIR/v2/${scenario}.js" \
    >"$OUT_DIR/v2/${scenario}-${tag}-warmup.txt" 2>&1 || true
  for run in $(seq 1 "$repeat"); do
    log "run1-scenario $scenario $tag run $run"
    RUN_ID="$RUN_ID-$scenario-$tag-$run" P95_MS="$p95_ms" SMOKE_SLEEP="$sleep_s" k6 run \
      --summary-export "$OUT_DIR/v2/${scenario}-${tag}-run${run}-summary.json" \
      "$K6_DIR/v2/${scenario}.js" \
      >"$OUT_DIR/v2/${scenario}-${tag}-run${run}.txt" 2>&1 || failures=$((failures + 1))
  done
  log "run1-scenario fallos de threshold: $failures"
  (( failures == 0 )) || return 1
}

run2() {
  local script="${PIPELINE_SCRIPT:-pipeline-1000.js}"
  local rate="${RATE:-2}"
  SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "run2: pipeline SCRIPT=$script DOCS=$DOCS VUS=$VUS RATE=${rate}/s"
  log "run2: ventana Mongo since=$SINCE"
  mkdir -p "$OUT_DIR/pipeline"
  export RUN_ID="$RUN_ID-pipeline"
  export PRE_VUS="$VUS" MAX_VUS=$((VUS * 2))
  export DOCS RATE="$rate" EXPECTED_COMPLETED="$DOCS" RAMP_DURATION="$PIPELINE_RAMP"
  export FIXTURE BASE_URL RUN_ID POLL_INTERVAL POLL_MAX
  export P4_LOAD_SINCE="$SINCE"
  printf '%s\n' "$SINCE" >"$OUT_DIR/pipeline/since.txt"

  local exit_code=0
  k6 run \
    --summary-export "$OUT_DIR/pipeline/summary.json" \
    "$E2E_DIR/load/$script" 2>&1 | tee "$OUT_DIR/pipeline/k6-run.txt" | tail -n 60 | tee -a "$LOG"
  exit_code=${PIPESTATUS[0]}

  pipeline_state_report
  log "run2 k6 exit=$exit_code"
  (( exit_code == 0 )) || return 1
}

pipeline_state_report() {
  local out="$OUT_DIR/pipeline/estado.json"
  local since
  since="$(cat "$OUT_DIR/pipeline/since.txt")"
  mongo_eval "
var since=ISODate('$since');
var docs=db.documents.find({created_at:{\$gte:since}}).toArray();
var terminal=['COMPLETED','FAILED','REJECTED','UPLOAD_EXPIRED'];
var byStatus={};
docs.forEach(function(d){ byStatus[d.status]=(byStatus[d.status]||0)+1; });
var nonTerminal=docs.filter(function(d){ return terminal.indexOf(d.status)==-1; }).length;
var times=[];
docs.forEach(function(d){
  if(d.status=='COMPLETED' && d.created_at && d.completed_at){
    times.push(new Date(d.completed_at)-new Date(d.created_at));
  }
});
times.sort(function(a,b){ return a-b; });
function pct(arr,p){ if(arr.length==0) return null; var i=Math.ceil(arr.length*p)-1; if(i<0) i=0; return arr[i]; }
print(JSON.stringify({since:'$since',total:docs.length,terminal:docs.length-nonTerminal,nonTerminal:nonTerminal,byStatus:byStatus,p50_ms:pct(times,0.5),p95_ms:pct(times,0.95),p99_ms:pct(times,0.99)},null,2));
" >"$out" || true
  log "run2 estado en Mongo:"; sed 's/^/[s9-carga]   /' "$out" | tee -a "$LOG"
}

run3() {
  log "run3: rate limit en el borde (gateway ForwardAuth)"
  mkdir -p "$OUT_DIR/ratelimit"
  # Ruta ratelimitd directa (/check) ya no se publica en el host; el contrato
  # comparable del borde es el de la matriz gateway (429 + Retry-After + 0 5xx).
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' -H 'Host: api.localhost' "$BASE_URL/healthz" || true)"
  log "run3 preflight healthz=$code"
  [[ "$code" == "200" ]] || fail "preflight de gateway fallo"
  sleep 3
  k6 run "$K6_DIR/ratelimit/gateway.js" 2>&1 | tee "$OUT_DIR/ratelimit/k6-run.txt" | tail -n 40 | tee -a "$LOG"
}

postcheck() {
  log "postcheck: DLQ y stream"
  redis_cli --raw XLEN stream:pdf-processing-dlq 2>/dev/null | sed 's/^/[s9-carga]   DLQ=/' | tee -a "$LOG" || true
  redis_cli --raw XLEN stream:pdf-processing 2>/dev/null | sed 's/^/[s9-carga]   XLEN=/' | tee -a "$LOG" || true
  log "postcheck: documentos no terminales en total"
  mongo_eval "
var terminal=['COMPLETED','FAILED','REJECTED','UPLOAD_EXPIRED'];
var total=db.documents.countDocuments({});
var nonTerminal=db.documents.countDocuments({status:{\$nin:terminal}});
var byStatus={};
db.documents.aggregate([{\$group:{_id:'\$status',n:{\$sum:1}}}]).forEach(function(d){ byStatus[d._id]=d.n; });
print(JSON.stringify({total:total,nonTerminal:nonTerminal,byStatus:byStatus}));
" | tee -a "$LOG" || true
  log "postcheck: alertas Prometheus activas"
  local alerts
  alerts="$(docker exec infra-prometheus-1 wget -qO- 'http://localhost:9090/api/v1/alerts' 2>/dev/null || echo '{}')"
  printf '%s\n' "$alerts" >"$OUT_DIR/alerts.json"
  printf '%s\n' "$alerts" | jq -r '.data.alerts[]? | "- \(.labels.alertname) [\(.state)]"' | tee -a "$LOG"
  local pending firing
  pending="$(printf '%s\n' "$alerts" | jq -r '[.data.alerts[]? | select(.state=="pending")] | length' 2>/dev/null || echo unknown)"
  firing="$(printf '%s\n' "$alerts" | jq -r '[.data.alerts[]? | select(.state=="firing")] | length' 2>/dev/null || echo unknown)"
  log "postcheck: alertas pending=$pending firing=$firing"
}

metrics() {
  local f rel txt p95 failed checks reqs thr
  while IFS= read -r -d '' f; do
    rel="${f#"$OUT_DIR"/}"
    p95="$(jq -r '.metrics.http_req_duration["p(95)"] // 0' "$f")"
    failed="$(jq -r '.metrics.http_req_failed.value // 0' "$f")"
    checks="$(jq -r '.metrics.checks.value // 0' "$f")"
    reqs="$(jq -r '(.metrics.http_reqs.value // .metrics.http_reqs.count) // 0' "$f")"
    # k6 v2.3 escribe `thresholds` en el summary-export con valores que no
    # reflejan la evaluacion real (marca false aunque el .txt muestre ✓). La
    # fuente autoritativa es la linea de error del .txt hermano.
    txt="${f%-summary.json}.txt"
    thr="none"
    if [[ -f "$txt" ]] && grep -q 'msg="thresholds on metrics' "$txt"; then
      thr="$(sed -n 's/.*msg="thresholds on metrics '"'"'\(.*\)'"'"' have been crossed".*/\1/p' "$txt" | head -1)"
      [[ -z "$thr" ]] && thr="crossed (ver $txt)"
    fi
    log "metrics: $rel  p95_ms=$p95  http_req_failed=$failed  checks=$checks  http_reqs=$reqs  failed_thresholds=$thr"
  done < <(find "$OUT_DIR" -type f -name '*-summary.json' -print0 | sort -z)
}

log "RUN_ID=$RUN_ID MODE=$MODE BASE_URL=$BASE_URL OUT_DIR=$OUT_DIR"
case "$MODE" in
  precheck) precheck ;;
  run1) run1 ;;
  run1-scenario) run1_scenario ;;
  run2) run2 ;;
  run3) run3 ;;
  postcheck) postcheck ;;
  metrics) metrics ;;
  all)
    precheck
    run1
    run2
    run3
    postcheck
    ;;
  *) fail "modo desconocido: $MODE (precheck|run1|run1-scenario|run2|run3|postcheck|metrics|all)" ;;
esac
log "listo: $OUT_DIR"
