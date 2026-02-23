# PixTools

PixTools is an asynchronous image-processing service built with FastAPI, Celery, PostgreSQL, Redis, RabbitMQ, and S3-compatible object storage.

It accepts uploads, executes processing tasks in the background, and exposes downloadable results through presigned URLs and a web UI.

## Core Capabilities

- Async job pipeline with Celery canvas (`group` + `chord`) and job finalization.
- Format conversion: `jpg`, `png`, `webp`, `avif`.
- ML denoising (`denoise`) via PyTorch DnCNN.
- EXIF metadata extraction as a first-class operation (`metadata`).
- Optional per-operation params:
  - `quality` for `jpg` and `webp`
  - `resize` for `jpg`, `png`, `webp`, `avif`, `denoise`
- ZIP bundling of completed artifacts.
- Optional outbound webhook on completion.
- Idempotency key support for safe retries.
- 24-hour retention model for job/result access.

## High-Level Architecture

`Client/UI -> FastAPI -> RabbitMQ -> Celery workers -> S3 + PostgreSQL`

Runtime services in local Docker:

- `api`: FastAPI app (`app.main`)
- `worker-standard`: conversion, finalize, archive, metadata tasks (`default_queue`)
- `worker-ml`: denoising task (`ml_inference_queue`, solo pool)
- `postgres`: job persistence
- `redis`: idempotency + Celery result backend
- `rabbitmq`: broker
- `localstack`: local S3-compatible storage
- `migrate`: one-shot Alembic migration runner

## Repository Layout

```text
app/
  routers/        # API endpoints
  tasks/          # Celery tasks (image ops, metadata, archive, finalize, ML)
  services/       # S3, DAG builder, idempotency, webhook delivery
  static/         # Frontend UI (vanilla JS)
  ml/             # DnCNN network definition
alembic/          # Database migrations
models/           # Model weights
tests/            # API and task tests
```

## Quick Start (Docker)

### 1. Configure environment

```bash
cp .env.example .env
```

### 2. Build and start

```bash
docker compose up -d --build
```

`migrate` runs `alembic upgrade head` before the API and workers start.

### 3. Verify services

```bash
docker compose ps
docker compose logs -f migrate
```

### 4. Open interfaces

- App UI: http://localhost:8000
- OpenAPI docs: http://localhost:8000/docs
- RabbitMQ management: http://localhost:15672

### 5. Re-run migrations manually (if needed)

```bash
docker compose run --rm migrate
```

## API Reference

### `POST /api/process`

Queues one or more operations for an uploaded image.

- Content type: `multipart/form-data`
- Required fields:
  - `file`
  - `operations` JSON array (for example: `["webp","metadata"]`)
- Optional fields:
  - `operation_params` JSON object keyed by operation
  - `idempotency_key`
  - `webhook_url`

Example with quality + resize + webhook:

```bash
curl -X POST "http://localhost:8000/api/process" \
  -F "file=@test_image.png" \
  -F "operations=[\"webp\",\"denoise\",\"metadata\"]" \
  -F "operation_params={\"webp\":{\"quality\":80},\"denoise\":{\"resize\":{\"width\":1280}}}" \
  -F "webhook_url=https://webhook.site/<your-id>" \
  -F "idempotency_key=demo-001"
```

### `GET /api/jobs/{job_id}`

Returns current job state:

- `status`
- `result_urls` (operation -> presigned URL)
- `archive_url` (ZIP, when ready)
- `metadata` (EXIF fields, if available)
- `error_message`
- `created_at`

Example:

```bash
curl "http://localhost:8000/api/jobs/<job_id>"
```

### `GET /api/health`

Deep dependency check for database, Redis, and S3.

## Operations

- `jpg`
- `png`
- `webp`
- `avif`
- `denoise`
- `metadata`

Behavior notes:

- Same-format conversion is rejected.
- Denoise outputs PNG.
- Metadata can run alone or alongside processing tasks.
- ZIP download is generated asynchronously after processing completion.

## Frontend Behavior

- Drag/drop upload with preview and operation picker.
- Quality slider appears only for `jpg`/`webp`.
- Resize fields appear only for resize-capable operations.
- Metadata rendered in a dedicated panel.
- Completed downloadable jobs are persisted locally for up to 24 hours.
- `Process Another` cancels active poll context to avoid stale result resurfacing.

## Webhook Testing

Use a request-capture endpoint (for example webhook.site):

1. Create a temporary URL at https://webhook.site
2. Submit a job with `webhook_url=<that-url>`
3. Confirm payload receipt:

```json
{
  "job_id": "<uuid>",
  "status": "COMPLETED",
  "result_urls": {
    "webp": "https://..."
  }
}
```

For metadata-only jobs, `result_urls` is empty and metadata is available from `GET /api/jobs/{job_id}`.

## Configuration

Key environment variables:

- `DATABASE_URL`
- `REDIS_URL`
- `RABBITMQ_URL`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_S3_BUCKET`
- `AWS_ENDPOINT_URL` (set for LocalStack, unset for AWS)
- `MAX_UPLOAD_BYTES`
- `MAX_IMAGE_WIDTH`
- `MAX_IMAGE_HEIGHT`
- `PRESIGNED_URL_EXPIRY_SECONDS`
- `JOB_RETENTION_HOURS`
- `S3_RETENTION_DAYS`
- `IDEMPOTENCY_TTL_SECONDS`
- `WEBHOOK_CB_FAIL_THRESHOLD`
- `WEBHOOK_CB_RESET_TIMEOUT`

See `.env.example` for baseline values.

## AWS Deployment Notes

For AWS deployment:

- Use RDS Postgres for `DATABASE_URL`.
- Use ElastiCache Redis for `REDIS_URL`.
- Use Amazon MQ (RabbitMQ) or managed RabbitMQ-compatible endpoint for `RABBITMQ_URL`.
- Use S3 bucket for `AWS_S3_BUCKET`.
- Leave `AWS_ENDPOINT_URL` empty.
- Ensure IAM credentials permit S3 read/write, lifecycle config, and presigned URL flow.

## Development and Testing

Install dependencies:

```bash
pip install -r requirements-dev.txt
```

Run API locally:

```bash
uvicorn app.main:app --reload
```

Run workers:

```bash
celery -A app.tasks.celery_app worker -Q default_queue --concurrency=5 --loglevel=info
celery -A app.tasks.celery_app worker -Q ml_inference_queue --pool=solo --without-gossip --without-mingle --loglevel=info
```

Run tests:

```bash
pytest -v --cov=app tests/
```

Optional static checks:

```bash
ruff check app tests
mypy app
```

## Troubleshooting

Common local reset flow when schema/state is out of sync:

```bash
docker compose down -v
docker compose up -d --build
docker compose logs -f migrate
```

If migrations succeed but app behavior is stale, restart API/workers and hard refresh the browser.

## License

Internal project. All rights reserved.
