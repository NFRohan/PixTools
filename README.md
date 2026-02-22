# PixTools

PixTools is an asynchronous image-processing platform built on FastAPI + Celery.
It accepts uploads, dispatches operations as background jobs, stores artifacts in S3-compatible storage, and exposes job status/results through a simple API and a built-in web UI.

## What It Does

- Processes uploaded images asynchronously with a queued worker model.
- Supports format conversion to `jpg`, `png`, `webp`, and `avif`.
- Supports ML denoising (`denoise`) using a PyTorch DnCNN model.
- Executes requested operations in parallel via Celery canvas (`group/chord`) and finalizes results in one callback.
- Persists jobs in PostgreSQL and publishes result download links as presigned URLs.
- Uses Redis-backed idempotency keys to prevent duplicate job creation.
- Applies S3 lifecycle retention rules to clean up raw and processed objects.
- Includes a deep health check endpoint for database, Redis, and S3 connectivity.
- Includes a browser UI with drag/drop upload, polling, and local job history persistence.

## Architecture

`FastAPI API` -> `RabbitMQ broker` -> `Celery workers` -> `S3 storage` -> `PostgreSQL job state`

Key runtime components:

- `api`: FastAPI application (`app.main`).
- `worker-standard`: conversion/finalization tasks (`default_queue`).
- `worker-ml`: ML denoising tasks (`ml_inference_queue`, solo pool).
- `postgres`: job metadata and status.
- `redis`: idempotency and Celery result backend.
- `rabbitmq`: task broker and routing.
- `localstack`: local S3-compatible endpoint for development.

## Tech Stack

- Python 3.12
- FastAPI
- Celery + RabbitMQ + Redis
- SQLAlchemy + Alembic
- PostgreSQL
- S3 (AWS or LocalStack)
- PyTorch + NumPy + Pillow
- Vanilla JS frontend

## Repository Structure

```text
app/
  routers/        # API endpoints (/api/process, /api/jobs/{id}, /api/health)
  tasks/          # Celery app, image ops, ML ops, finalize flow
  services/       # S3, idempotency, DAG builder, webhook delivery
  static/         # Browser UI (index.html, app.js, style.css)
  ml/             # DnCNN model definition
alembic/          # DB migrations
models/           # Trained model weights (dncnn_color_blind.pth)
tests/            # API, task, and service tests
```

## Getting Started (Docker)

### Prerequisites

- Docker + Docker Compose

### 1. Configure Environment

```bash
cp .env.example .env
```

The compose file already injects local defaults for PostgreSQL, Redis, RabbitMQ, and LocalStack.

### 2. Start Services

```bash
docker compose up -d --build
```

### 3. Run Migrations

```bash
docker compose exec api alembic upgrade head
```

### 4. Open the App

- UI: http://localhost:8000
- OpenAPI: http://localhost:8000/docs
- RabbitMQ UI: http://localhost:15672

## API Quick Reference

### `POST /api/process`

Uploads an image and queues one or more operations.

- Content type: `multipart/form-data`
- Required form fields:
  - `file` (JPEG/PNG/WEBP/AVIF, max 10 MB by default)
  - `operations` (JSON array, example `["webp","denoise"]`)
- Optional form field:
  - `idempotency_key` (replay-safe submission key)

Example:

```bash
curl -X POST "http://localhost:8000/api/process" \
  -F "file=@test_image.png" \
  -F "operations=[\"webp\",\"denoise\"]" \
  -F "idempotency_key=demo-123"
```

### `GET /api/jobs/{job_id}`

Returns job state and generated download URLs when available.

Example:

```bash
curl "http://localhost:8000/api/jobs/<job_id>"
```

### `GET /api/health`

Deep dependency health check for DB, Redis, and S3.

## Supported Operations

- `jpg`
- `png`
- `webp`
- `avif`
- `denoise`

Notes:

- Conversion to the same source format is rejected.
- Denoised output is uploaded as PNG.
- Multiple operations in a single request run in parallel.

## Configuration

Settings are loaded from environment variables via `app/config.py`.
Common variables:

- `DATABASE_URL`
- `REDIS_URL`
- `RABBITMQ_URL`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_S3_BUCKET`
- `AWS_ENDPOINT_URL` (set to LocalStack in local compose)
- `MAX_UPLOAD_BYTES`
- `PRESIGNED_URL_EXPIRY_SECONDS`
- `S3_RETENTION_DAYS`

Use `.env.example` as the baseline.

## Development (Without Docker)

Install dependencies:

```bash
pip install -r requirements.txt
```

Run API:

```bash
uvicorn app.main:app --reload
```

Run workers:

```bash
celery -A app.tasks.celery_app worker -Q default_queue --concurrency=5 --loglevel=info
celery -A app.tasks.celery_app worker -Q ml_inference_queue --pool=solo --without-gossip --without-mingle --loglevel=info
```

## Testing and Quality

Run tests:

```bash
pytest -v --cov=app tests/
```

Static analysis:

```bash
ruff check app tests
mypy app
```

## Operational Notes

- Logging is structured JSON and includes request/task correlation IDs where available.
- Celery queues are configured with a dead-letter exchange (`dlx`) for failed messages.
- S3 lifecycle rules are applied at startup for both `raw/` and `processed/` prefixes.
- A webhook circuit breaker is implemented (`pybreaker`) for outbound webhook delivery.
- API key validation helper exists in `app/dependencies.py`, but is not currently attached to routes.

## License

Internal project. All rights reserved.
