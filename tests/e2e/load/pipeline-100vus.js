// Carga del pipeline con un perfil de VUs: subida subita, meseta y bajada.
//
// Perfil por defecto:
//   0 -> 100 VUs en 10s | 100 VUs durante 20s | 100 -> 0 VUs en 10s
//
// Cada iteracion crea un documento, sube el PDF y espera su estado terminal,
// asi que el volumen depende del throughput del worker (el perfil es la carga
// de clientes concurrentes, no un numero fijo de documentos).
//
// Uso (desde la carpeta donde quieras los resultados):
//
//   BASE_URL=https://load.localhost:8543 \
//   k6 run --log-format=raw --summary-trend-stats "avg,p(90),p(95),p(99),max" \
//     --summary-export ./summary.json /ruta/a/pipeline-100vus.js
//
// Variables (todas opcionales):
//   BASE_URL        default https://load.localhost:8543
//   VUS             VUs de la meseta (default 100)
//   RAMP_UP         subida (default 10s)
//   HOLD            meseta (default 20s)
//   RAMP_DOWN       bajada (default 10s)
//   FIXTURE         PDF a subir (default ../../fixtures/pdf/baseline-0001.pdf)
//   POLL_INTERVAL   segundos entre polls (default 1)
//   POLL_MAX        polls maximos por documento (default 600)
//   MIN_COMPLETED   umbral opcional de COMPLETED; 0 = sin umbral
//   P95_MS          threshold de e2e_latency_ms p95; 0 = desactivado
//   STOP            gracefulStop para drenar iteraciones en vuelo (default 15m)
//   RUN_ID          prefijo de los idempotency_key
//
// El PDF de fixtures es minimo (609 B, 1 pagina): mide throughput del pipeline
// (create -> upload -> relay -> worker -> COMPLETED), no CPU de extraccion.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'https://load.localhost:8543';
const FIXTURE = __ENV.FIXTURE || '../../fixtures/pdf/baseline-0001.pdf';
const POLL_INTERVAL = Number(__ENV.POLL_INTERVAL || 1);
const RUN_ID = __ENV.RUN_ID || `vus-${Date.now()}`;
const TERMINAL_STATES = ['COMPLETED', 'FAILED', 'REJECTED', 'UPLOAD_EXPIRED'];

function positiveInt(raw, fallback) {
  const value = Math.floor(Number(raw));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const VUS = positiveInt(__ENV.VUS, 100);
const RAMP_UP = __ENV.RAMP_UP || '10s';
const HOLD = __ENV.HOLD || '20s';
const RAMP_DOWN = __ENV.RAMP_DOWN || '10s';
const POLL_MAX = positiveInt(__ENV.POLL_MAX, 600);
const MIN_COMPLETED = Math.max(0, Number(__ENV.MIN_COMPLETED || 0));
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
// el orden de las claves de un objeto (falla con 400/403), asi que armamos el
// cuerpo a mano: campos en orden y el archivo al final.
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
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: RAMP_UP, target: VUS },
        { duration: HOLD, target: VUS },
        { duration: RAMP_DOWN, target: 0 },
      ],
      gracefulRampDown: '30s',
      // Las iteraciones en vuelo esperan al worker; el escenario drena aca.
      gracefulStop: __ENV.STOP || '15m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    ...(MIN_COMPLETED > 0 ? { completed_documents: [`count>=${MIN_COMPLETED}`] } : {}),
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
    console.log(JSON.stringify({
      event: 'create_failed',
      doc_id: docId,
      status: created.status,
      body: String(created.body || '').slice(0, 200),
    }));
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
      body: String(uploaded.body || '').slice(0, 200),
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
