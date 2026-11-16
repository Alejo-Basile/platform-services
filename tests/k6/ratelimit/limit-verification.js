import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import exec from 'k6/execution';

// S7-P4-04: dispara peticiones a una tasa controlada (constant-arrival-rate)
// durante una ventana fija y cuenta cuántas pasan (200) y cuántas se rechazan
// (429). El runner run-limit-verification.sh compara esos contadores con el
// máximo teórico del límite GCRA para la ventana del escenario.
//
// Por qué arribos pautados y no una ráfaga de VUs: con `shared-iterations` la
// ventana real de llegada al limitador no se puede medir desde k6 (el gateway
// puede encolar las evaluaciones), y el relleno de tokens durante esa cola
// hacía que el conteo esperado fuera indeterminable. Con una tasa de ataque
// superior al límite y una ventana fija, el máximo teórico es exacto:
// burst + rate * duración.
//
// Parámetros (todos opcionales):
//   BASE_URL        default https://api.localhost:8543
//   SCENARIO_PATH   ruta bajo el límite (default /api/v2/documents)
//   DOC_ID          opcional; se agrega al final de SCENARIO_PATH
//   ATTACK_RATE     arribos por segundo (default 20)
//   DURATION        ventana del escenario en segundos, formato k6 (default 4s)
//   PRE_VUS         VUs preasignados (default max(20, ATTACK_RATE*3))
//   P95_MS          umbral opcional de latencia p95 (default sin umbral)
//   RUN_ID          trazabilidad (se propaga como header)

function positiveInteger(raw, fallback) {
  const value = Math.floor(Number(raw));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';
const SCENARIO_PATH = __ENV.SCENARIO_PATH || '/api/v2/documents';
const DOC_ID = __ENV.DOC_ID || '';
const ATTACK_RATE = positiveInteger(__ENV.ATTACK_RATE, 20);
const DURATION = __ENV.DURATION || '4s';
const PRE_VUS = positiveInteger(__ENV.PRE_VUS, Math.max(20, ATTACK_RATE * 3));
const RUN_ID = __ENV.RUN_ID || 'local';

const targetURL = DOC_ID
  ? `${BASE_URL}${SCENARIO_PATH}/${encodeURIComponent(DOC_ID)}`
  : `${BASE_URL}${SCENARIO_PATH}`;

const allowed = new Counter('allowed_total');
const denied = new Counter('denied_total');
const unexpected = new Counter('unexpected_status_total');
const startOffset = new Trend('request_start_offset_ms');
const endOffset = new Trend('request_end_offset_ms');

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
  scenarios: {
    paced: {
      executor: 'constant-arrival-rate',
      rate: ATTACK_RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PRE_VUS,
      maxVUs: PRE_VUS * 2,
    },
  },
  thresholds: {
    checks: ['rate==1'],
    unexpected_status_total: ['count==0'],
    // Un arribo no emitido invalida la ventana: no se puede comparar contra el
    // máximo teórico si k6 no llegó a disparar la carga pautada.
    dropped_iterations: ['count==0'],
    ...(Number(__ENV.P95_MS || 0) > 0
      ? { http_req_duration: [`p(95)<${Number(__ENV.P95_MS)}`] }
      : {}),
  },
};

export default function () {
  const scenarioStart = Number(exec.scenario.startTime) || Date.now();
  const startedAt = Date.now();
  const response = http.get(targetURL, {
    headers: { 'X-Correlation-Id': RUN_ID },
    tags: { endpoint: 'limit-verification' },
  });
  const finishedAt = Date.now();

  startOffset.add(startedAt - scenarioStart);
  endOffset.add(finishedAt - scenarioStart);

  check(response, {
    'status 200 o 429': (result) => result.status === 200 || result.status === 429,
  });

  if (response.status === 200) {
    allowed.add(1);
    return;
  }
  if (response.status === 429) {
    denied.add(1);
    return;
  }
  unexpected.add(1);
}
