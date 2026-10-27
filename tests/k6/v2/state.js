import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';
const RUN_ID = __ENV.RUN_ID || 'local';

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
  scenarios: {
    state: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '10s', target: 5 },
        { duration: '30s', target: 5 },
        { duration: '5s', target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_failed: ['rate==0'],
    checks: ['rate==1'],
    ...(Number(__ENV.P95_MS || 0) > 0
      ? { http_req_duration: [`p(95)<${Number(__ENV.P95_MS)}`] }
      : {}),
  },
};

export default function () {
  const id = `k6-state-${RUN_ID}-${__VU}-${__ITER}`;
  const create = http.post(
    `${BASE_URL}/api/v2/documents`,
    JSON.stringify({ idempotency_key: id, size_bytes: 12345 }),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { endpoint: 'create_for_state' },
    },
  );
  check(create, { 'create for state 201': (r) => r.status === 201 });

  const state = http.get(`${BASE_URL}/api/v2/documents/${id}`, {
    tags: { endpoint: 'state' },
  });
  check(state, {
    'state 200': (r) => r.status === 200,
    'state document_id': (r) => r.json('document_id') === id,
    'state PENDING_UPLOAD': (r) => r.json('status') === 'PENDING_UPLOAD',
  });
}
