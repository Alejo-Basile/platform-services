import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const allowed = new Counter('allowed_total');
const denied = new Counter('denied_total');

// 100 clientes concurrentes sobre la misma clave. Con rate=0.1/s y burst=1
// debe permitirse exactamente 1 petición y rechazarse 99.
export const options = {
  scenarios: {
    burst: {
      executor: 'shared-iterations',
      vus: 100,
      iterations: 100,
      maxDuration: '20s',
    },
  },
  thresholds: {
    checks: ['rate==1'],
    allowed_total: ['count==1'],
    denied_total: ['count==99'],
  },
};

const baseURL = __ENV.BASE_URL || 'http://127.0.0.1:8090';
const runID = __ENV.RUN_ID || `${Date.now()}`;
const key = `k6-concurrency-${runID}`;

export default function () {
  const url = `${baseURL}/check?key=${encodeURIComponent(key)}&rate=0.1&burst=1`;
  const res = http.get(url);

  check(res, {
    'status 200 o 429': (r) => r.status === 200 || r.status === 429,
    'cuerpo JSON': (r) => (r.headers['Content-Type'] || '').includes('application/json'),
  });

  if (res.status === 200) allowed.add(1);
  else if (res.status === 429) denied.add(1);
}
