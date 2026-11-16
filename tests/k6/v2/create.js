import http from 'k6/http';
import { check, sleep } from 'k6';

// Functional smoke for the v2 create endpoint.
//
// The gateway applies a global ForwardAuth limit of rate=10/s and burst=20
// (infra/traefik/dynamic/middlewares.yml). This smoke must stay below that
// limit so a 429 is a real failure, not expected load shedding. The scenario
// that EXPECTS 429 is tests/k6/ratelimit/gateway.js; do not move that
// assertion here.
//
// Tunables (all optional):
//   CREATE_RATE              arrivals per second (default 5; keep it < 10)
//   CREATE_DURATION          scenario duration (default 10s)
//   CREATE_PREALLOCATED_VUS  VUs reserved for the arrival rate (default 2)
//   CREATE_MAX_VUS           maximum VUs (default 5)
//
// Default load: 5 arrivals/s for 10s => about 50 create requests. run-smoke.sh
// shortens the duration to 5s => about 25 iterations. The gateway allows 10/s
// with burst 20, so the default keeps a 2x safety margin. Setting CREATE_RATE
// at or above 10 can legitimately produce 429s and fail this functional smoke.

function positiveNumber(raw, fallback) {
  const value = Number(raw);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function positiveInteger(raw, fallback) {
  const value = Math.floor(Number(raw));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const CREATE_RATE = positiveNumber(__ENV.CREATE_RATE, 5);
const CREATE_DURATION = __ENV.CREATE_DURATION || '10s';
const CREATE_PREALLOCATED_VUS = positiveInteger(__ENV.CREATE_PREALLOCATED_VUS, 2);
const CREATE_MAX_VUS = Math.max(
  CREATE_PREALLOCATED_VUS,
  positiveInteger(__ENV.CREATE_MAX_VUS, 5),
);

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
      executor: 'constant-arrival-rate',
      rate: CREATE_RATE,
      timeUnit: '1s',
      duration: CREATE_DURATION,
      preAllocatedVUs: CREATE_PREALLOCATED_VUS,
      maxVUs: CREATE_MAX_VUS,
      gracefulStop: '5s',
    },
  },
  thresholds: {
    // A 429, a 5xx, or a contract mismatch must fail the functional smoke.
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
