import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import exec from 'k6/execution';

// S7-P4-04: dispara TOTAL_REQUESTS peticiones en una ráfaga densa y cuenta
// cuántas pasan (200) y cuántas se rechazan (429). El runner
// run-limit-verification.sh compara esos contadores con el límite esperado.
//
// Parámetros (todos opcionales):
//   BASE_URL        default https://api.localhost:8543
//   SCENARIO_PATH   ruta bajo el límite (default /api/v2/documents)
//   DOC_ID          opcional; se agrega al final de SCENARIO_PATH
//   TOTAL_REQUESTS  peticiones de la ráfaga (default 100)
//   VUS             VUs concurrentes (default = TOTAL_REQUESTS)
//   MAX_DURATION    techo del escenario (default 30s)
//   P95_MS          umbral opcional de latencia p95 (default sin umbral)
//   RUN_ID          trazabilidad (se propaga como header)
//
// La ráfaga es intencionalmente densa: `shared-iterations` reparte
// TOTAL_REQUESTS entre VUS sin pausa para que la ventana medida sea corta y el
// relleno del token bucket aporte lo mínimo. Aun así el relleno nunca es cero,
// por eso el runner calcula el máximo teórico con la ventana observada
// (request_start_offset_ms / request_end_offset_ms) en lugar de asumir que no
// hubo relleno.

function positiveInteger(raw, fallback) {
  const value = Math.floor(Number(raw));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';
const SCENARIO_PATH = __ENV.SCENARIO_PATH || '/api/v2/documents';
const DOC_ID = __ENV.DOC_ID || '';
const TOTAL_REQUESTS = positiveInteger(__ENV.TOTAL_REQUESTS, 100);
const VUS = Math.min(TOTAL_REQUESTS, positiveInteger(__ENV.VUS, TOTAL_REQUESTS));
const MAX_DURATION = __ENV.MAX_DURATION || '30s';
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
    burst: {
      executor: 'shared-iterations',
      vus: VUS,
      iterations: TOTAL_REQUESTS,
      maxDuration: MAX_DURATION,
    },
  },
  thresholds: {
    checks: ['rate==1'],
    unexpected_status_total: ['count==0'],
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
