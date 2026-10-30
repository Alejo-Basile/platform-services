#!/usr/bin/env bash
# Reporte post-carga S5-P4-01 (Mongo + MinIO)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

COMPOSE_FILES+=(-f "$BUILD_FILE" -f "$OVERRIDE_FILE")

MONGO_DATABASE="$(env_value MONGO_DATABASE)"; MONGO_DATABASE="${MONGO_DATABASE:-documents}"
export P4_MONGO_DB="$MONGO_DATABASE"
OUT_DIR="$PLATFORM_ROOT/docs/evidencias/S5"
mkdir -p "$OUT_DIR"

REPORT_JSON="$OUT_DIR/S5-P4-01-report.json"
REPORT_CSV="$OUT_DIR/S5-P4-01-report.csv"
REPORT_MD="$OUT_DIR/S5-P4-01-report.md"

# Ventana por defecto: última hora (ajustable con P4_LOAD_SINCE)
SINCE="${P4_LOAD_SINCE:-$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)}"

log(){ printf '[load-report] %s\n' "$*"; }

log "Generando reporte S5-P4-01 desde $SINCE"
mongo_eval "
var since=ISODate('$SINCE');
var docs=db.documents.find({created_at:{\$gte:since}}).toArray();
var total=docs.length;
var byStatus={};
docs.forEach(function(d){ byStatus[d.status]=(byStatus[d.status]||0)+1; });
var terminal=['COMPLETED','FAILED','REJECTED','UPLOAD_EXPIRED'];
var nonTerminal=docs.filter(function(d){ return terminal.indexOf(d.status)==-1; }).length;
var completed=docs.filter(function(d){ return d.status=='COMPLETED'; });
// tiempos
var times=[];
docs.forEach(function(d){
  if(d.status=='COMPLETED' && d.created_at){
    var end=d.completed_at || (d.history && d.history.length? d.history[d.history.length-1].at : null);
    if(end){ times.push({id:d._id, ms:(new Date(end)-new Date(d.created_at))}); }
  }
});
times.sort(function(a,b){ return a.ms-b.ms; });
function pct(arr,p){ if(arr.length==0)return null; var idx=Math.ceil(arr.length*p)-1; if(idx<0)idx=0; return arr[idx].ms; }
var p50=pct(times,0.5), p95=pct(times,0.95), p99=pct(times,0.99);
var recovered=0;
docs.forEach(function(d){
  if(d.history){
    for(var i=0;i<d.history.length;i++){
      if(d.history[i].actor=='reconciler'){ recovered++; break; }
    }
  }
});
print(JSON.stringify({total:total,byStatus:byStatus,nonTerminal:nonTerminal,completed:completed.length,recovered:recovered,p50:p50,p95:p95,p99:p99,since:'$SINCE'},null,2));
" | tee "$REPORT_JSON"

jq -r '. | ["metric","valor"], ["total",.total], ["non_terminal",.nonTerminal], ["completed",.completed], ["recovered",.recovered], ["p50_ms",(.p50//"")], ["p95_ms",(.p95//"")], ["p99_ms",(.p99//"")] | @tsv' "$REPORT_JSON" > "$REPORT_CSV"

{
echo "# S5-P4-01 Reporte de carga"
echo
echo "- Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "- Ventana desde: $SINCE"
echo
jq -r '"- Total: \(.total)\n- No terminales: \(.nonTerminal)\n- Completados: \(.completed)\n- Recuperados por reconciliador: \(.recovered)\n- p50: \(.p50 // "N/A") ms\n- p95: \(.p95 // "N/A") ms\n- p99: \(.p99 // "N/A") ms"' "$REPORT_JSON"
echo
echo "## Por estado"
jq -r '.byStatus | to_entries[] | "- \(.key): \(.value)"' "$REPORT_JSON"
} > "$REPORT_MD"

log "Reporte generado: $REPORT_JSON $REPORT_CSV $REPORT_MD"
