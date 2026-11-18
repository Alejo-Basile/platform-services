#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317,SC2329
# Caos parcial de S4-P4: doc-service, Redis Streams, extraction-worker y Mongo.
# Requiere el stack E2E ya levantado; no lo levanta.
#
# Uso:
#   tests/e2e/chaos/run.sh --all
#   tests/e2e/chaos/run.sh --chaos1          # ventana webhook -> XADD (real)
#   tests/e2e/chaos/run.sh --chaos1-kill     # variante Redis caido + SIGKILL
#   P4_CHAOS_REDIS_SECONDS=10 tests/e2e/chaos/run.sh --chaos3
#   tests/e2e/chaos/run.sh --chaos2-seed --full
#   P4_CHAOS2_MODE=kill tests/e2e/chaos/run.sh --chaos2 --full
#   tests/e2e/chaos/run.sh --chaos4 --full
#   tests/e2e/chaos/run.sh --all --full      # cuando exista worker real
#   P4_STRICT_RELAY=1 tests/e2e/chaos/run.sh --all  # exige recuperacion por relay
#
# Con worker real, el mensaje puede consumirse y ACK-earse antes de que el
# arnes lo observe. Por eso "sin entrada en el stream" no es un fallo por si
# solo: se acepta unicamente si el documento tiene el estado terminal
# esperado (COMPLETED), una unica transicion en status_history, el .txt
# extraido en MinIO y ninguna evidencia de duplicado. Una entrada de mas, o
# un documento no terminal sin entrada, sigue siendo fallo.
#
# Sin worker real, los caos terminan en la cola y el aserto COMPLETED queda
# BLOQUEADO. --full convierte ese bloqueo en fallo y exige la evidencia
# terminal completa.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

REDIS_DOWN_SECONDS="${P4_CHAOS_REDIS_SECONDS:-300}"
CHAOS1_RACE_RUNS="${P4_CHAOS1_RACE_RUNS:-10}"
CHAOS2_RUNS="${P4_CHAOS2_RUNS:-3}"
CHAOS2_MODE="${P4_CHAOS2_MODE:-seed}"
STRICT_RELAY="${P4_STRICT_RELAY:-0}"
RELAY_ISSUE="doc-service#55"
RUN_CHAOS1=0
RUN_CHAOS1_KILL=0
RUN_CHAOS3=0
RUN_CHAOS2=0
RUN_CHAOS4=0
FULL=0
WORKER_SCALE_REQUIRED=0

usage() {
  cat <<'EOF'
  Uso: tests/e2e/chaos/run.sh <--chaos1|--chaos1-kill|--chaos2|--chaos2-seed|--chaos2-kill|--chaos3|--chaos4|--all> [--full]

  --chaos1       S4-P4-01: doc-service muere entre webhook y XADD (real)
  --chaos1-kill  Variante: Redis caido + SIGKILL de doc-service
  --chaos2       S4-P4-02: modo P4_CHAOS2_MODE (seed por defecto)
  --chaos2-seed  S4-P4-02: prueba determinista desde el estado post-crash
  --chaos2-kill  S4-P4-02: kill real; la carrera sub-segundo es inalcanzable
  --chaos3       S4-P4-03: Redis Streams cae durante la ventana configurada
  --chaos4       S4-P4-04: Mongo cae durante el cierre de un trabajo
  --all          todos los casos implementados
  --full         exige COMPLETED con status_history, .txt y sin duplicados

Con worker real el mensaje puede estar consumido y ACK-eado: la ausencia de
entrada en el stream se acepta solo con la evidencia terminal completa.

Variables:
  P4_CHAOS_REDIS_SECONDS   duracion de la caida de Redis (default 300)
  P4_CHAOS1_RACE_RUNS      repeticiones de --chaos1 (default 10)
  P4_CHAOS2_RUNS            repeticiones de --chaos2 (default 3)
  P4_CHAOS2_MODE            modo de --chaos2: seed o kill (default seed)
  P4_STRICT_RELAY          si vale 1, exige que el relay reencole (default 0)
  P4_COMPOSE_PROJECT       proyecto Compose (default infra)
  P4_WORKSPACE_ROOT        workspace con infra/ y platform-services/
EOF
}

while (($# > 0)); do
  case "$1" in
    --chaos1) RUN_CHAOS1=1 ;;
    --chaos1-kill) RUN_CHAOS1_KILL=1 ;;
    --chaos2) RUN_CHAOS2=1 ;;
    --chaos2-seed) RUN_CHAOS2=1; CHAOS2_MODE=seed ;;
    --chaos2-kill) RUN_CHAOS2=1; CHAOS2_MODE="kill" ;;
    --chaos3) RUN_CHAOS3=1 ;;
    --chaos4) RUN_CHAOS4=1 ;;
    --all) RUN_CHAOS1=1; RUN_CHAOS1_KILL=1; RUN_CHAOS2=1; RUN_CHAOS3=1; RUN_CHAOS4=1 ;;
    --full) FULL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ((RUN_CHAOS1 == 0 && RUN_CHAOS1_KILL == 0 && RUN_CHAOS2 == 0 && RUN_CHAOS3 == 0 && RUN_CHAOS4 == 0)); then
  usage >&2
  exit 2
fi
if ! [[ "$REDIS_DOWN_SECONDS" =~ ^[0-9]+$ ]] || ((REDIS_DOWN_SECONDS < 1)); then
  echo "[chaos] ERROR: P4_CHAOS_REDIS_SECONDS debe ser un entero >= 1" >&2
  exit 2
fi
if ! [[ "$CHAOS1_RACE_RUNS" =~ ^[0-9]+$ ]] || ((CHAOS1_RACE_RUNS < 1)); then
  echo "[chaos] ERROR: P4_CHAOS1_RACE_RUNS debe ser un entero >= 1" >&2
  exit 2
fi
if ! [[ "$CHAOS2_RUNS" =~ ^[0-9]+$ ]] || ((CHAOS2_RUNS < 1)); then
  echo "[chaos] ERROR: P4_CHAOS2_RUNS debe ser un entero >= 1" >&2
  exit 2
fi
if ((RUN_CHAOS2 == 1)) && [[ "$CHAOS2_MODE" != "seed" && "$CHAOS2_MODE" != "kill" ]]; then
  echo "[chaos] ERROR: P4_CHAOS2_MODE debe ser seed o kill" >&2
  exit 2
fi

log()   { printf '[chaos] %s\n' "$*"; }
pass()  { printf '  [PASS] %s\n' "$*"; }
bad()   { printf '  [FAIL] %s\n' "$*"; }
block() { printf '  [BLOCKED] %s\n' "$*"; }
note()  { printf '  [INFO] %s\n' "$*"; }
known() { printf '  [KNOWN-ISSUE] %s\n' "$*"; }

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT)"
HTTPS_PORT="${HTTPS_PORT:-8543}"
API_BASE="https://api.localhost:${HTTPS_PORT}"
MONGO_DATABASE="$(env_value MONGO_DATABASE)"
MONGO_DATABASE="${MONGO_DATABASE:-documents}"
REDIS_STREAM_KEY="$(env_value REDIS_STREAM_KEY)"
REDIS_STREAM_KEY="${REDIS_STREAM_KEY:-stream:pdf-processing}"

internal_token() {
  local token=""
  token="$(compose exec -T doc-service sh -c 'cat /run/secrets/internal_token 2>/dev/null || printenv INTERNAL_TOKEN' 2>/dev/null | tr -d '\r\n')"
  [[ -n "$token" ]] || token="$(env_value INTERNAL_TOKEN)"
  printf '%s' "$token"
}

INTERNAL_TOKEN="$(internal_token)"

TMP_DIR="$(mktemp -d)"
VALID_PDF="$PLATFORM_ROOT/tests/fixtures/pdf/baseline-0001.pdf"
CURRENT_DOCS=()
CURRENT_KEYS=()
STOPPED=()
NEW_DOC_ID=""
NEW_DOC_KEY=""
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_BLOCKED=0
TOTAL_KNOWN=0
CASE_ENV_BLOCKED=0
DEAD_CHAOS2_CONSUMER=""

# mongo_eval, mongo_status y mongo_delete vienen de lib.sh (DRY).

mongo_age_document() {
  local id="$1"
  # Envejece también expires_at: el reconciliador solo toca PENDING_UPLOAD
  # vencidos y UPLOADED con updated_at viejo. Sin expires_at, un documento
  # que quedó PENDING_UPLOAD tras el kill nunca se recupera en la prueba.
  mongo_eval "db.documents.updateOne({_id:'$id'},{\$set:{created_at:new Date(Date.now()-45*60*1000),updated_at:new Date(Date.now()-45*60*1000),expires_at:new Date(Date.now()-45*60*1000)}}).modifiedCount" \
    | tail -n1
}

mongo_age_queued_document() {
  local id="$1"
  # sweepStuckQueued exige created_at y updated_at antiguos. Mantener expires_at
  # en el futuro evita que el indice TTL elimine el documento antes del sweep.
  mongo_eval "var now=Date.now(); db.documents.updateOne({_id:'$id'},{\$set:{created_at:new Date(now-45*60*1000),updated_at:new Date(now-45*60*1000),expires_at:new Date(now+60*60*1000)}}).modifiedCount" \
    | tail -n1
}

post_create() {
  local id="$1" size="$2" body_file="$3" hdr_file="$4"
  local body
  body="$(jq -n --arg ik "$id" --argjson sz "$size" \
    '{idempotency_key:$ik, size_bytes:$sz}')"
  curl -sk --max-time 45 --resolve "api.localhost:${HTTPS_PORT}:127.0.0.1" \
    -X POST "$API_BASE/api/v2/documents" \
    -H 'Content-Type: application/json' -H "X-Correlation-Id: chaos-${id}" \
    -d "$body" -D "$hdr_file" -o "$body_file" -w '%{http_code}' || true
}

upload_pdf() {
  local create_json="$1" file="$2" ctype="$3"
  local url key
  url="$(jq -r '.upload_url // empty' "$create_json")"
  key="$(jq -r '.form_fields.key // empty' "$create_json")"
  [[ -n "$url" && -n "$key" ]] || return 1
  local form_args=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && form_args+=(-F "$k=$v")
  done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' "$create_json")

  printf '%s' "$key" > "$TMP_DIR/upload.key"
  curl -sk --max-time 60 --resolve "s3.localhost:${HTTPS_PORT}:127.0.0.1" \
    -X POST "$url" "${form_args[@]}" -F "file=@${file};type=${ctype}" \
    -o /dev/null -w '%{http_code}' || true
}

new_document() {
  local prefix="$1" action="${2:-}" body hdr code upload id monitor_pid="" monitor_result=0 i
  id="${prefix}-$(date +%s)-$RANDOM"
  body="$TMP_DIR/${id}.json"
  hdr="$TMP_DIR/${id}.hdr"
  code="$(post_create "$id" "$(wc -c < "$VALID_PDF" | tr -d ' ')" "$body" "$hdr")"
  if [[ "$code" == "500" ]]; then
    note "create HTTP 500; esperando 120 s por recuperacion del circuit breaker y reintentando una vez"
    sleep 120
    code="$(post_create "$id" "$(wc -c < "$VALID_PDF" | tr -d ' ')" "$body" "$hdr")"
    if [[ "$code" == "500" ]]; then
      block "create HTTP 500 persistente tras 120 s y un reintento; bloqueo de entorno por circuit breaker"
      TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
      CASE_ENV_BLOCKED=1
      return 2
    fi
  fi
  if [[ "$code" != "201" ]]; then
    bad "create HTTP $code"
    return 1
  fi
  NEW_DOC_ID="$id"
  NEW_DOC_KEY="$(jq -r '.form_fields.key // empty' "$body")"
  CURRENT_DOCS+=("$id")
  CURRENT_KEYS+=("$NEW_DOC_KEY")
  if [[ -n "$action" ]]; then
    monitor_processing_action "$id" "$action" "$TMP_DIR/${id}.event" &
    monitor_pid=$!
    for ((i = 1; i <= 300; i++)); do
      [[ -f "$TMP_DIR/${id}.event.ready" ]] && break
      sleep 0.1
    done
    if [[ ! -f "$TMP_DIR/${id}.event.ready" ]]; then
      wait "$monitor_pid" || true
      bad "no se pudo iniciar el monitor de cambios Mongo para $id"
      return 1
    fi
  fi
  upload="$(upload_pdf "$body" "$VALID_PDF" "application/pdf")"
  if ! [[ "$upload" =~ ^2[0-9][0-9]$ ]]; then
    if [[ -n "$monitor_pid" ]]; then
      wait "$monitor_pid" 2>/dev/null || true
    fi
    bad "upload HTTP $upload"
    return 1
  fi
  if [[ -n "$monitor_pid" ]]; then
    wait "$monitor_pid" || monitor_result=$?
    if [[ -f "$TMP_DIR/${id}.event.mongo-stopped" ]]; then
      STOPPED+=(mongo)
    fi
    if ((monitor_result != 0 && monitor_result != 2)); then
      bad "no se pudo ejecutar la accion de caos durante PROCESSING (exit=$monitor_result)"
      return 1
    fi
  fi
}

stop_service() {
  local svc="$1"
  compose stop "$svc" >/dev/null
  STOPPED+=("$svc")
}

worker_replicas_running() {
  local expected="$1" attempt cid status running
  local containers=()
  for ((attempt = 1; attempt <= 45; attempt++)); do
    mapfile -t containers < <(compose --profile full ps -q extraction-worker 2>/dev/null)
    running=0
    for cid in "${containers[@]}"; do
      [[ -n "$cid" ]] || continue
      status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
      [[ "$status" == "running" ]] && running=$((running + 1))
    done
    ((running == expected)) && return 0
    sleep 2
  done
  bad "extraction-worker: se esperaban $expected replicas running; observadas $running"
  return 1
}

worker_replicas_healthy() {
  local expected="$1" attempt cid health healthy
  local containers=()
  for ((attempt = 1; attempt <= 90; attempt++)); do
    mapfile -t containers < <(compose --profile full ps -q extraction-worker 2>/dev/null)
    healthy=0
    for cid in "${containers[@]}"; do
      [[ -n "$cid" ]] || continue
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
      [[ "$health" == "healthy" ]] && healthy=$((healthy + 1))
    done
    ((healthy == expected && ${#containers[@]} == expected)) && return 0
    sleep 2
  done
  bad "extraction-worker: se esperaban $expected replicas healthy; observadas $healthy"
  return 1
}

unpause_worker_ids() {
  local cid paused=0 failed=0
  for cid in "$@"; do
    [[ -n "$cid" ]] || continue
    if [[ "$(docker inspect -f '{{.State.Paused}}' "$cid" 2>/dev/null || true)" == "true" ]]; then
      paused=$((paused + 1))
      if ! docker unpause "$cid" >/dev/null 2>&1; then
        bad "no se pudo despausar extraction-worker $cid"
        failed=1
      fi
    fi
  done
  ((failed == 0))
}

unpause_all_workers() {
  local cid
  local worker_ids=()
  mapfile -t worker_ids < <(docker ps --filter name=infra-extraction-worker --format '{{.ID}}')
  for cid in "${worker_ids[@]}"; do
    [[ -n "$cid" ]] || continue
    if [[ "$(docker inspect -f '{{.State.Paused}}' "$cid" 2>/dev/null || true)" == "true" ]]; then
      docker unpause "$cid" >/dev/null 2>&1 || {
        bad "no se pudo despausar extraction-worker $cid"
        return 1
      }
    fi
  done
}

scale_worker() {
  local replicas="$1"
  compose --profile full up -d --scale "extraction-worker=$replicas" extraction-worker
}

restore_one_worker() {
  local restore_failed=0
  ((WORKER_SCALE_REQUIRED == 1)) || return 0
  unpause_all_workers || restore_failed=1
  scale_worker 1 || restore_failed=1
  worker_replicas_running 1 || restore_failed=1
  worker_replicas_healthy 1 || restore_failed=1
  if ((restore_failed == 0)); then
    WORKER_SCALE_REQUIRED=0
    pass "extraction-worker restaurado a una replica"
    return 0
  fi
  bad "no se pudo restaurar extraction-worker a una replica"
  return 1
}

restore_services() {
  local svc
  for svc in "${STOPPED[@]:-}"; do
    if [[ -n "$svc" ]]; then
      compose start "$svc" >/dev/null 2>&1 || true
    fi
  done
  STOPPED=()
}

remove_dead_chaos2_consumer() {
  local result remaining
  [[ -n "$DEAD_CHAOS2_CONSUMER" ]] || return 0
  result="$(redis_cli --raw XGROUP DELCONSUMER "$REDIS_STREAM_KEY" extraction-workers "$DEAD_CHAOS2_CONSUMER")"
  remaining="$(redis_cli --raw XINFO CONSUMERS "$REDIS_STREAM_KEY" extraction-workers |
    awk -v consumer="$DEAD_CHAOS2_CONSUMER" '$0 == "name" { getline; if ($0 == consumer) found=1 } END { print found+0 }')"
  if ! [[ "$result" =~ ^[0-9]+$ ]] || [[ "$remaining" != "0" ]]; then
    bad "no se pudo eliminar el consumidor temporal $DEAD_CHAOS2_CONSUMER (DEL=$result presente=$remaining)"
    return 1
  fi
  note "consumidor temporal $DEAD_CHAOS2_CONSUMER eliminado (XGROUP DELCONSUMER=$result)"
  DEAD_CHAOS2_CONSUMER=""
}

kill_doc_service() {
  local cid before after i
  cid="$(compose ps -q doc-service)"
  [[ -n "$cid" ]] || { bad "doc-service no esta levantado"; return 1; }
  before="$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null || true)"
  docker kill --signal=KILL "$cid" >/dev/null 2>&1 || return 1
  for ((i = 1; i <= 40; i++)); do
    after="$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null || true)"
    if [[ -n "$after" && "$after" != "$before" ]]; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)" != "true" ]]; then
      compose start doc-service >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.5
  done
  return 1
}

reconcile_once() {
  local output exit_code
  if output="$(compose exec -T doc-service wget -O- \
    --header="X-Internal-Token: ${INTERNAL_TOKEN}" \
    --post-data='{}' http://localhost:8080/internal/reconcile 2>&1)"; then
    exit_code=0
  else
    exit_code=$?
  fi
  output="${output//$'\r'/ }"
  output="${output//$'\n'/ }"

  if ((exit_code != 0)); then
    bad "reconciliador fallo (exit=$exit_code): ${output:-sin respuesta}"
    return 1
  fi
  if [[ "$output" != *'"lock_acquired":true'* ]]; then
    bad "reconciliador no adquirio el lock (HTTP/error observado, exit=$exit_code): ${output:-cuerpo vacio}"
    return 1
  fi
  note "reconciliador adquirio el lock"
}

worker_present() {
  local attempt output
  for ((attempt = 1; attempt <= 3; attempt++)); do
    if compose --profile full config --services 2>/dev/null | grep -qx "extraction-worker"; then
      return 0
    fi
    if docker ps --filter name=extraction-worker --filter status=running \
      --format '{{.Names}}' 2>/dev/null | grep -q 'extraction-worker'; then
      return 0
    fi
    if ((attempt < 3)); then
      sleep 1
    fi
  done

  output="$(compose --profile full config --services 2>&1 | tail -3)" || true
  note "salida final de compose --profile full config --services: ${output:-sin salida}"
  return 1
}

require_full_worker() {
  local container_status
  if ((FULL == 1)) && ! worker_present; then
    container_status="$(docker ps --filter name=extraction-worker --format '{{.Names}} {{.Status}}' 2>&1)" || true
    bad "--full requiere un servicio extraction-worker en Compose (contenedor observado: ${container_status:-ninguno})"
    return 1
  fi
  return 0
}

cleanup() {
  local previous_compose_timeout="${P4_COMPOSE_TIMEOUT:-}"
  export P4_COMPOSE_TIMEOUT=15s
  restore_services
  unpause_all_workers || TOTAL_FAIL=$((TOTAL_FAIL + 1))
  restore_one_worker || TOTAL_FAIL=$((TOTAL_FAIL + 1))
  remove_dead_chaos2_consumer || TOTAL_FAIL=$((TOTAL_FAIL + 1))
  local i
  for i in "${!CURRENT_DOCS[@]}"; do
    mongo_delete "${CURRENT_DOCS[$i]}"
    minio_delete "${CURRENT_KEYS[$i]:-}"
  done
  for i in "${!CURRENT_DOCS[@]}"; do
    local id="${CURRENT_DOCS[$i]}"
    local entry
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && stream_delete "$entry"
    done < <(chaos_stream_entries_for "$id" 2>/dev/null || true)
  done
  if [[ -n "$previous_compose_timeout" ]]; then
    export P4_COMPOSE_TIMEOUT="$previous_compose_timeout"
  else
    unset P4_COMPOSE_TIMEOUT
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# `stream_entries_for` de lib.sh solo reconoce el sobre JSON legado
# (`{"document_id":"..."}`); el relay publica hoy campos planos (ADR-0007).
# Este arnes necesita distinguir "entrada visible" de "mensaje consumido y
# ACK-eado" para no fallar por una carrera con el worker real, asi que parsea
# ambos formatos sobre la misma `redis_cli` compartida.
chaos_stream_entries_for() {
  local id="$1"
  redis_cli --raw XRANGE "$REDIS_STREAM_KEY" - + COUNT 10000 |
    awk -v id="$id" '
      /^[0-9]+-[0-9]+$/ { entry=$0; want_field=1; next }
      want_field { field=$0; want_field=0; next }
      {
        if (field == "document_id" && $0 == id) { print entry }
        else if (index($0, "\"document_id\":\"" id "\"") > 0) { print entry }
        want_field=1
      }
    '
}

chaos_stream_entry_for() {
  chaos_stream_entries_for "$1" | awk 'NF { print; exit }'
}

chaos_stream_count() {
  chaos_stream_entries_for "$1" | wc -l | tr -d ' '
}

mongo_doc_state() {
  local id="$1"
  # Sin `$` en el JS: el script corre dentro del contenedor, no en este shell.
  mongo_eval "var d=db.documents.findOne({_id:'$id'}); print(JSON.stringify(d?{status:d.status||'',txt_ref:d.txt_ref||'',history:(d.status_history||[]).map(function(h){return {status:h.status||'',actor:h.actor||'',correlation_id:h.correlation_id||''}})}:null))" \
    | tail -n1
}

# Evidencia terminal completa del camino real: COMPLETED, una sola entrada
# COMPLETED en status_history (sin duplicados), `.txt` extraido y presente en
# MinIO. Es lo que hace aceptable que el stream ya no muestre el mensaje.
doc_terminal_ok() {
  local id="$1" state status txt_ref completed terminal actor correlation
  state="$(mongo_doc_state "$id")"
  [[ -n "$state" && "$state" != "null" ]] || return 1
  status="$(jq -r '.status // empty' <<<"$state" 2>/dev/null)" || return 1
  [[ "$status" == "COMPLETED" ]] || return 1
  txt_ref="$(jq -r '.txt_ref // empty' <<<"$state")"
  [[ -n "$txt_ref" ]] || return 1
  completed="$(jq -r '[.history[]? | select(.status=="COMPLETED")] | length' <<<"$state")"
  [[ "$completed" == "1" ]] || return 1
  terminal="$(jq -r '[.history[]? | select(.status=="COMPLETED")][0] // {} | "\(.actor // "")|\(.correlation_id // "")"' <<<"$state")"
  actor="${terminal%%|*}"
  correlation="${terminal#*|}"
  [[ "$actor" == "worker" && -n "$correlation" ]] || return 1
  minio_exists "extracted-txt/$txt_ref" || return 1
  return 0
}

wait_doc_terminal() {
  local id="$1" tries="${2:-60}" i
  for ((i = 1; i <= tries; i++)); do
    if ((i % 2 == 0 || i == tries)); then
      doc_terminal_ok "$id" && return 0
    fi
    sleep 1
  done
  return 1
}

wait_document_status() {
  local id="$1" max_seconds="$2" interval="${3:-10}" started="$SECONDS"
  local state status elapsed
  while :; do
    state="$(mongo_doc_state "$id")"
    status="$(jq -r '.status // empty' <<<"$state" 2>/dev/null || true)"
    if [[ "$status" == "COMPLETED" || "$status" == "FAILED" ]]; then
      printf '%s\n' "$state"
      return 0
    fi
    elapsed=$((SECONDS - started))
    ((elapsed >= max_seconds)) && break
    sleep "$interval"
  done
  printf '%s\n' "${state:-}"
  return 1
}

worker_container_for_document() {
  local id="$1" cid logs
  local matches=()
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    logs="$(docker logs --since 10m "$cid" 2>&1 || true)"
    [[ "$logs" == *"$id"* ]] && matches+=("$cid")
  done < <(compose --profile full ps -q extraction-worker 2>/dev/null)
  if ((${#matches[@]} == 1)); then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  return 1
}

minio_txt_count_for_document() {
  local id="$1" user pass network
  local net_args=()
  user="$(env_value MINIO_ROOT_USER)"
  pass="$(env_value MINIO_ROOT_PASSWORD)"
  network="$(data_network || true)"
  [[ -n "$network" ]] && net_args=(--network "$network")
  MC_HOST_local="http://${user}:${pass}@minio:9000" docker run --rm \
    "${net_args[@]}" -e MC_HOST_local "$MC_IMAGE" find local/extracted-txt \
    --name "*${id}*" 2>/dev/null |
    awk -v id="$id" 'index($0,id)>0 && $0 ~ /\.(txt|md)$/ {count++} END {print count+0}'
}

assert_completed_once() {
  local id="$1" state status txt_ref completions txt_count stream_count
  state="$(mongo_doc_state "$id")"
  status="$(jq -r '.status // empty' <<<"$state")"
  txt_ref="$(jq -r '.txt_ref // empty' <<<"$state")"
  completions="$(jq -r '[.history[]? | select(.status=="COMPLETED")] | length' <<<"$state")"
  stream_count="$(chaos_stream_count "$id")"
  txt_count="$(minio_txt_count_for_document "$id")"
  [[ "$status" == "COMPLETED" ]] || { bad "$id: status=$status (esperado COMPLETED)"; return 1; }
  [[ "$completions" == "1" ]] || { bad "$id: transiciones COMPLETED=$completions"; return 1; }
  [[ -n "$txt_ref" && ( "$txt_ref" == *.txt || "$txt_ref" == *.md ) ]] \
    || { bad "$id: referencia del artefacto de texto ausente ($txt_ref)"; return 1; }
  minio_exists "extracted-txt/$txt_ref" \
    || { bad "$id: no existe extracted-txt/$txt_ref"; return 1; }
  [[ "$txt_count" == "1" ]] || { bad "$id: archivos .txt asociados=$txt_count (esperado 1)"; return 1; }
  [[ "$stream_count" == "0" || "$stream_count" == "1" ]] \
    || { bad "$id: entradas duplicadas en stream=$stream_count"; return 1; }
  pass "$id: COMPLETED, una transicion, un .txt y sin entradas duplicadas"
}

wait_mongo_healthy() {
  local attempt cid status
  for ((attempt = 1; attempt <= 90; attempt++)); do
    cid="$(compose ps -q mongo 2>/dev/null)"
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
    [[ "$status" == "healthy" || "$status" == "running" ]] && return 0
    sleep 2
  done
  bad "mongo no alcanzo estado healthy (ultimo estado=$status)"
  return 1
}

monitor_processing_action() {
  local id="$1" action="$2" event_file="$3" fifo watcher_pid marker
  local cid consumer_name consumer_host killed_at_ms killed_at_iso status
  local entry_id pending_output survivor_cid survivor_number log_prefix
  local worker_ids=()
  fifo="${event_file}.pipe"
  mkfifo "$fifo" || return 1
  P4_COMPOSE_TIMEOUT=90s mongo_eval \
    "var c=db.documents.watch([{\$match:{operationType:'update','documentKey._id':'$id','updateDescription.updatedFields.status':'PROCESSING'}}]); print('WATCH_READY'); var e=c.next(); print(e?'PROCESSING':'NO_EVENT')" \
    > "$fifo" 2> "${event_file}.error" &
  watcher_pid=$!
  while IFS= read -r marker; do
    if [[ "$marker" == "WATCH_READY" ]]; then
      touch "${event_file}.ready"
      continue
    fi
    [[ "$marker" == "PROCESSING" ]] || continue
    if [[ "$action" == "kill-worker" ]]; then
      mapfile -t worker_ids < <(compose --profile full ps -q extraction-worker 2>/dev/null)
      if ((${#worker_ids[@]} != 2)); then
        printf 'UNRESOLVED|replicas=%s\n' "${#worker_ids[@]}" > "$event_file"
        wait "$watcher_pid" || true
        return 2
      fi
      for cid in "${worker_ids[@]}"; do
        if ! docker pause "$cid" >/dev/null 2>&1; then
          unpause_worker_ids "${worker_ids[@]}" || true
          printf 'UNRESOLVED|pause-failed=%s\n' "$cid" > "$event_file"
          wait "$watcher_pid" || true
          return 2
        fi
      done

      entry_id="$(chaos_stream_entry_for "$id")"
      if [[ -z "$entry_id" ]]; then
        unpause_worker_ids "${worker_ids[@]}" || true
        printf 'LOST_WINDOW|entry_id=missing|XPENDING=not-run\n' > "$event_file"
        wait "$watcher_pid" || true
        return 2
      fi
      pending_output="$(redis_cli --raw XPENDING "$REDIS_STREAM_KEY" extraction-workers "$entry_id" "$entry_id" 1)"
      consumer_name="$(awk 'NR == 2 { print; exit }' <<<"$pending_output")"
      if [[ -z "$consumer_name" ]]; then
        unpause_worker_ids "${worker_ids[@]}" || true
        printf 'LOST_WINDOW|entry_id=%s|XPENDING=%s\n' "$entry_id" "${pending_output//$'\n'/,}" > "$event_file"
        wait "$watcher_pid" || true
        return 2
      fi

      if [[ "$consumer_name" =~ ^consumer-(.+)-[0-9]+$ ]]; then
        consumer_host="${BASH_REMATCH[1]}"
      else
        unpause_worker_ids "${worker_ids[@]}" || true
        printf 'UNRESOLVED|entry_id=%s|consumer=%s|format=invalid\n' "$entry_id" "$consumer_name" > "$event_file"
        wait "$watcher_pid" || true
        return 2
      fi

      local matches=()
      while read -r cid _; do
        [[ -n "$cid" ]] || continue
        [[ "$cid" == "$consumer_host"* ]] && matches+=("$cid")
      done < <(docker ps --filter name=infra-extraction-worker --format '{{.ID}} {{.Names}}')
      if ((${#matches[@]} != 1)); then
        unpause_worker_ids "${worker_ids[@]}" || true
        printf 'UNRESOLVED|entry_id=%s|consumer=%s|hostname=%s|matches=%s\n' \
          "$entry_id" "$consumer_name" "$consumer_host" "${#matches[@]}" > "$event_file"
        wait "$watcher_pid" || true
        return 2
      fi
      cid="${matches[0]}"
      local survivors=()
      for survivor_cid in "${worker_ids[@]}"; do
        [[ "$survivor_cid" == "$cid" ]] || survivors+=("$survivor_cid")
      done
      if ((${#survivors[@]} != 1)); then
        unpause_worker_ids "${worker_ids[@]}" || true
        printf 'UNRESOLVED|entry_id=%s|consumer=%s|owner=%s|survivors=%s\n' \
          "$entry_id" "$consumer_name" "$cid" "${#survivors[@]}" > "$event_file"
        wait "$watcher_pid" || true
        return 2
      fi

      survivor_cid="${survivors[0]}"
      killed_at_iso="$(date --iso-8601=seconds)"
      killed_at_ms="$(date +%s%3N)"
      if ! docker kill -s KILL "$cid" >/dev/null; then
        unpause_worker_ids "${worker_ids[@]}" || true
        wait "$watcher_pid" || true
        return 1
      fi
      unpause_worker_ids "${survivors[@]}" || { wait "$watcher_pid" || true; return 1; }
      printf 'PROCESSING|%s|%s|%s|%s|%s|%s\n' \
        "$cid" "$consumer_name" "$entry_id" "$survivor_cid" "$killed_at_ms" "$killed_at_iso" > "$event_file"
      break
    fi
    if [[ "$action" == "stop-mongo" ]]; then
      stop_service mongo || { wait "$watcher_pid" || true; return 1; }
      touch "${event_file}.mongo-stopped"
      sleep 25
      restore_services
      wait_mongo_healthy || { wait "$watcher_pid" || true; return 1; }
      printf 'PROCESSING|mongo-detenido-25s|healthy\n' > "$event_file"
      break
    fi
    wait "$watcher_pid" || true
    return 1
  done < "$fifo"
  wait "$watcher_pid" || true
  if [[ ! -s "$event_file" ]]; then
    status="$(mongo_status "$id")"
    printf 'NO_WINDOW|%s\n' "${status:-MISSING}" > "$event_file"
    return 2
  fi
  return 0
}

# Exito si aparece una entrada O si el mensaje ya fue consumido y el documento
# llego al estado terminal completo. Varias entradas son duplicado: fallo.
wait_entry_or_consumed() {
  local id="$1" tries="${2:-60}" i count
  for ((i = 1; i <= tries; i++)); do
    count="$(chaos_stream_count "$id")"
    if [[ "$count" == "1" ]]; then
      return 0
    fi
    [[ "$count" != "0" ]] && return 1
    if ((i % 2 == 0 || i == tries)); then
      doc_terminal_ok "$id" && return 0
    fi
    sleep 1
  done
  return 1
}

assert_single_entry() {
  local id="$1" count
  count="$(chaos_stream_count "$id")"
  if [[ "$count" == "1" ]]; then
    pass "una sola entrada en el stream para $id"
    return 0
  fi
  if [[ "$count" != "0" ]]; then
    bad "entradas en el stream para $id: $count (esperado 1 o consumida)"
    return 1
  fi
  # Cero entradas solo es valido si Redis respondio y el documento demuestra
  # el cierre real; una lectura fallida no debe confundirse con un consumo.
  redis_available \
    || { bad "Redis no disponible: no se puede distinguir consumo de fallo de lectura ($id)"; return 1; }
  if wait_doc_terminal "$id"; then
    pass "mensaje consumido y ACK-eado con estado terminal verificado ($id)"
    return 0
  fi
  bad "sin entrada en el stream ni evidencia terminal completa (COMPLETED, status_history, .txt, sin duplicados) para $id"
  return 1
}

assert_completed() {
  local id="$1"
  if ! wait_status "$id" "COMPLETED" 120; then
    bad "documento no llego a COMPLETED: $id"
    return 1
  fi
  if ! doc_terminal_ok "$id"; then
    bad "COMPLETED sin evidencia terminal completa (status_history/.txt/duplicados): $id"
    return 1
  fi
  pass "documento COMPLETED con status_history y .txt verificados: $id"
  return 0
}

chaos1_race() {
  local runs="$CHAOS1_RACE_RUNS" i id status_after recovered
  local hit_pending=0 hit_uploaded=0 hit_queued=0 forced=0
  log "S4-P4-01 (real): doc-service muere entre webhook y XADD (${runs} repeticiones)"
  require_full_worker || return 1

  for ((i = 1; i <= runs; i++)); do
    new_document "chaos1-race" || {
      local create_result=$?
      restore_services
      ((create_result == 2)) && return 0
      return 1
    }
    id="$NEW_DOC_ID"
    note "iteracion $i/$runs: document_id=$id"

    # Kill inmediatamente despues del upload, con Redis sano: no hay failpoint,
    # asi que la ventana exacta webhook -> XADD es probabilistica. El estado
    # posterior indica donde cayo el kill.
    if ! kill_doc_service; then
      bad "iteracion $i: no se pudo matar el doc-service"
      return 1
    fi
    wait_http "$API_BASE/healthz" "api.localhost:${HTTPS_PORT}:127.0.0.1" 90 \
      || { bad "iteracion $i: doc-service no volvio"; return 1; }

    status_after="$(mongo_status "$id")"
    local had_entry=0 entry_id
    entry_id="$(chaos_stream_entry_for "$id")"
    [[ -n "$entry_id" ]] && had_entry=1
    case "$status_after" in
      PENDING_UPLOAD) hit_pending=$((hit_pending + 1)) ;;
      UPLOADED)
        if ((had_entry)); then hit_queued=$((hit_queued + 1)); else hit_uploaded=$((hit_uploaded + 1)); fi
        ;;
      QUEUED|PROCESSING|COMPLETED) hit_queued=$((hit_queued + 1)) ;;
      *) bad "iteracion $i: estado inesperado '$status_after'"; return 1 ;;
    esac

    recovered=""
    if ((had_entry)); then
      recovered="ya-encolado"
    elif [[ "$status_after" != "PENDING_UPLOAD" ]]; then
      # El worker real puede consumir el mensaje antes de esta lectura: se
      # acepta si el documento ya demuestra el cierre terminal.
      wait_entry_or_consumed "$id" 20 && recovered="relay"
    fi

    if [[ -z "$recovered" ]]; then
      if [[ "$status_after" == "UPLOADED" ]]; then
        known "iteracion $i: el relay no reencolo (status=UPLOADED). Ver $RELAY_ISSUE"
        TOTAL_KNOWN=$((TOTAL_KNOWN + 1))
        if [[ "$STRICT_RELAY" == "1" ]]; then
          bad "iteracion $i: relay no recupero el evento (P4_STRICT_RELAY=1)"
          return 1
        fi
      else
        note "iteracion $i: el webhook no proceso (status=$status_after); se prueba el reconciliador"
      fi

      if [[ "$status_after" == "PENDING_UPLOAD" ]]; then
        mongo_age_document "$id" >/dev/null
      else
        mongo_age_queued_document "$id" >/dev/null
      fi
      if ! reconcile_once; then
        note "iteracion $i: se evaluara la recuperacion observada aunque falle reconcile"
      fi
      if ! wait_entry_or_consumed "$id" 30; then
        # Segundo pase: PENDING_UPLOAD -> UPLOADED y, si el relay sigue roto,
        # UPLOADED estancado -> reencolado directo por el reconciliador.
        mongo_age_queued_document "$id" >/dev/null
        if ! reconcile_once; then
          note "iteracion $i: segundo reconcile fallo; se evaluara la recuperacion observada"
        fi
        if ! wait_entry_or_consumed "$id" 30; then
          bad "iteracion $i: ni relay ni reconciliador encolaron $id (o hay entradas duplicadas)"
          return 1
        fi
      fi
      recovered="reconciler"
      forced=$((forced + 1))
    fi

    assert_single_entry "$id" || return 1
    pass "iteracion $i: recuperado por $recovered (status previo=$status_after)"
  done

  note "cobertura: webhook->XADD=${hit_uploaded} webhook-perdido=${hit_pending} ya-encolado=${hit_queued} reconciliador-forzado=${forced}"

  if ((FULL == 1)); then
    for i in "${!CURRENT_DOCS[@]}"; do
      assert_completed "${CURRENT_DOCS[$i]}" || return 1
    done
    pass "S4-P4-01 real: $runs/$runs sin perdida ni duplicados y COMPLETED"
  else
    block "COMPLETED bloqueado por G-B (worker real ausente)"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
    pass "S4-P4-01 real: $runs/$runs sin perdida ni duplicados"
  fi
}

chaos1_kill() {
  local id recovered="" status=""
  log "S4-P4-01 (variante): Redis caido + SIGKILL de doc-service"
  require_full_worker || return 1

  stop_service redis-streams
  note "Redis detenido; el webhook no podra encolar"
  new_document "chaos1" || {
    local create_result=$?
    restore_services
    ((create_result == 2)) && return 0
    return 1
  }
  id="$NEW_DOC_ID"
  for ((i = 1; i <= 40; i++)); do
    status="$(mongo_status "$id")"
    [[ "$status" == "UPLOADED" || "$status" == "QUEUED" ]] && break
    sleep 1
  done
  [[ "$status" == "UPLOADED" || "$status" == "QUEUED" ]] \
    || { bad "el documento no quedo UPLOADED/QUEUED con Redis caido (estado=$status)"; return 1; }
  pass "webhook proceso el evento y dejo $status"
  note "document_id=$id"
  if ! kill_doc_service; then
    bad "no se pudo matar el doc-service"
    return 1
  fi
  pass "doc-service recibio SIGKILL"

  restore_services
  wait_redis 60 || { bad "Redis no volvio"; return 1; }
  wait_http "$API_BASE/healthz" "api.localhost:${HTTPS_PORT}:127.0.0.1" 90 \
    || { bad "doc-service no volvio"; return 1; }
  pass "Redis y doc-service recuperados"

  if wait_entry_or_consumed "$id" 60; then
    recovered="relay"
  else
    note "relay no recupero el evento; se fuerza un ciclo de reconciliacion"
    mongo_age_queued_document "$id" >/dev/null
    if ! reconcile_once; then
      note "reconciliacion fallo; se evaluara la recuperacion observada"
    fi
    if wait_entry_or_consumed "$id" 60; then
      recovered="reconciler"
    fi
  fi

  [[ -n "$recovered" ]] || { bad "ni relay ni reconciliador encolaron el documento (o hay entradas duplicadas)"; return 1; }
  if [[ "$recovered" == "reconciler" ]]; then
    known "el relay no reencolo; recupero el reconciliador (forzado). Ver $RELAY_ISSUE"
    TOTAL_KNOWN=$((TOTAL_KNOWN + 1))
    if [[ "$STRICT_RELAY" == "1" ]]; then
      bad "relay no recupero el evento (P4_STRICT_RELAY=1)"
      return 1
    fi
  else
    pass "documento recuperado por $recovered"
  fi
  assert_single_entry "$id" || return 1

  if ((FULL == 1)); then
    assert_completed "$id" || return 1
    block "validacion de descarga pendiente de completar el arnes"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
  else
    block "COMPLETED bloqueado por G-B (worker real ausente)"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
  fi
  pass "S4-P4-01 parcial"
}

chaos3() {
  local start elapsed remaining id recovered="" status="" i
  local original_ids=()
  log "S4-P4-03: Redis caido ${REDIS_DOWN_SECONDS}s con trabajos encolados"
  require_full_worker || return 1

  for i in 1 2; do
    new_document "chaos3-pre" || {
      local create_result=$?
      ((create_result == 2)) && return 0
      restore_services
      return 1
    }
    id="$NEW_DOC_ID"
    original_ids+=("$id")
    wait_entry_or_consumed "$id" 40 || { bad "documento previo no encolado: $id"; return 1; }
    pass "documento previo encolado o ya consumido con cierre terminal: $id"
  done

  start=$SECONDS
  stop_service redis-streams
  note "Redis detenido; se sube un documento durante la caida"
  new_document "chaos3-during" || {
    local create_result=$?
    restore_services
    ((create_result == 2)) && return 0
    return 1
  }
  id="$NEW_DOC_ID"
  for ((i = 1; i <= 40; i++)); do
    status="$(mongo_status "$id")"
    [[ "$status" == "UPLOADED" || "$status" == "QUEUED" ]] && break
    sleep 1
  done
  [[ "$status" == "UPLOADED" || "$status" == "QUEUED" ]] \
    || { bad "el documento de la caida no quedo UPLOADED/QUEUED (estado=$status)"; return 1; }
  pass "documento subido durante la caida quedo $status"

  elapsed=$((SECONDS - start))
  remaining=$((REDIS_DOWN_SECONDS - elapsed))
  if ((remaining > 0)); then
    note "esperando ${remaining}s para completar la ventana"
    sleep "$remaining"
  fi
  elapsed=$((SECONDS - start))
  note "ventana de caida real: ${elapsed}s"

  restore_services
  wait_redis 60 || { bad "Redis no volvio"; return 1; }
  pass "Redis recuperado"

  for i in "${original_ids[@]}"; do
    assert_single_entry "$i" || return 1
  done
  pass "entradas previas conservadas o ya consumidas con estado terminal (AOF)"

  if wait_entry_or_consumed "$id" 60; then
    recovered="relay"
  else
    note "relay no recupero el documento de la caida; se fuerza reconciliacion"
    mongo_age_queued_document "$id" >/dev/null
    if ! reconcile_once; then
      note "reconciliacion fallo; se evaluara la recuperacion observada"
    fi
    if wait_entry_or_consumed "$id" 60; then
      recovered="reconciler"
    fi
  fi
  [[ -n "$recovered" ]] || { bad "el documento de la caida no se recupero (o hay entradas duplicadas)"; return 1; }
  if [[ "$recovered" == "reconciler" ]]; then
    known "el relay no reencolo el documento de la caida; recupero el reconciliador (forzado). Ver $RELAY_ISSUE"
    TOTAL_KNOWN=$((TOTAL_KNOWN + 1))
    if [[ "$STRICT_RELAY" == "1" ]]; then
      bad "relay no recupero el evento de la caida (P4_STRICT_RELAY=1)"
      return 1
    fi
  else
    pass "documento de la caida recuperado por $recovered"
  fi
  assert_single_entry "$id" || return 1

  if ((FULL == 1)); then
    for i in "${original_ids[@]}" "$id"; do
      assert_completed "$i" || return 1
    done
    block "perdida por replica asincrona y conteo de recuperados pendientes de G-B"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
  else
    block "COMPLETED y perdida por replica asincrona bloqueados por G-B"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
  fi
  pass "S4-P4-03 parcial"
}

chaos2_seed_diagnostics() {
  local id="$1" entry_id="$2" worker_started_iso="$3" pending_output state log_output
  pending_output="$(redis_cli --raw XPENDING "$REDIS_STREAM_KEY" extraction-workers "$entry_id" "$entry_id" 1)"
  state="$(mongo_doc_state "$id")"
  log_output="$(compose --profile full logs --no-color --since "$worker_started_iso" extraction-worker 2>&1 || true)"
  bad "diagnostico seed: entry=$entry_id XPENDING=${pending_output//$'\n'/,} documento=$(jq -c '{status:.status,history:.history,txt_ref:.txt_ref}' <<<"$state") logs desde $worker_started_iso siguen"
  printf '%s\n' "${log_output:-[sin logs observados]}"
}

chaos2_seed() {
  local id entry_id correlation_id create_result created read_output claim_output pending_output worker_started_iso worker_started_ms
  local state completed_at_ms recovery_ms log_output xautoclaim_line consumer_name
  local worker_ids=() running=0 cid status
  log "S4-P4-02: estado post-crash sembrado para verificar XAUTOCLAIM"
  WORKER_SCALE_REQUIRED=1
  mapfile -t worker_ids < <(compose --profile full ps -q extraction-worker 2>/dev/null)
  for cid in "${worker_ids[@]}"; do
    [[ -n "$cid" ]] || continue
    status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
    [[ "$status" == "running" ]] && running=$((running + 1))
  done
  if ((running > 1)); then
    scale_worker 1 || { bad "no se pudo escalar extraction-worker a una replica"; return 1; }
    worker_replicas_running 1 || return 1
  elif ((running != 1)); then
    bad "S4-P4-02 seed requiere exactamente una replica running; observadas $running"
    return 1
  fi
  pass "exactamente una replica de extraction-worker esta running"

  compose stop extraction-worker >/dev/null || { bad "no se pudo detener extraction-worker"; return 1; }
  STOPPED+=(extraction-worker)
  pass "extraction-worker detenido; no hay consumidores activos"
  new_document "chaos2-seed" || {
    create_result=$?
    ((create_result == 2)) && return 0
    return 1
  }
  id="$NEW_DOC_ID"
  entry_id="$(chaos_stream_entry_for "$id")"
  if [[ -z "$entry_id" ]]; then
    bad "S4-P4-02 seed: no existe entrada de stream para $id"
    return 1
  fi
  pass "relay encolo $id como entry=$entry_id"

  correlation_id="$(mongo_get "$id" correlation_id)"
  if [[ -z "$correlation_id" ]]; then
    bad "S4-P4-02 seed: correlation_id ausente en Mongo para $id"
    return 1
  fi
  if ! created="$(mongo_eval "db.documents.updateOne({_id:'$id'}, {\$set:{status:'PROCESSING',updated_at:new Date()},\$push:{status_history:{status:'PROCESSING',actor:'worker',correlation_id:'$correlation_id'}}}).modifiedCount" | tail -n1)" \
    || [[ "$created" != "1" ]]; then
    bad "S4-P4-02 seed: no se pudo sembrar PROCESSING con historial para $id (modifiedCount=${created:-vacio})"
    return 1
  fi
  pass "PROCESSING sembrado con status_history y correlation_id existente"

  DEAD_CHAOS2_CONSUMER="dead-chaos2-$id"
  created="$(redis_cli --raw XGROUP CREATECONSUMER "$REDIS_STREAM_KEY" extraction-workers "$DEAD_CHAOS2_CONSUMER")"
  if [[ "$created" != "1" ]]; then
    bad "S4-P4-02 seed: XGROUP CREATECONSUMER no creo $DEAD_CHAOS2_CONSUMER (resultado=${created:-vacio})"
    return 1
  fi
  read_output="$(redis_cli --raw XREADGROUP GROUP extraction-workers "$DEAD_CHAOS2_CONSUMER" COUNT 1 STREAMS "$REDIS_STREAM_KEY" '>')"
  if [[ "$read_output" != *"$entry_id"* ]]; then
    bad "S4-P4-02 seed: XREADGROUP no incorporo $entry_id al PEL (salida=${read_output:-vacia})"
    return 1
  fi
  # XCLAIM applies min-idle-time before IDLE, so first seed an eligible idle age.
  claim_output="$(redis_cli --raw XCLAIM "$REDIS_STREAM_KEY" extraction-workers "$DEAD_CHAOS2_CONSUMER" 0 "$entry_id" IDLE 610000 RETRYCOUNT 1)"
  if [[ "$claim_output" != *"$entry_id"* ]]; then
    bad "S4-P4-02 seed: no se pudo fijar el idle post-crash de $entry_id (salida=${claim_output:-vacia})"
    return 1
  fi
  claim_output="$(redis_cli --raw XCLAIM "$REDIS_STREAM_KEY" extraction-workers "$DEAD_CHAOS2_CONSUMER" 600001 "$entry_id" IDLE 610000 RETRYCOUNT 1)"
  if [[ "$claim_output" != *"$entry_id"* ]]; then
    bad "S4-P4-02 seed: XCLAIM no devolvio la entrada $entry_id (salida=${claim_output:-vacia})"
    return 1
  fi
  pending_output="$(redis_cli --raw XPENDING "$REDIS_STREAM_KEY" extraction-workers "$entry_id" "$entry_id" 1)"
  consumer_name="$(awk 'NR == 2 { print; exit }' <<<"$pending_output")"
  if ! awk -v entry="$entry_id" -v consumer="$DEAD_CHAOS2_CONSUMER" \
    'NR == 1 { actual_entry=$0 } NR == 2 { actual_consumer=$0 } END { exit !(actual_entry == entry && actual_consumer == consumer) }' \
    <<<"$pending_output"; then
    bad "S4-P4-02 seed: XPENDING no confirma la entrada para consumidor muerto (observado=${pending_output//$'\n'/,})"
    return 1
  fi
  note "XPENDING confirmó entry=$entry_id consumer=$consumer_name: ${pending_output//$'\n'/,}"

  if ! compose start extraction-worker >/dev/null; then
    bad "S4-P4-02 seed: no se pudo iniciar extraction-worker"
    return 1
  fi
  worker_started_ms="$(date +%s%3N)"
  worker_started_iso="$(date --iso-8601=seconds)"
  note "extraction-worker iniciado en $worker_started_iso; esperando COMPLETED hasta 300 s"
  if ! state="$(wait_document_status "$id" 300 10)"; then
    chaos2_seed_diagnostics "$id" "$entry_id" "$worker_started_iso"
    return 1
  fi
  completed_at_ms="$(date +%s%3N)"
  recovery_ms=$((completed_at_ms - worker_started_ms))
  if ! assert_completed_once "$id"; then
    chaos2_seed_diagnostics "$id" "$entry_id" "$worker_started_iso"
    return 1
  fi
  if ! log_output="$(compose --profile full logs --no-color --since "$worker_started_iso" extraction-worker 2>&1)"; then
    bad "S4-P4-02 seed: no se pudieron leer logs desde $worker_started_iso: $log_output"
    chaos2_seed_diagnostics "$id" "$entry_id" "$worker_started_iso"
    return 1
  fi
  xautoclaim_line="$(awk -v entry="$entry_id" -v id="$id" \
    'tolower($0) ~ /xautoclaim/ && (index($0, entry) > 0 || index($0, id) > 0) { print; exit }' <<<"$log_output")"
  note "latencia de recuperación desde el arranque del worker=${recovery_ms}ms"
  if [[ -z "$xautoclaim_line" ]]; then
    chaos2_seed_diagnostics "$id" "$entry_id" "$worker_started_iso"
    bad "S4-P4-02 seed: no se observó XAUTOCLAIM asociado a $entry_id o $id"
    return 1
  fi
  note "línea XAUTOCLAIM observada: $xautoclaim_line"
  pass "S4-P4-02 seed: COMPLETED, una transición, un artefacto y sin entradas duplicadas"
  remove_dead_chaos2_consumer || return 1
}

chaos2_kill() {
  local runs="$CHAOS2_RUNS" i id state event_type event_line cid consumer_name entry_id survivor_cid
  local killed_at_ms killed_at_iso recovery_ms recovery_seconds completed=0 missed=0
  local log_output xautoclaim_line survivor_number log_prefix
  log "S4-P4-02: worker muere durante la extraccion ($runs repeticiones)"
  WORKER_SCALE_REQUIRED=1
  scale_worker 2 || { bad "no se pudieron escalar dos replicas de extraction-worker"; return 1; }
  worker_replicas_running 2 || return 1
  pass "dos replicas reales de extraction-worker estan running"

  for ((i = 1; i <= runs; i++)); do
    new_document "chaos2" "kill-worker" || {
      local create_result=$?
      ((create_result == 2)) && return 0
      return 1
    }
    id="$NEW_DOC_ID"
    note "iteracion $i/$runs: document_id=$id"
    IFS= read -r event_line < "$TMP_DIR/${id}.event"
    IFS='|' read -r event_type cid consumer_name entry_id survivor_cid killed_at_ms killed_at_iso <<<"$event_line"
    if [[ "$event_type" != "PROCESSING" ]]; then
      state="$(mongo_doc_state "$id")"
      note "iteracion $i: evento=$event_type evidencia=${event_line#*|}; estado=$(jq -r '.status // empty' <<<"$state")"
      if [[ "$event_type" == "LOST_WINDOW" ]]; then
        bad "iteracion $i: XPENDING no encontro mensaje pendiente antes del kill; ventana perdida, no demuestra XAUTOCLAIM ni implica fallo del producto"
        return 1
      fi
      missed=$((missed + 1))
      continue
    fi
    pass "iteracion $i: ventana PROCESSING alcanzada"
    note "iteracion $i: XPENDING entry=$entry_id consumer=$consumer_name; SIGKILL al owner=$cid; sobreviviente=$survivor_cid"

    if ! state="$(wait_document_status "$id" 720 30)"; then
      state="$(mongo_doc_state "$id")"
      bad "iteracion $i: no convergio en 720 s; status=$(jq -r '.status // empty' <<<"$state") history=$(jq -c '.history // []' <<<"$state")"
      return 1
    fi
    recovery_ms=$(($(date +%s%3N) - killed_at_ms))
    recovery_seconds=$((recovery_ms / 1000))
    if ! assert_completed_once "$id"; then
      state="$(mongo_doc_state "$id")"
      bad "iteracion $i: estado final observado=$(jq -c '{status:.status,history:.history,txt_ref:.txt_ref}' <<<"$state")"
      return 1
    fi
    survivor_number="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.container-number" }}' "$survivor_cid" 2>/dev/null || true)"
    log_prefix="extraction-worker-${survivor_number}"
    if ! log_output="$(compose --profile full logs --no-color --since "$killed_at_iso" extraction-worker 2>&1)"; then
      bad "iteracion $i: no se pudieron leer logs de extraction-worker desde $killed_at_iso: $log_output"
      return 1
    fi
    xautoclaim_line="$(awk -v prefix="$log_prefix" 'tolower($0) ~ /xautoclaim/ && index($0, prefix) > 0 { print; exit }' <<<"$log_output")"
    note "iteracion $i: recuperacion=${recovery_ms}ms (${recovery_seconds}s); linea XAUTOCLAIM sobreviviente=${xautoclaim_line:-no observada}"
    if ((recovery_ms < 600000)); then
      bad "iteracion $i: latencia ${recovery_ms}ms inferior a 600000ms; XAUTOCLAIM no queda demostrado"
      return 1
    fi
    if [[ -z "$xautoclaim_line" ]]; then
      bad "iteracion $i: no se encontro linea XAUTOCLAIM en los logs de $log_prefix; escenario no validado"
      return 1
    fi
    completed=$((completed + 1))
  done
  note "cobertura PROCESSING: alcanzada=$completed/$runs no_alcanzada=$missed/$runs"
  if ((missed > 0)); then
    bad "S4-P4-02: cobertura PROCESSING incompleta ($completed/$runs); repetir para obtener evidencia"
    return 1
  fi
  pass "S4-P4-02: $completed repeticiones convergieron; cobertura no alcanzada=$missed"
}

chaos4() {
  local id state status txt_ref completions terminal_count orphan_count event_type event_detail
  log "S4-P4-04: Mongo cae durante el cierre"
  require_full_worker || return 1
  new_document "chaos4" "stop-mongo" || {
    local create_result=$?
    ((create_result == 2)) && return 0
    return 1
  }
  id="$NEW_DOC_ID"
  note "document_id=$id"
  IFS='|' read -r event_type event_detail _ < "$TMP_DIR/${id}.event"
  if [[ "$event_type" != "PROCESSING" ]]; then
    state="$(mongo_doc_state "$id")"
    bad "no se observo PROCESSING antes de detener Mongo; evento=$event_type estado=$(jq -r '.status // empty' <<<"$state")"
    return 1
  fi
  pass "documento en PROCESSING; Mongo detenido 25 s y restaurado healthy ($event_detail)"
  reconcile_once || note "reconciliador no confirmo lock; se esperara la convergencia observada"

  if ! state="$(wait_document_status "$id" 300 10)"; then
    state="$(mongo_doc_state "$id")"
    bad "S4-P4-04 no convergio; status=$(jq -r '.status // empty' <<<"$state") history=$(jq -c '.history // []' <<<"$state") txt_ref=$(jq -r '.txt_ref // empty' <<<"$state")"
    return 1
  fi
  status="$(jq -r '.status // empty' <<<"$state")"
  txt_ref="$(jq -r '.txt_ref // empty' <<<"$state")"
  terminal_count="$(mongo_eval "db.documents.countDocuments({status:{\$nin:['COMPLETED','FAILED','REJECTED','UPLOAD_EXPIRED']}})" | tail -n1)"
  [[ "$terminal_count" == "0" ]] \
    || { bad "documentos no terminales al final del barrido=$terminal_count"; return 1; }
  if [[ "$status" == "COMPLETED" ]]; then
    completions="$(jq -r '[.history[]? | select(.status=="COMPLETED")] | length' <<<"$state")"
    [[ "$completions" == "1" ]] || { bad "COMPLETED history=$completions (esperado 1)"; return 1; }
    orphan_count="$(minio_txt_count_for_document "$id")"
    [[ "$orphan_count" == "1" && -n "$txt_ref" ]] \
      || { bad "COMPLETED: .txt asociados=$orphan_count txt_ref=$txt_ref"; return 1; }
    minio_exists "extracted-txt/$txt_ref" \
      || { bad "COMPLETED: falta extracted-txt/$txt_ref"; return 1; }
    pass "S4-P4-04 COMPLETED: una transicion COMPLETED y un .txt; sin .txt huerfano"
  elif [[ "$status" == "FAILED" ]]; then
    orphan_count="$(minio_txt_count_for_document "$id")"
    [[ "$orphan_count" == "0" ]] \
      || { bad "FAILED: .txt huerfanos asociados=$orphan_count"; return 1; }
    pass "S4-P4-04 FAILED: sin .txt huerfano"
  else
    bad "estado terminal inesperado: $status"
    return 1
  fi
  pass "S4-P4-04: estado terminal $status; cero documentos no terminales al final del barrido"
}

preflight() {
  local tool
  for tool in docker curl jq openssl timeout; do
    command -v "$tool" >/dev/null 2>&1 || { bad "falta $tool"; exit 1; }
  done
  require_mc_image || exit 1
  [[ -f "$ENV_FILE" ]] || { bad "falta $ENV_FILE"; exit 1; }
  [[ -f "$OVERRIDE_FILE" ]] || { bad "falta $OVERRIDE_FILE"; exit 1; }
  [[ -f "$VALID_PDF" ]] || { bad "falta el fixture $VALID_PDF"; exit 1; }
  [[ -n "$REDIS_STREAM_KEY" ]] || { bad "REDIS_STREAM_KEY vacio"; exit 1; }
  [[ -n "$INTERNAL_TOKEN" ]] || { bad "INTERNAL_TOKEN vacio"; exit 1; }
  compose ps -q doc-service | grep -q . || { bad "doc-service no esta levantado"; exit 1; }
  wait_http "$API_BASE/healthz" "api.localhost:${HTTPS_PORT}:127.0.0.1" 5 \
    || { bad "doc-service no responde /healthz"; exit 1; }
  redis_available || { bad "Redis no autentica con $ENV_FILE"; exit 1; }
}

record_case() {
  local result=0
  CASE_ENV_BLOCKED=0
  "$@" || result=$?
  ((CASE_ENV_BLOCKED == 1)) && return 0
  if ((result == 0)); then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}

log "API_BASE=$API_BASE proyecto=$PROJECT redis_down=${REDIS_DOWN_SECONDS}s chaos1_runs=${CHAOS1_RACE_RUNS} chaos2_runs=${CHAOS2_RUNS} chaos2_mode=$CHAOS2_MODE full=$FULL strict_relay=$STRICT_RELAY"
preflight

if ((RUN_CHAOS1 == 1)); then
  record_case chaos1_race
  restore_services
fi

if ((RUN_CHAOS1_KILL == 1)); then
  record_case chaos1_kill
  restore_services
fi

if ((RUN_CHAOS3 == 1)); then
  record_case chaos3
  restore_services
fi

if ((RUN_CHAOS2 == 1)); then
  CASE_ENV_BLOCKED=0
  case_result=0
  restore_failed=0
  if [[ "$CHAOS2_MODE" == "seed" ]]; then
    chaos2_seed || case_result=$?
  else
    chaos2_kill || case_result=$?
  fi
  if ! restore_one_worker; then
    restore_failed=1
  fi
  if ((CASE_ENV_BLOCKED == 0)); then
    if ((case_result == 0 && restore_failed == 0)); then
      TOTAL_PASS=$((TOTAL_PASS + 1))
    else
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
  elif ((restore_failed == 1)); then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  restore_services
fi

if ((RUN_CHAOS4 == 1)); then
  record_case chaos4
  restore_services
fi

echo
log "resumen: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL BLOCKED=$TOTAL_BLOCKED KNOWN=$TOTAL_KNOWN"
if ((TOTAL_FAIL > 0)); then
  exit 1
fi
exit 0
