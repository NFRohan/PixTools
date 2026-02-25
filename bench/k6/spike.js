import { check } from 'k6';
import { Counter } from 'k6/metrics';

import { BASE_URL } from './lib/config.js';
import { submitJob } from './lib/jobs.js';

const jobsSubmitted = new Counter('jobs_submitted_total');
const jobsFailed = new Counter('jobs_failed_total');

export const options = {
  scenarios: {
    spike: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 500),
      duration: __ENV.DURATION || '2m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.10'],
    http_req_duration: ['p(95)<2000'],
  },
};

export default function () {
  const idempotencyKey = `spike-${__VU}-${__ITER}-${Date.now()}`;
  const { response, jobId } = submitJob({
    baseUrl: BASE_URL,
    operations: ['webp'],
    operationParams: { webp: { quality: 75 } },
    idempotencyKey,
    timeout: __ENV.REQUEST_TIMEOUT || '20s',
  });

  const ok = check(response, {
    'process accepted': (r) => r.status === 202 || r.status === 200,
    'process has job id': () => !!jobId,
  });

  if (ok) {
    jobsSubmitted.add(1);
  } else {
    jobsFailed.add(1);
  }
}
