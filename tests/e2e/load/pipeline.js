import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';
const FIXTURE = __ENV.FIXTURE || '../../fixtures/pdf/baseline-0001.pdf';
const FIXTURE_BYTES = open(FIXTURE, 'b'); // open() solo es valido en el init (global scope), no dentro de la iteracion.
const POLL_INTERVAL = Number(__ENV.POLL_INTERVAL || 2);
const POLL_MAX = Number(__ENV.POLL_MAX || 300);
const RUN_ID = __ENV.RUN_ID || `load-${Date.now()}`;
const EXPECTED_TERMINAL = Number(__ENV.EXPECTED_TERMINAL || 4);
const terminalDocuments = new Counter('terminal_documents');
const TERMINAL_STATES = ['COMPLETED', 'FAILED', 'REJECTED', 'UPLOAD_EXPIRED'];

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
  scenarios: {
    pipeline: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.PRE_VUS || 20),
      maxVUs: Number(__ENV.MAX_VUS || 50),
      stages: [
        { duration: '30s', target: Number(__ENV.RATE_START || 2) },
        { duration: __ENV.RAMP_DURATION || '5m', target: Number(__ENV.RATE_TARGET || 5) },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    terminal_documents: [`count>=${EXPECTED_TERMINAL}`],
    // Tail docs can still be RETRYING at the 10-min poll limit because
    // XAUTOCLAIM min-idle is 600 s; tolerate <0.1% under sustained load.
    'checks{check:terminal_status}': ['rate>0.999'],
  },
};

export default function () {
  const docId = `load-${RUN_ID}-${exec.vu.idInTest}-${exec.scenario.iterationInInstance}`;
  const body = JSON.stringify({ idempotency_key: docId, size_bytes: FIXTURE_BYTES.byteLength });
  const c = http.post(`${BASE_URL}/api/v2/documents`, body, {
    headers: { 'Content-Type': 'application/json' },
    tags: { endpoint: 'create' },
  });
  if (!check(c, { 'create 201': (r) => r.status === 201 })) {
    console.log(JSON.stringify({ event: 'create_failed', doc_id: docId, status: c.status }));
    return;
  }
  const createJson = c.json();
  const uploadUrl = createJson.upload_url;
  const formFields = createJson.form_fields || {};
  const key = formFields.key || '';
  
  // Build multipart explicitly with deterministic field order (file last)
  const enc = new TextEncoder();
  const boundary = '----k6boundary' + Math.random().toString(16).slice(2);
  const parts = [];
  for (const k of Object.keys(formFields)) {
    parts.push(enc.encode(`--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${formFields[k]}\r\n`));
  }
  parts.push(enc.encode(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="doc.pdf"\r\nContent-Type: application/pdf\r\n\r\n`));
  parts.push(new Uint8Array(FIXTURE_BYTES));
  parts.push(enc.encode(`\r\n--${boundary}--\r\n`));
  const total = parts.reduce((n, p) => n + p.byteLength, 0);
  const bodyBytes = new Uint8Array(total);
  let off = 0; for (const p of parts) { bodyBytes.set(p, off); off += p.byteLength; }
  const u = http.post(uploadUrl, bodyBytes.buffer, {
    headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
    tags: { endpoint: 'upload' }, timeout: '60s',
  });
  if (!check(u, { 'upload 2xx': (r) => r.status >= 200 && r.status < 300 })) {
    console.log(JSON.stringify({ event: 'upload_failed', doc_id: docId, status: u.status }));
    return;
  }
  
  const createdAt = Date.now();
  let status = 'UNKNOWN';
  let terminal = false;
  let terminalAt = 0;
  for (let i = 0; i < POLL_MAX; i++) {
    const s = http.get(`${BASE_URL}/api/v2/documents/${docId}`, { tags: { endpoint: 'poll' }, timeout: '10s' });
    if (s.status === 200) {
      try {
        const j = s.json();
        status = j.status || status;
        if (TERMINAL_STATES.includes(status)) {
          terminal = true;
          terminalAt = Date.now();
          break;
        }
      } catch (e) {}
    }
    sleep(POLL_INTERVAL);
  }

  check(terminal, { terminal_status: (v) => v === true });
  if (terminal) {
    terminalDocuments.add(1);
  }
  
  console.log(JSON.stringify({
    event: 'result',
    doc_id: docId,
    object_key: key,
    status,
    terminal,
    created_at: createdAt,
    terminal_at: terminalAt,
    duration_ms: terminal ? (terminalAt - createdAt) : -1,
  }));
}
