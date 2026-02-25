export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';
export const POLL_COMPLETION = (__ENV.POLL_COMPLETION || 'false').toLowerCase() === 'true';
export const POLL_MAX_SECONDS = Number(__ENV.POLL_MAX_SECONDS || 120);
export const POLL_INTERVAL_SECONDS = Number(__ENV.POLL_INTERVAL_SECONDS || 1);
