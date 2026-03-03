# Go API Parity Patch List

This tracks the API migration gaps between the original Python FastAPI service and the current Go service.

## P0: Correctness blockers

- [x] Align the Go `Job` model with the Alembic-backed `jobs` table.
  - Add `retry_count`.
  - Remove `DeletedAt` soft-delete drift.
  - Stop using GORM `AutoMigrate()` as a second schema authority.

- [x] Restore backend request validation parity for `POST /api/process`.
  - Reject unknown operations.
  - Reject empty operations.
  - Validate `operation_params` shape and supported keys.
  - Reject same-format conversions.
  - Validate webhook URL as absolute `http(s)`.

- [x] Stop returning `202 Accepted` when RabbitMQ enqueue fails.
  - Treat router-task publish failure as request failure.
  - Treat metadata-task publish failure as request failure.
  - Remove fire-and-forget idempotency writes.

- [x] Restore request/job metadata propagation into Celery tasks.
  - Ensure every request has an `X-Request-ID`.
  - Pass `request_id` and enqueue time from Go into the Python router/metadata tasks.
  - Preserve queue-wait and correlation logging on the worker side.

- [x] Fix archive bundle lookup parity.
  - Go must use `archives/{job_id}/bundle.zip`.

## P1: Operational parity

- [x] Restore `/api/livez` and `/api/readyz`.
- [x] Make `/api/health` match the Python contract.
  - Include `database`, `redis`, `rabbitmq`, and `s3`.
  - Return `healthy` / `unhealthy`.
  - Return `503` on dependency failure.

- [x] Restore config defaults that changed during the rewrite.
  - Default max upload size must remain `10 MB`, not `50 MB`.

## P2: Still missing after this first pass

- [ ] `/metrics` parity with the Python API.
- [ ] Public API docs parity (`/docs` / OpenAPI surface).
- [ ] Dedicated Go tests for the migrated behavior.

## First implementation slice

The initial patch should complete:

1. Schema/model parity.
2. Validation parity.
3. Synchronous enqueue failure handling.
4. Request ID and enqueue-time propagation.
5. Archive path parity.
6. Health endpoint parity.

Metrics/docs can follow after the API contract is trustworthy again.
