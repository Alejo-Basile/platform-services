import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:8000';
const PDF_COUNT = 100;

// Los PDFs se cargan en el contexto de inicialización (requisito de k6 para open()).
// Son 100 documentos con texto único: los primeros 100 POST recorren la extracción real;
// a partir de ahí el monolito responde desde su caché por hash. El informe lo declara.
const PDFS = [];
for (let i = 1; i <= PDF_COUNT; i++) {
  const name = `baseline-${String(i).padStart(4, '0')}.pdf`;
  PDFS.push({
    name,
    data: open(`../../fixtures/pdf/${name}`, 'b'),
  });
}

export const options = {
  scenarios: {
    pdf_process: {
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
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const index = (__VU * 1000 + __ITER) % PDFS.length;
  const pdf = PDFS[index];
  const res = http.post(
    `${BASE_URL}/pdf/process`,
    { file: http.file(pdf.data, pdf.name, 'application/pdf') },
    { tags: { endpoint: 'pdf_process' } },
  );

  check(res, {
    'pdf_process 200/409': (r) => r.status === 200 || r.status === 409,
    'pdf_process devuelve texto': (r) => String(r.body).includes('PDF EXTRACTEXT'),
  });
}
