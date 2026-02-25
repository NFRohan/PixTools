import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

import { BASE_URL, POLL_COMPLETION } from './lib/config.js';
import { pollJobUntilTerminal, submitJob } from './lib/jobs.js';

const jobsSubmitted = new Counter('jobs_submitted_total');
const jobsCompleted = new Counter('jobs_completed_total');
const jobsFailed = new Counter('jobs_failed_total');
const jobsTimedOut = new Counter('jobs_poll_timeout_total');
const clientJobEndToEnd = new Trend('client_job_end_to_end_seconds');

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 50),
      duration: __ENV.DURATION || '5m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<1200'],
  },
};

export default function () {
  const idempotencyKey = `baseline-${__VU}-${__ITER}-${Date.now()}`;
  const started = Date.now();

  const { response, jobId } = submitJob({
    baseUrl: BASE_URL,
    operations: ['webp'],
    operationParams: { webp: { quality: 80 } },
    idempotencyKey,
  });

  const accepted = check(response, {
    'process accepted': (r) => r.status === 202 || r.status === 200,
    'process has job id': () => !!jobId,
  });

  if (!accepted) {
    jobsFailed.add(1);
    return;
  }

  jobsSubmitted.add(1);

  if (!POLL_COMPLETION) {
    return;
  }

  const polled = pollJobUntilTerminal(BASE_URL, jobId);
  const elapsedSeconds = (Date.now() - started) / 1000.0;
  clientJobEndToEnd.add(elapsedSeconds);

  if (polled.status === 'COMPLETED' || polled.status === 'COMPLETED_WEBHOOK_FAILED') {
    jobsCompleted.add(1);
    return;
  }
  if (polled.status === 'TIMEOUT') {
    jobsTimedOut.add(1);
    return;
  }
  jobsFailed.add(1);
}
