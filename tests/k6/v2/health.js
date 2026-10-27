import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
  scenarios: {
    health: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '10s', target: 10 },
        { duration: '30s', target: 10 },
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
  const res = http.get(`${BASE_URL}/healthz`, { tags: { endpoint: 'healthz' } });
  check(res, {
    'healthz 200': (r) => r.status === 200,
    'healthz healthy': (r) => String(r.body).includes('"status":"healthy"'),
  });
}
