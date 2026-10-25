import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://api.localhost:8543';

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
  scenarios: {
    list: {
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
  const res = http.get(`${BASE_URL}/api/v2/documents?limit=10`, {
    tags: { endpoint: 'list' },
  });
  check(res, {
    'list 200': (r) => r.status === 200,
    'list documents': (r) => Array.isArray(r.json('documents')),
    'list has_more boolean': (r) => typeof r.json('has_more') === 'boolean',
  });
}
