// Carga del pipeline con un numero EXACTO de documentos (default 1000).
//
// A diferencia de pipeline.js (ramping-arrival-rate, donde el volumen real
// depende de la rampa), aca los arribos son pautados: RATE iteraciones por
// segundo durante DOCS/RATE segundos => exactamente DOCS documentos.
// El ritmo se mantiene bajo la ruta sensible POST /api/v2/documents (5/s).
//
// Uso (desde la carpeta donde quieras los resultados):
//
//   BASE_URL=https://load.localhost:8543 \
//   k6 run --log-format=raw --summary-trend-stats "avg,p(90),p(95),p(99),max" \
//     --summary-export ./summary.json /ruta/a/pipeline-1000.js
//
// Variables (todas opcionales):
//   BASE_URL             default https://load.localhost:8543
//   DOCS                 documentos a crear (default 1000)
//   RATE                 creates por segundo (default 2; debe quedar < 5)
//   PRE_VUS / MAX_VUS    VUs preasignados / maximos (default 20 / 60)
//   FIXTURE              PDF a subir (default ../../fixtures/pdf/baseline-0001.pdf)
//   POLL_INTERVAL        segundos entre polls de estado (default 2)
//   POLL_MAX             polls maximos por documento (default 300)
//   EXPECTED_COMPLETED   DOCS que deben terminar COMPLETED (default DOCS)
//   P95_MS               threshold de e2e_latency_ms p95; 0 = desactivado
//   RUN_ID               prefijo de los idempotency_key
//
// El PDF de fixtures es minimo (609 B): mide throughput del pipeline
// (create -> upload -> relay -> worker -> COMPLETED), no CPU de extraccion.
// Para castigar el worker usa FIXTURE con un PDF grande.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'https://load.localhost:8543';
const FIXTURE = __ENV.FIXTURE || '../../fixtures/pdf/baseline-0001.pdf';
const POLL_INTERVAL = Number(__ENV.POLL_INTERVAL || 2);
const RUN_ID = __ENV.RUN_ID || `docs-${Date.now()}`;
const TERMINAL_STATES = ['COMPLETED', 'FAILED', 'REJECTED', 'UPLOAD_EXPIRED'];

function positiveInt(raw, fallback) {
  const value = Math.floor(Number(raw));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const DOCS = positiveInt(__ENV.DOCS, 1000);
// `POST /api/v2/documents` es una ruta sensible propia (Consul KV:
// sensitive_routes=5:10 => rate 5/s, burst 10). Se pauta por debajo de 5/s;
// si DOCS no es divisible por RATE, se usa 1/s para conservar el conteo exacto.
let RATE = positiveInt(__ENV.RATE, 2);
if (DOCS % RATE !== 0) RATE = 1;
const DURATION_S = DOCS / RATE;
const PRE_VUS = positiveInt(__ENV.PRE_VUS, 20);
const MAX_VUS = Math.max(PRE_VUS, positiveInt(__ENV.MAX_VUS, 60));
const POLL_MAX = positiveInt(__ENV.POLL_MAX, 300);
const EXPECTED_COMPLETED = positiveInt(__ENV.EXPECTED_COMPLETED, DOCS);
const P95_MS = Number(__ENV.P95_MS || 0);

// open() solo es valido en el init (global scope), no dentro de la iteracion.
const FIXTURE_BYTES = open(FIXTURE, 'b');

const CRLF = '\r\n';

// ASCII -> bytes. Los campos del POST policy son base64/hex/URLs, todos ASCII.
function asciiBytes(text) {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i) & 0xff;
  return out;
}

// MinIO exige que la parte `file` sea la ULTIMA del multipart. k6 no garantiza
// el orden de las claves de un objeto (lo vimos fallar con 400/403), asi que
// armamos el cuerpo a mano: campos en orden y el archivo al final.
function buildMultipart(fields, fileBytes, fileName, fileType) {
  const boundary = `----k6${Date.now().toString(16)}${Math.random().toString(16).slice(2)}`;
  const parts = [];
  for (const [name, value] of fields) {
    parts.push(asciiBytes(
      `--${boundary}${CRLF}` +
      `Content-Disposition: form-data; name="${name}"${CRLF}${CRLF}${value}${CRLF}`,
    ));
  }
  parts.push(asciiBytes(
    `--${boundary}${CRLF}` +
    `Content-Disposition: form-data; name="file"; filename="${fileName}"${CRLF}` +
    `Content-Type: ${fileType}${CRLF}${CRLF}`,
  ));
  parts.push(new Uint8Array(fileBytes));
  parts.push(asciiBytes(`${CRLF}--${boundary}--${CRLF}`));

  const total = parts.reduce((n, p) => n + p.length, 0);
  const body = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    body.set(part, offset);
    offset += part.length;
  }
  return { body: body.buffer, contentType: `multipart/form-data; boundary=${boundary}` };
}

const terminalDocuments = new Counter('terminal_documents');
const completedDocuments = new Counter('completed_documents');
const failedDocuments = new Counter('failed_documents');
// Tiempo end-to-end: desde antes del create hasta el estado terminal.
const e2eLatency = new Trend('e2e_latency_ms', true);

export const options = {
  insecureSkipTLSVerify: true,
  scenarios: {
    docs: {
      // Arribos pautados: RATE iteraciones por segundo durante DURATION_S.
      // Total = RATE * DURATION_S = DOCS (exacto, sin rafagas de create).
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: `${DURATION_S}s`,
      preAllocatedVUs: PRE_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    terminal_documents: [`count>=${EXPECTED_COMPLETED}`],
    completed_documents: [`count>=${EXPECTED_COMPLETED}`],
    ...(P95_MS > 0 ? { e2e_latency_ms: [`p(95)<${P95_MS}`] } : {}),
  },
};

export default function () {
  const docId = `k6-${RUN_ID}-${exec.vu.idInTest}-${exec.scenario.iterationInInstance}`;
  const startedAt = Date.now();

  const created = http.post(
    `${BASE_URL}/api/v2/documents`,
    JSON.stringify({ idempotency_key: docId, size_bytes: 12345 }),
    { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'create' } },
  );
  if (!check(created, { 'create 201': (r) => r.status === 201 })) {
    console.log(JSON.stringify({ event: 'create_failed', doc_id: docId, status: created.status }));
    return;
  }

  const createJson = created.json();
  const uploadUrl = createJson.upload_url;
  const fields = Object.entries(createJson.form_fields || {});
  const multipart = buildMultipart(fields, FIXTURE_BYTES, 'doc.pdf', 'application/pdf');

  const uploaded = http.post(uploadUrl, multipart.body, {
    headers: { 'Content-Type': multipart.contentType },
    tags: { endpoint: 'upload' },
    timeout: '60s',
  });
  if (!check(uploaded, { 'upload 2xx': (r) => r.status >= 200 && r.status < 300 })) {
    console.log(JSON.stringify({
      event: 'upload_failed',
      doc_id: docId,
      status: uploaded.status,
      body: String(uploaded.body || '').slice(0, 300),
    }));
    return;
  }

  let status = 'UNKNOWN';
  let terminal = false;
  let terminalAt = 0;
  for (let i = 0; i < POLL_MAX; i++) {
    const poll = http.get(`${BASE_URL}/api/v2/documents/${docId}`, {
      tags: { endpoint: 'poll' },
      timeout: '10s',
    });
    if (poll.status === 200) {
      try {
        status = poll.json().status || status;
        if (TERMINAL_STATES.includes(status)) {
          terminal = true;
          terminalAt = Date.now();
          break;
        }
      } catch (e) { /* respuesta no-JSON: seguir polleando */ }
    }
    sleep(POLL_INTERVAL);
  }

  check(terminal, { terminal_status: (v) => v === true });
  if (terminal) {
    terminalDocuments.add(1);
    e2eLatency.add(terminalAt - startedAt);
  }
  if (status === 'COMPLETED') {
    completedDocuments.add(1);
  } else if (terminal) {
    failedDocuments.add(1);
  }

  console.log(JSON.stringify({
    event: 'result',
    doc_id: docId,
    status,
    terminal,
    duration_ms: terminal ? terminalAt - startedAt : -1,
  }));
}
