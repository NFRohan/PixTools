import { check } from 'k6';
import { Counter } from 'k6/metrics';

import { BASE_URL } from './lib/config.js';
import { submitJob } from './lib/jobs.js';

const lightSubmitted = new Counter('light_jobs_submitted_total');
const heavySubmitted = new Counter('heavy_jobs_submitted_total');
const mixFailures = new Counter('mix_failures_total');

export const options = {
  scenarios: {
    heavy: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.HEAVY_RPS || 8),
      timeUnit: '1s',
      duration: __ENV.DURATION || '4m',
      preAllocatedVUs: Number(__ENV.HEAVY_PREALLOCATED_VUS || 60),
      maxVUs: Number(__ENV.HEAVY_MAX_VUS || 200),
      tags: { workload: 'heavy' },
      exec: 'runHeavy',
    },
    light: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.LIGHT_RPS || 2),
      timeUnit: '1s',
      duration: __ENV.DURATION || '4m',
      preAllocatedVUs: Number(__ENV.LIGHT_PREALLOCATED_VUS || 20),
      maxVUs: Number(__ENV.LIGHT_MAX_VUS || 100),
      tags: { workload: 'light' },
      exec: 'runLight',
    },
  },
  thresholds: {
    'http_req_duration{workload:light}': ['p(95)<1500'],
    'http_req_failed{workload:light}': ['rate<0.10'],
  },
};

export function runHeavy() {
  const idempotencyKey = `heavy-${__VU}-${__ITER}-${Date.now()}`;
  const { response, jobId } = submitJob({
    baseUrl: BASE_URL,
    operations: ['denoise'],
    idempotencyKey,
    timeout: __ENV.REQUEST_TIMEOUT || '30s',
  });
  const ok = check(response, {
    'heavy accepted': (r) => r.status === 202 || r.status === 200,
    'heavy has job id': () => !!jobId,
  });
  if (ok) {
    heavySubmitted.add(1);
  } else {
    mixFailures.add(1);
  }
}

export function runLight() {
  const idempotencyKey = `light-${__VU}-${__ITER}-${Date.now()}`;
  const { response, jobId } = submitJob({
    baseUrl: BASE_URL,
    operations: ['webp'],
    operationParams: { webp: { quality: 80 } },
    idempotencyKey,
    timeout: __ENV.REQUEST_TIMEOUT || '20s',
  });
  const ok = check(response, {
    'light accepted': (r) => r.status === 202 || r.status === 200,
    'light has job id': () => !!jobId,
  });
  if (ok) {
    lightSubmitted.add(1);
  } else {
    mixFailures.add(1);
  }
}
