#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317,SC2329
# Caos parcial de S4-P4: S4-P4-01 (doc-service tras webhook), su variante
# Redis caido + SIGKILL, y S4-P4-03 (Redis Streams caido). Requiere el stack
# E2E ya levantado; no lo levanta.
#
# Uso:
#   tests/e2e/chaos/run.sh --all
#   tests/e2e/chaos/run.sh --chaos1          # ventana webhook -> XADD (real)
#   tests/e2e/chaos/run.sh --chaos1-kill     # variante Redis caido + SIGKILL
#   P4_CHAOS_REDIS_SECONDS=10 tests/e2e/chaos/run.sh --chaos3
#   tests/e2e/chaos/run.sh --all --full      # cuando exista worker real
#   P4_STRICT_RELAY=1 tests/e2e/chaos/run.sh --all  # exige recuperacion por relay
#
# Sin worker real, los caos terminan en la cola y el aserto COMPLETED queda
# BLOQUEADO. --full convierte ese bloqueo en fallo.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

REDIS_DOWN_SECONDS="${P4_CHAOS_REDIS_SECONDS:-300}"
CHAOS1_RACE_RUNS="${P4_CHAOS1_RACE_RUNS:-10}"
STRICT_RELAY="${P4_STRICT_RELAY:-0}"
RELAY_ISSUE="doc-service#55"
RUN_CHAOS1=0
RUN_CHAOS1_KILL=0
RUN_CHAOS3=0
FULL=0

usage() {
  cat <<'EOF'
Uso: tests/e2e/chaos/run.sh <--chaos1|--chaos1-kill|--chaos3|--all> [--full]

  --chaos1       S4-P4-01: doc-service muere entre webhook y XADD (real)
  --chaos1-kill  Variante: Redis caido + SIGKILL de doc-service
  --chaos3       S4-P4-03: Redis Streams cae durante la ventana configurada
  --all          los tres casos
  --full         exige COMPLETED (solo con worker real)

Variables:
  P4_CHAOS_REDIS_SECONDS   duracion de la caida de Redis (default 300)
  P4_CHAOS1_RACE_RUNS      repeticiones de --chaos1 (default 10)
  P4_STRICT_RELAY          si vale 1, exige que el relay reencole (default 0)
  P4_COMPOSE_PROJECT       proyecto Compose (default infra)
  P4_WORKSPACE_ROOT        workspace con infra/ y platform-services/
EOF
}

while (($# > 0)); do
  case "$1" in
    --chaos1) RUN_CHAOS1=1 ;;
    --chaos1-kill) RUN_CHAOS1_KILL=1 ;;
    --chaos3) RUN_CHAOS3=1 ;;
    --all) RUN_CHAOS1=1; RUN_CHAOS1_KILL=1; RUN_CHAOS3=1 ;;
    --full) FULL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ((RUN_CHAOS1 == 0 && RUN_CHAOS1_KILL == 0 && RUN_CHAOS3 == 0)); then
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
INTERNAL_TOKEN="$(env_value INTERNAL_TOKEN)"

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

mongo_eval() {
  local js="$1"
  compose exec -T -e P4_JS="$js" -e P4_DB="$MONGO_DATABASE" mongo sh -c '
    if [ -r /run/secrets/mongo_initdb_root_password ]; then
      PW=$(cat /run/secrets/mongo_initdb_root_password)
    else
      PW=$MONGO_INITDB_ROOT_PASSWORD
    fi
    mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$PW" \
      --authenticationDatabase admin "$P4_DB" --eval "$P4_JS"
  ' 2>/dev/null
}

mongo_status() {
  local id="$1"
  mongo_eval "var d=db.documents.findOne({_id:'$id'}); print(d?d.status:'')" | tail -n1
}

mongo_delete() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  mongo_eval "db.documents.deleteOne({_id:'$id'})" >/dev/null 2>&1 || true
}

mongo_age_document() {
  local id="$1"
  # Envejece también expires_at: el reconciliador solo toca PENDING_UPLOAD
  # vencidos y UPLOADED con updated_at viejo. Sin expires_at, un documento
  # que quedó PENDING_UPLOAD tras el kill nunca se recupera en la prueba.
  mongo_eval "db.documents.updateOne({_id:'$id'},{\$set:{created_at:new Date(Date.now()-45*60*1000),updated_at:new Date(Date.now()-45*60*1000),expires_at:new Date(Date.now()-45*60*1000)}}).modifiedCount" \
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
  local prefix="$1" body hdr code upload id
  id="${prefix}-$(date +%s)-$RANDOM"
  body="$TMP_DIR/${id}.json"
  hdr="$TMP_DIR/${id}.hdr"
  code="$(post_create "$id" "$(wc -c < "$VALID_PDF" | tr -d ' ')" "$body" "$hdr")"
  if [[ "$code" != "201" ]]; then
    bad "create HTTP $code"
    return 1
  fi
  upload="$(upload_pdf "$body" "$VALID_PDF" "application/pdf")"
  if ! [[ "$upload" =~ ^2[0-9][0-9]$ ]]; then
    bad "upload HTTP $upload"
    return 1
  fi
  NEW_DOC_ID="$id"
  NEW_DOC_KEY="$(cat "$TMP_DIR/upload.key")"
  CURRENT_DOCS+=("$id")
  CURRENT_KEYS+=("$NEW_DOC_KEY")
}

stop_service() {
  local svc="$1"
  compose stop "$svc" >/dev/null
  STOPPED+=("$svc")
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
  compose exec -T doc-service wget -qO- \
    --header="X-Internal-Token: ${INTERNAL_TOKEN}" \
    --post-data='{}' http://localhost:8080/internal/reconcile 2>/dev/null
}

worker_present() {
  compose --profile full config --services 2>/dev/null | grep -qx "extraction-worker"
}

require_full_worker() {
  if ((FULL == 1)) && ! worker_present; then
    bad "--full requiere un servicio extraction-worker en Compose"
    return 1
  fi
  return 0
}

cleanup() {
  restore_services
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
    done < <(stream_entries_for "$id" 2>/dev/null || true)
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

assert_single_entry() {
  local id="$1" count
  count="$(stream_entries_for "$id" | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    pass "una sola entrada en el stream para $id"
    return 0
  fi
  bad "entradas en el stream para $id: $count (esperado 1)"
  return 1
}

assert_completed() {
  local id="$1"
  if wait_status "$id" "COMPLETED" 120; then
    pass "documento COMPLETED: $id"
    return 0
  fi
  bad "documento no llego a COMPLETED: $id"
  return 1
}

chaos1_race() {
  local runs="$CHAOS1_RACE_RUNS" i id status_after recovered
  local hit_pending=0 hit_uploaded=0 hit_queued=0 forced=0
  log "S4-P4-01 (real): doc-service muere entre webhook y XADD (${runs} repeticiones)"
  require_full_worker || return 1

  for ((i = 1; i <= runs; i++)); do
    new_document "chaos1-race" || { restore_services; return 1; }
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
    entry_id="$(stream_entry_for "$id")"
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
      wait_stream_entry "$id" 20 && recovered="relay"
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

      mongo_age_document "$id" >/dev/null
      reconcile_once >/dev/null || true
      if ! wait_stream_entry "$id" 30; then
        # Segundo pase: PENDING_UPLOAD -> UPLOADED y, si el relay sigue roto,
        # UPLOADED estancado -> reencolado directo por el reconciliador.
        mongo_age_document "$id" >/dev/null
        reconcile_once >/dev/null || true
        if ! wait_stream_entry "$id" 30; then
          bad "iteracion $i: ni relay ni reconciliador encolaron $id"
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
  local id recovered=""
  log "S4-P4-01 (variante): Redis caido + SIGKILL de doc-service"
  require_full_worker || return 1

  stop_service redis-streams
  note "Redis detenido; el webhook no podra encolar"
  new_document "chaos1" || { restore_services; return 1; }
  id="$NEW_DOC_ID"
  wait_status "$id" "UPLOADED" 40 || { bad "el documento no quedo UPLOADED con Redis caido"; return 1; }
  pass "webhook proceso el evento y dejo UPLOADED"
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

  if wait_stream_entry "$id" 60; then
    recovered="relay"
  else
    note "relay no recupero el evento; se fuerza un ciclo de reconciliacion"
    mongo_age_document "$id" >/dev/null
    reconcile_once >/dev/null || true
    if wait_stream_entry "$id" 60; then
      recovered="reconciler"
    fi
  fi

  [[ -n "$recovered" ]] || { bad "ni relay ni reconciliador encolaron el documento"; return 1; }
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
    block "validacion de .txt/descarga/status_history pendiente de completar el arnes"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
  else
    block "COMPLETED bloqueado por G-B (worker real ausente)"
    TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
  fi
  pass "S4-P4-01 parcial"
}

chaos3() {
  local start elapsed remaining id recovered="" i
  local original_ids=()
  log "S4-P4-03: Redis caido ${REDIS_DOWN_SECONDS}s con trabajos encolados"
  require_full_worker || return 1

  for i in 1 2; do
    new_document "chaos3-pre" || { restore_services; return 1; }
    id="$NEW_DOC_ID"
    original_ids+=("$id")
    wait_stream_entry "$id" 40 || { bad "documento previo no encolado: $id"; return 1; }
    pass "documento previo encolado: $id"
  done

  start=$SECONDS
  stop_service redis-streams
  note "Redis detenido; se sube un documento durante la caida"
  new_document "chaos3-during" || { restore_services; return 1; }
  id="$NEW_DOC_ID"
  wait_status "$id" "UPLOADED" 40 || { bad "el documento de la caida no quedo UPLOADED"; return 1; }
  pass "documento subido durante la caida quedo UPLOADED"

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
  pass "entradas previas preservadas (AOF)"

  if wait_stream_entry "$id" 60; then
    recovered="relay"
  else
    note "relay no recupero el documento de la caida; se fuerza reconciliacion"
    mongo_age_document "$id" >/dev/null
    reconcile_once >/dev/null || true
    if wait_stream_entry "$id" 60; then
      recovered="reconciler"
    fi
  fi
  [[ -n "$recovered" ]] || { bad "el documento de la caida no se recupero"; return 1; }
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

preflight() {
  local tool
  for tool in docker curl jq openssl; do
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

log "API_BASE=$API_BASE proyecto=$PROJECT redis_down=${REDIS_DOWN_SECONDS}s chaos1_runs=${CHAOS1_RACE_RUNS} full=$FULL strict_relay=$STRICT_RELAY"
preflight

if ((RUN_CHAOS1 == 1)); then
  if chaos1_race; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  restore_services
fi

if ((RUN_CHAOS1_KILL == 1)); then
  if chaos1_kill; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  restore_services
fi

if ((RUN_CHAOS3 == 1)); then
  if chaos3; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  restore_services
fi

echo
log "resumen: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL BLOCKED=$TOTAL_BLOCKED KNOWN=$TOTAL_KNOWN"
if ((TOTAL_FAIL > 0)); then
  exit 1
fi
exit 0
