# Pre-Deploy Blockers

This is the final pre-live review log for the Go API migration.

## Blockers fixed in this pass

- [x] `gocelery` hardcoded AMQP publishes to the `celery` queue instead of the worker queues we actually run.
- [x] Job creation published to RabbitMQ before the database transaction was committed.
- [x] Idempotency checks failed open when Redis read failed.
- [x] API key middleware existed but was never wired to the `/api` routes.

## Remaining intentional design debt

- [ ] No transactional outbox exists yet.
  - Current behavior after this patch: the job row commits first, then tasks publish.
  - If publish fails, the job is marked `FAILED` with an enqueue error.
  - This is acceptable for the demo, but an outbox is the production-grade next step.

- [ ] Frontend API-key protection is only a light gate.
  - The frontend is public and static, so any client that can load the page can still reproduce its requests.
  - The API key now works as a deployment guard and wiring check, not as strong security.

- [ ] No Go integration tests exist yet for the RabbitMQ publish path.

## Deploy expectation after this pass

1. `POST /api/process` validates like the Python API.
2. A committed job row exists before any task is published.
3. Router and metadata tasks publish to `default_queue`, which the deployed workers actually consume.
4. `/api/process` and `/api/jobs/:id` honor `X-API-Key` when configured.
5. If enqueue fails, the API returns failure and the job row is marked failed instead of silently stalling.
