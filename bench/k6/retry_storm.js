import { check } from 'k6';
import { Counter } from 'k6/metrics';

import { BASE_URL } from './lib/config.js';
import { submitJob } from './lib/jobs.js';

const jobsSubmitted = new Counter('jobs_submitted_total');
const clientRetries = new Counter('client_retries_total');
const duplicateProcessingSignals = new Counter('duplicate_processing_signals_total');
const failedAfterRetries = new Counter('failed_after_retries_total');

const seenByKey = new Map();

export const options = {
  scenarios: {
    retry_storm: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 200),
      duration: __ENV.DURATION || '3m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.20'],
  },
};

function shouldRetry(res) {
  if (!res) {
    return true;
  }
  if (res.error) {
    return true;
  }
  return res.status >= 500 || res.status === 429;
}

export default function () {
  const logicalJobId = Math.floor(__ITER / 3);
  const idempotencyKey = `storm-${__VU}-${logicalJobId}`;

  let attempt = 0;
  let finalResult = null;
  const maxAttempts = Number(__ENV.MAX_CLIENT_ATTEMPTS || 3);
  const timeout = __ENV.REQUEST_TIMEOUT || '2s';

  while (attempt < maxAttempts) {
    finalResult = submitJob({
      baseUrl: BASE_URL,
      operations: ['webp'],
      operationParams: { webp: { quality: 70 } },
      idempotencyKey,
      timeout,
    });

    if (!shouldRetry(finalResult.response)) {
      break;
    }
    clientRetries.add(1);
    attempt += 1;
  }

  const response = finalResult ? finalResult.response : null;
  const jobId = finalResult ? finalResult.jobId : null;

  const accepted = check(response, {
    'final response accepted or idempotent': (r) => !!r && (r.status === 200 || r.status === 202),
  });

  if (!accepted || !jobId) {
    failedAfterRetries.add(1);
    return;
  }

  jobsSubmitted.add(1);

  const priorJobId = seenByKey.get(idempotencyKey);
  if (priorJobId && priorJobId !== jobId) {
    duplicateProcessingSignals.add(1);
  } else if (!priorJobId) {
    seenByKey.set(idempotencyKey, jobId);
  }
}
