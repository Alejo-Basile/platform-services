import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';
const FIXTURE = __ENV.FIXTURE || '../../fixtures/pdf/baseline-0001.pdf';
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
    'checks{check:terminal_status}': ['rate==1'],
  },
};

export default function () {
  const docId = `load-${RUN_ID}-${exec.vu.idInTest}-${exec.scenario.iterationInInstance}`;
  const body = JSON.stringify({ idempotency_key: docId, size_bytes: 12345 });
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
  
  // Build multipart
  const data = {};
  Object.keys(formFields).forEach((k) => { data[k] = formFields[k]; });
  // Attach file - k6 can read file
  const f = open(FIXTURE, 'b');
  data['file'] = http.file(f, 'doc.pdf', 'application/pdf');
  
  const u = http.post(uploadUrl, data, { tags: { endpoint: 'upload' }, timeout: '60s' });
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
