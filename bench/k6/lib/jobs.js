import http from 'k6/http';
import { sleep } from 'k6';

import { API_KEY, POLL_INTERVAL_SECONDS, POLL_MAX_SECONDS } from './config.js';

const imageBinary = open('../../../test_image.png', 'b');

export function submitJob({
  baseUrl,
  operations = ['webp'],
  idempotencyKey,
  operationParams = null,
  timeout = '30s',
}) {
  const payload = {
    file: http.file(imageBinary, 'test_image.png', 'image/png'),
    operations: JSON.stringify(operations),
  };
  if (operationParams !== null) {
    payload.operation_params = JSON.stringify(operationParams);
  }

  const headers = {
    'Idempotency-Key': idempotencyKey,
  };
  if (API_KEY) {
    headers['X-API-Key'] = API_KEY;
  }

  const res = http.post(`${baseUrl}/api/process`, payload, {
    headers,
    timeout,
    tags: { endpoint: 'process' },
  });

  let body = null;
  try {
    body = res.json();
  } catch (_err) {
    body = null;
  }

  return {
    response: res,
    jobId: body && body.job_id ? body.job_id : null,
    body,
  };
}

export function pollJobUntilTerminal(baseUrl, jobId, timeoutSeconds = POLL_MAX_SECONDS) {
  const maxIters = Math.ceil(timeoutSeconds / POLL_INTERVAL_SECONDS);
  for (let i = 0; i < maxIters; i += 1) {
    const pollHeaders = API_KEY ? { 'X-API-Key': API_KEY } : {};
    const res = http.get(`${baseUrl}/api/jobs/${jobId}`, {
      headers: pollHeaders,
      tags: { endpoint: 'poll_job' },
    });
    let body = null;
    try {
      body = res.json();
    } catch (_err) {
      body = null;
    }
    const status = body && body.status ? body.status : '';
    if (status === 'COMPLETED' || status === 'COMPLETED_WEBHOOK_FAILED' || status === 'FAILED') {
      return { response: res, status, body };
    }
    sleep(POLL_INTERVAL_SECONDS);
  }
  return { response: null, status: 'TIMEOUT', body: null };
}
