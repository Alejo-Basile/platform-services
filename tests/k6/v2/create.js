import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';
// Pausa entre iteraciones del smoke: mantiene el ritmo por debajo del
// forwardAuth rate-limit (10 rps / burst 20) de Traefik. Las corridas de carga
// (run-v2.sh) no la definen y conservan el ritmo sin pausa.
const SMOKE_SLEEP = Number(__ENV.SMOKE_SLEEP || 0);
const RUN_ID = __ENV.RUN_ID || 'local';

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
  scenarios: {
    create: {
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
  const body = JSON.stringify({
    idempotency_key: `k6-${RUN_ID}-${__VU}-${__ITER}`,
    size_bytes: 12345,
  });
  const res = http.post(`${BASE_URL}/api/v2/documents`, body, {
    headers: { 'Content-Type': 'application/json' },
    tags: { endpoint: 'create' },
  });

  check(res, {
    'create 201': (r) => r.status === 201,
    'create document_id': (r) => Boolean(r.json('document_id')),
    'create presigned url': (r) => String(r.json('upload_url')).startsWith('http'),
    'create form_fields': (r) => Boolean(r.json('form_fields.key')),
    'create expires_at': (r) => Boolean(r.json('expires_at')),
  });

  sleep(SMOKE_SLEEP);
}
