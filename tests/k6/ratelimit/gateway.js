import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const allowedTotal = new Counter('allowed_total');
const deniedTotal = new Counter('denied_total');
const serverErrorTotal = new Counter('server_error_total');

export const options = {
  insecureSkipTLSVerify: true,
  scenarios: {
    main: {
      executor: 'shared-iterations',
      vus: 12,
      iterations: 60,
      maxDuration: '60s',
    },
  },
  thresholds: {
    checks: ['rate==1'],
    denied_total: ['count>0'],
    server_error_total: ['count==0'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'https://127.0.0.1:8543';
const HOST_HEADER = __ENV.HOST_HEADER || 'api.localhost';
const TARGET_PATH = __ENV.TARGET_PATH || '/api/v2/documents';

// k6 canonicalizes header keys (X-RateLimit-Remaining becomes X-Ratelimit-Remaining
// and HTTP/2 may deliver them lowercase), so look names up case-insensitively.
function header(res, name) {
  const wanted = name.toLowerCase();
  for (const key of Object.keys(res.headers)) {
    if (key.toLowerCase() === wanted) return res.headers[key];
  }
  return '';
}

export default function () {
  const res = http.get(`${BASE_URL}${TARGET_PATH}`, {
    headers: { Host: HOST_HEADER },
  });
  if (res.status === 200) allowedTotal.add(1);
  else if (res.status === 429) deniedTotal.add(1);
  else if (res.status >= 500) serverErrorTotal.add(1);

  check(res, {
    'status is 200 or 429': (r) => r.status === 200 || r.status === 429,
    'zero 5xx': (r) => r.status < 500,
    '429 has Retry-After': (r) => r.status !== 429 || header(r, 'Retry-After').length > 0,
    '200 has X-RateLimit-Remaining': (r) => r.status !== 200 || header(r, 'X-RateLimit-Remaining').length > 0,
  });
}
