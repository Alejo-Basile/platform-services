import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const allowed = new Counter('allowed_total');
const denied = new Counter('denied_total');
const unexpected = new Counter('unexpected_status_total');

export const options = {
  insecureSkipTLSVerify: true,
  hosts: { 'api.localhost': '127.0.0.1' },
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
    allowed_total: ['count>0'],
    denied_total: ['count>0'],
    unexpected_status_total: ['count==0'],
  },
};

const baseURL = __ENV.BASE_URL || 'https://api.localhost:8543';
const documentID = __ENV.DOC_ID;

if (!documentID) {
  throw new Error('DOC_ID is required');
}

export default function () {
  const response = http.get(`${baseURL}/api/v2/documents/${encodeURIComponent(documentID)}`);
  check(response, {
    'gateway returns 200 or 429': (result) => result.status === 200 || result.status === 429,
  });

  if (response.status === 200) {
    allowed.add(1);
    return;
  }
  if (response.status === 429) {
    denied.add(1);
    return;
  }
  unexpected.add(1);
}
