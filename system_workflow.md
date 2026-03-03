# PixTools System Workflow

This document describes the current system as it actually works in code today.

It is intentionally detailed. It covers:

- every public HTTP route
- every internal service-to-service call in the request path
- every queue and task involved in job execution
- every database field that matters to runtime behavior
- every S3 key pattern used by the system
- every meaningful state transition and failure branch

This is the source-of-truth workflow for the current split architecture:

- Go serves the frontend and HTTP API
- Python Celery workers execute the asynchronous image-processing pipeline
- Postgres is the system-of-record
- RabbitMQ is the task transport
- Redis is the idempotency store
- S3 stores raw inputs, processed outputs, and ZIP archives

## 1. Runtime split

PixTools is no longer a single Python HTTP service.

The current runtime split is:

- `go-api/`
  - active HTTP server
  - serves `/`, `/static/*`, `/app-config.js`, `/api/*`
  - validates requests
  - uploads the raw file to S3
  - writes the initial `jobs` row to Postgres
  - publishes Celery-compatible task envelopes directly to RabbitMQ
- `app/`
  - active asynchronous worker runtime
  - defines Celery app, queues, routing, tasks, finalization, archive bundling, maintenance, metrics, and webhook delivery
- `Postgres`
  - stores the durable `jobs` table
- `RabbitMQ`
  - stores and routes task messages between API and workers
- `Redis`
  - stores idempotency keys
- `S3`
  - stores raw uploads, processed outputs, and ZIP bundles

Important clarification:

- `app/main.py` and the FastAPI routers still exist in the repository.
- They are no longer the primary deployed API path.
- The current live request path starts in `go-api/cmd/api/main.go`.

## 2. Boot sequence

### 2.1 Go API startup

The Go API process starts in `go-api/cmd/api/main.go`.

Startup order:

1. Load environment config from `go-api/internal/config/config.go`.
2. Open a GORM Postgres connection using `DATABASE_URL`.
3. Open a Redis client using `REDIS_URL`.
4. Open an AMQP connection to RabbitMQ using `RABBITMQ_URL`.
5. Create an S3 client using:
   - real AWS IAM/ambient credentials when `S3_ENDPOINT_URL` is empty
   - explicit static credentials when `S3_ENDPOINT_URL` is set for LocalStack/MinIO
6. Optionally initialize OpenTelemetry in `go-api/internal/telemetry/tracer.go`.
7. Build the Gin server and register middleware/routes in `go-api/internal/handlers/server.go`.
8. Listen on port `8000`.

The Go API does not run schema migration at startup.

That is deliberate. The Alembic migration history is the schema authority.

### 2.2 Python worker startup

The Python worker runtime is driven by `app/tasks/celery_app.py`.

Startup behavior:

1. Instantiate the Celery app with:
   - broker = `settings.rabbitmq_url`
   - result backend = `settings.redis_url`
2. Register queue definitions:
   - `default_queue`
   - `ml_inference_queue`
   - `dead_letter`
3. Register task routing:
   - `app.tasks.image_ops.*` -> `default_queue`
   - `app.tasks.metadata.*` -> `default_queue`
   - `app.tasks.archive.*` -> `default_queue`
   - `app.tasks.finalize.*` -> `default_queue`
   - `app.tasks.maintenance.*` -> `default_queue`
   - `app.tasks.ml_ops.denoise` -> `ml_inference_queue` when `ml_queue_isolation_enabled=true`, otherwise `default_queue`
4. Enable Celery beat schedule for hourly job pruning.
5. Enable reliability settings:
   - `task_acks_late = True`
   - `task_reject_on_worker_lost = True`
   - `worker_prefetch_multiplier = 1`
   - `broker_connection_retry_on_startup = True`
6. Import task modules so Celery registers them.
7. Install logging/metrics/observability hooks.

### 2.3 ML worker startup

The ML worker has one extra startup step in `app/tasks/ml_ops.py`.

On Celery `worker_init`:

1. Set PyTorch CPU threads to `4`.
2. Instantiate `DnCNN()`.
3. Load `models/dncnn_color_blind.pth`.
4. Switch the model to `eval()` mode.

The DnCNN model is loaded once per worker process, not per task.

## 3. Configuration inputs

### 3.1 Go API configuration

Loaded in `go-api/internal/config/config.go`.

Important runtime settings:

- `DATABASE_URL`
- `REDIS_URL`
- `RABBITMQ_URL`
- `AWS_REGION`
- `AWS_S3_BUCKET` or `S3_BUCKET_NAME`
- `S3_ENDPOINT_URL`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `API_KEY`
- `MAX_UPLOAD_BYTES`
- `ACCEPTED_MIME_TYPES`
- `OBSERVABILITY_ENABLED`
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_SERVICE_NAME_API`

Defaults that matter:

- region default = `us-east-1`
- upload limit default = `10 MB`
- accepted MIME types default =
  - `image/jpeg`
  - `image/png`
  - `image/webp`
  - `image/avif`

### 3.2 Python worker configuration

Loaded in `app/config.py`.

Important worker-side settings:

- `database_url`
- `redis_url`
- `rabbitmq_url`
- `aws_region`
- `aws_s3_bucket`
- `aws_endpoint_url`
- `aws_access_key_id`
- `aws_secret_access_key`
- `idempotency_ttl_seconds`
- `webhook_cb_fail_threshold`
- `webhook_cb_reset_timeout`
- `max_image_width`
- `max_image_height`
- `task_timeout_seconds`
- `presigned_url_expiry_seconds`
- `job_retention_hours`
- `s3_retention_days`
- `ml_queue_isolation_enabled`
- `observability_enabled`
- `metrics_enabled`

## 4. Data model

The main persistent entity is the `jobs` table.

Current runtime fields used by both Go and Python:

- `id`
  - UUID primary key
- `status`
  - one of:
    - `PENDING`
    - `PROCESSING`
    - `COMPLETED`
    - `FAILED`
    - `COMPLETED_WEBHOOK_FAILED`
- `operations`
  - JSON array of requested operations as strings
- `s3_raw_key`
  - S3 key of the uploaded source image
- `original_filename`
  - browser-provided original file name
- `webhook_url`
  - optional callback target
- `result_keys`
  - JSON map of `operation -> S3 key`
- `result_urls`
  - JSON map of `operation -> presigned download URL`
- `exif_metadata`
  - JSON object containing extracted EXIF fields
- `error_message`
  - terminal failure message
- `retry_count`
  - integer, default `0`
- `created_at`
- `updated_at`

Important current behavior:

- The code defines a `PROCESSING` status.
- The current runtime does not actually set `PROCESSING`.
- Jobs stay `PENDING` until they become:
  - `COMPLETED`
  - `FAILED`
  - `COMPLETED_WEBHOOK_FAILED`

## 5. Object naming and key formats

### 5.1 Redis

Idempotency keys are stored as:

- `idempotency:{Idempotency-Key}`

Value:

- the job UUID string

TTL:

- 24 hours on the Go API path

### 5.2 S3 keys

Current S3 object layouts:

- raw uploads from Go API:
  - `raw/{job_id}/{original_filename}`
- processed outputs from Python workers:
  - `processed/{job_id}/{operation}_{random8}.{ext}`
- ZIP archives:
  - `archives/{job_id}/bundle.zip`

### 5.3 RabbitMQ topology

Declared on the Python side:

- exchange `default` of type `direct`
- exchange `dlx` of type `direct`
- queue `default_queue`
- queue `ml_inference_queue`
- queue `dead_letter`

Current Go publisher behavior:

- publishes API-created tasks to `default_queue`
- declares `dlx`
- declares and binds `dead_letter`
- declares `default_queue` with:
  - `x-dead-letter-exchange = dlx`
  - `x-dead-letter-routing-key = dead_letter`

## 6. Public HTTP surface

The current public routes are served by Gin in `go-api/internal/handlers/server.go`.

### 6.1 `GET /`

Purpose:

- returns the frontend HTML page

Implementation:

- serves `go-api/static/index.html`

### 6.2 `GET /static/*`

Purpose:

- serves static frontend assets

Examples:

- `/static/style.css`
- `/static/app.js`

### 6.3 `GET /app-config.js`

Purpose:

- injects runtime config into the browser

Current contents:

- `window.__PIXTOOLS_CONFIG__ = { apiKey: "<value>" };`

Headers:

- `Content-Type: application/javascript; charset=utf-8`
- `Cache-Control: no-store`

### 6.4 `GET /api/livez`

Purpose:

- simple liveness probe

Response:

- `200 {"status":"alive"}`

No dependency checks.

### 6.5 `GET /api/readyz`

Purpose:

- readiness probe

Checks:

- Postgres
- Redis
- RabbitMQ

Response:

- `200` with `"status":"healthy"` when all are reachable
- `503` with `"status":"unhealthy"` when any dependency fails

### 6.6 `GET /api/health`

Purpose:

- deep health check

Checks:

- Postgres
- Redis
- RabbitMQ
- S3 bucket reachability

Response shape:

```json
{
  "status": "healthy",
  "dependencies": {
    "database": "ok",
    "redis": "ok",
    "rabbitmq": "ok",
    "s3": "ok"
  }
}
```

If any dependency is down:

- `status` becomes `"unhealthy"`
- HTTP status becomes `503`

### 6.7 `POST /api/process`

Purpose:

- submit a new image-processing job

Consumes:

- `multipart/form-data`

Form fields:

- `file`
  - required
- `operations`
  - required JSON array string
- `operation_params`
  - optional JSON object string
- `webhook_url`
  - optional absolute `http://` or `https://` URL

Headers:

- `Idempotency-Key`
  - optional
- `X-API-Key`
  - required when `API_KEY` is configured on the server
- `X-Request-ID`
  - optional; generated if omitted

### 6.8 `GET /api/jobs/:id`

Purpose:

- poll current job state
- fetch fresh presigned URLs after completion
- surface archive URL when ready

Headers:

- `X-API-Key` when configured

## 7. Frontend page-load flow

The frontend entrypoint is `go-api/static/index.html`.

Browser load sequence:

1. Browser requests `GET /`.
2. Server returns `index.html`.
3. Browser requests:
   - Google Fonts CSS from `fonts.googleapis.com`
   - Google Fonts assets from `fonts.gstatic.com`
   - `/static/style.css`
   - `/app-config.js`
   - `/static/app.js`
4. `go-api/static/app.js` runs on `DOMContentLoaded`.
5. `init()` executes:
   - loads saved local history from `localStorage`
   - updates advanced control visibility
   - binds the clear-history button

The frontend stores job history under:

- `localStorage["pixtools_jobs"]`

Current settings in frontend code:

- local history limit = `10`
- history retention check = `24 hours`
- upload timeout = `90 seconds`
- polling interval = `2 seconds`

## 8. Frontend interaction flow before network I/O

### 8.1 File selection

The user can provide a file by:

- clicking the drop zone
- dragging and dropping into the drop zone

Local browser validation before any request:

1. MIME type must be in:
   - `image/jpeg`
   - `image/png`
   - `image/webp`
   - `image/avif`
2. file size must be <= `10 MB`
3. the preview is generated with `FileReader`

### 8.2 Operation selection

Available frontend operations:

- `jpg`
- `png`
- `webp`
- `avif`
- `denoise`
- `metadata`

Same-format conversion is prevented in the UI:

- if the source extension is already `png`, the `png` operation is disabled
- same rule for `jpg`, `webp`, `avif`
- `denoise` and `metadata` are not disabled by source format

### 8.3 Operation parameters

The frontend builds per-operation params based on selected controls.

Supported params:

- `quality`
  - only emitted for `jpg` and `webp`
- `resize`
  - emitted for:
    - `jpg`
    - `png`
    - `webp`
    - `avif`
    - `denoise`

### 8.4 Idempotency key generation

On submit, the browser generates an idempotency key by:

1. `crypto.randomUUID()` when available
2. fallback to `crypto.getRandomValues()` UUID-style generation
3. final fallback to a timestamp + random suffix string

That key is sent in the `Idempotency-Key` header.

## 9. `POST /api/process` request lifecycle

This is the main creation path.

### 9.1 Browser request composition

When the user clicks `PROCESS`:

1. the button hides
2. the processing indicator shows
3. the UI displays `Uploading...`
4. file input and operation toggles are disabled
5. a `FormData` object is built
6. `fetchWithTimeout("/api/process", ...)` is called

Outgoing request contents:

- method: `POST`
- headers:
  - `Idempotency-Key: <generated-key>`
  - `X-API-Key: <runtime-api-key>` when present in `/app-config.js`
- body:
  - `file`
  - `operations`
  - optional `operation_params`
  - optional `webhook_url`

### 9.2 Go middleware chain

The Go API applies middleware in this order:

1. Gin default middleware
2. `requestIDMiddleware()`
3. optional OpenTelemetry Gin middleware when enabled
4. `apiKeyMiddleware()` on the `/api` route group

#### 9.2.1 Request ID middleware

Behavior:

- read `X-Request-ID`
- if absent, generate a UUID
- store it in Gin context as `request_id`
- echo it back in the response header

#### 9.2.2 API key middleware

Behavior:

- if `API_KEY` server config is empty, allow the request through
- otherwise read:
  - `X-API-Key`
  - fallback query param `api_key`
- if it does not match config:
  - return `401 {"detail":"Invalid or missing API Key"}`

### 9.3 Multipart binding

`CreateJob` in `go-api/internal/handlers/jobs.go` binds the multipart request into:

- `models.JobRequest`

Bound fields:

- `file`
- `operations`
- `Idempotency-Key`
- `operation_params`
- `webhook_url`

### 9.4 Request validation sequence

The handler validates in this order.

#### 9.4.1 File size

If `req.File.Size > MaxUploadBytes`:

- return `413`

#### 9.4.2 MIME type

The Go API reads `req.File.Header.Get("Content-Type")`.

If not one of the accepted MIME types:

- return `400`

#### 9.4.3 Operations JSON parse

`models.ParseOperations`:

1. JSON-decodes the `operations` string
2. rejects invalid JSON
3. rejects empty arrays
4. rejects unknown operations

Allowed operations:

- `jpg`
- `png`
- `webp`
- `avif`
- `denoise`
- `metadata`

Invalid operations return:

- `422`

#### 9.4.4 Operation params parse

`models.ParseOperationParams`:

1. JSON-decodes the `operation_params` string
2. ignores params for operations that were not requested
3. validates supported keys by operation
4. validates integer encoding and numeric ranges

Rules:

- `quality`
  - allowed only for `jpg` and `webp`
  - must be integer `1..100`
- `resize`
  - allowed only for `jpg`, `png`, `webp`, `avif`, `denoise`
  - must contain at least one of `width` or `height`
  - each provided dimension must be integer `> 0`

Invalid params return:

- `422`

#### 9.4.5 Webhook URL validation

`models.ValidateWebhookURL`:

- empty string is allowed
- otherwise URL must:
  - parse successfully
  - have scheme
  - have host
  - use `http` or `https`

Invalid webhook URLs return:

- `422`

#### 9.4.6 Same-format rejection

`models.ValidateSourceTargetFormats`:

1. derive source format from filename extension
2. skip `denoise`
3. skip `metadata`
4. reject when a requested conversion target matches the source format

Example:

- source `photo.png`
- requested ops `["png"]`
- return `422`

### 9.5 Idempotency read

If an `Idempotency-Key` exists:

1. the Go API calls `IdempotencyService.CheckIdempotency`
2. Redis key format is `idempotency:{key}`

Outcomes:

- cache miss -> continue
- cache hit -> return existing `job_id` with HTTP `202`
- Redis error -> return `503 {"detail":"idempotency store unavailable"}`

### 9.6 Raw file read

The Go API then:

1. opens the multipart file
2. reads it fully into memory with `io.ReadAll`

Current implication:

- the Go API does not stream the upload to S3
- the raw upload path is memory-backed per request

### 9.7 Job identity creation

The handler creates:

- `jobID = uuid.New()`
- `requestID` from Gin context
- `enqueuedAt = time.Now().UTC()`

### 9.8 S3 raw upload

The Go API calls `S3Service.UploadRaw`.

Behavior:

1. construct key = `raw/{jobID}/{originalFilename}`
2. call `PutObject`
3. return the key

If S3 upload fails:

- return `500 {"detail":"failed to upload to storage layer"}`
- no DB row is written

### 9.9 Database insert

The API writes one `jobs` row with:

- `id = jobID`
- `status = PENDING`
- `operations = requested operations`
- `s3_raw_key = uploaded raw key`
- `original_filename = uploaded name`
- `webhook_url = validated URL or empty string`
- `retry_count = 0`

If the insert fails:

- return `500 {"detail":"failed to write job to database"}`

### 9.10 Task selection split

Before publish, the Go API separates metadata from pipeline operations.

Current logic:

- `metadata` is not routed through the Python router task
- all other operations become `pipelineOps`

That creates three possible publish shapes:

- pipeline only -> router task only
- metadata only -> metadata task only
- pipeline + metadata -> router task plus metadata task

### 9.11 RabbitMQ publish

The Go API calls `CeleryService.PublishJobTasks`.

#### 9.11.1 Enqueue timestamp format

`enqueued_at` is serialized as:

- seconds since epoch
- string with microsecond precision

Example:

- `"1739990400.123456"`

#### 9.11.2 Router task kwargs

When `pipelineOps` is non-empty, the Go API publishes task `app.tasks.router.start_pipeline` with kwargs:

```json
{
  "job_id": "<job-id>",
  "s3_raw_key": "raw/<job-id>/<filename>",
  "operations": ["webp", "avif"],
  "operation_params": {
    "webp": { "quality": 80 }
  },
  "request_id": "<request-id>",
  "enqueued_at": "1739990400.123456"
}
```

#### 9.11.3 Metadata task kwargs

When metadata is requested, the Go API publishes task `app.tasks.metadata.extract_metadata` with kwargs:

```json
{
  "job_id": "<job-id>",
  "s3_raw_key": "raw/<job-id>/<filename>",
  "mark_completed": false,
  "request_id": "<request-id>",
  "enqueued_at": "1739990400.123456"
}
```

If metadata is the only requested operation:

- `mark_completed = true`

#### 9.11.4 Celery message envelope

Each AMQP message body is JSON with this shape:

```json
{
  "id": "<uuid>",
  "task": "app.tasks.router.start_pipeline",
  "args": [],
  "kwargs": { "...": "..." },
  "retries": 0,
  "eta": null,
  "expires": null
}
```

#### 9.11.5 Publish transaction

The Go API:

1. opens an AMQP channel
2. declares `dlx`
3. declares `dead_letter`
4. binds `dead_letter` to `dlx`
5. declares `default_queue` with dead-letter arguments
6. starts an AMQP transaction
7. publishes each task to exchange `""` with routing key `default_queue`
8. commits the AMQP transaction

If any publish step fails:

1. the AMQP transaction rolls back
2. the API updates the DB row:
   - `status = FAILED`
   - `error_message = "enqueue failed: ..."`
3. the API returns `500 {"detail":"failed to enqueue job"}`

### 9.12 Idempotency write

After a successful publish, if the request supplied `Idempotency-Key`:

1. the Go API writes Redis key `idempotency:{key}`
2. value = `jobID`
3. TTL = `24 hours`

If this Redis write fails:

- the API logs the error
- the request still returns `202`
- the job remains valid and enqueued

### 9.13 API success response

On success the API returns:

```json
{
  "job_id": "<job-id>",
  "status": "PENDING"
}
```

HTTP status:

- `202 Accepted`

## 10. Python worker execution path

Once the Go API publishes to `default_queue`, Celery workers begin processing.

### 10.1 Celery task lifecycle hooks

Before task-specific logic runs, `app/tasks/celery_app.py` hooks fire.

#### 10.1.1 `task_prerun`

For every task:

1. read task headers and kwargs
2. set `job_id` context variable
3. set `request_id` context variable
4. compute queue wait time from `X-Job-Enqueued-At` header or `enqueued_at` kwarg fallback
5. record queue wait histogram
6. record task start log with `task_id`, `task_name`, `job_id`, `enqueue_time`, `start_time`, `retry_count`, and `worker_id`

#### 10.1.2 `task_postrun`

After task completion:

1. compute processing duration
2. record worker task histogram
3. log task finish
4. clear request/job logging context

#### 10.1.3 `task_retry`

On retry:

- increment retry counter
- log retry reason and worker identity

#### 10.1.4 `task_failure`

On terminal failure:

- increment task failure counter
- log task ID, name, job ID, and traceback

## 11. Router task behavior

The router task lives in `app/tasks/router.py`.

Task name:

- `app.tasks.router.start_pipeline`

Purpose:

- bridge the Go API and the Python Celery Canvas DAG builder

Inputs:

- `job_id`
- `s3_raw_key`
- `operations`
- `operation_params`
- `request_id`
- `enqueued_at`

Behavior:

1. log that Go requested a pipeline start
2. parse `enqueued_at` to float if possible
3. call `build_dag(...)` in `app/services/dag_builder.py`
4. log successful DAG dispatch

The router task does not itself perform image processing.

## 12. DAG builder behavior

Current operation map:

- `jpg` -> `app.tasks.image_ops.convert_jpg`
- `png` -> `app.tasks.image_ops.convert_png`
- `webp` -> `app.tasks.image_ops.convert_webp`
- `avif` -> `app.tasks.image_ops.convert_avif`
- `denoise` -> `app.tasks.ml_ops.denoise`

Behavior:

1. build common headers:
   - `X-Request-ID`
   - `X-Job-ID`
   - `X-Job-Enqueued-At`
2. for each requested operation:
   - resolve task name
   - attach kwargs:
     - `job_id`
     - `s3_raw_key`
     - `params`
3. create a finalization signature:
   - `app.tasks.finalize.finalize_job(job_id=<job-id>)`
4. dispatch:
   - `chord(group(task_signatures))(finalize_sig)`

Current workflow shape:

- all non-metadata operations run in parallel
- `finalize_job` runs after all of them finish

If no valid operations remain:

- the DAG builder logs an error and returns without dispatching a chord

## 13. Standard image operation tasks

Tasks:

- `app.tasks.image_ops.convert_jpg`
- `app.tasks.image_ops.convert_png`
- `app.tasks.image_ops.convert_webp`
- `app.tasks.image_ops.convert_avif`

Shared logic:

1. download raw image from S3 using `app.services.s3.download_raw`
2. apply EXIF orientation correction with `ImageOps.exif_transpose`
3. optionally resize
4. optionally apply `quality`
5. encode target format
6. upload result with `app.services.s3.upload_processed`
7. return the new S3 key

Resize parsing:

- read `params["resize"]`
- accept `width`, `height`, or both
- reject non-positive values
- clamp dimensions to max width `1920` and max height `1080`
- preserve aspect ratio when only one side is provided

Quality handling:

- validated as integer `1..100`
- applied only to JPEG and WebP

Retry behavior:

- each conversion task is `bind=True`
- each has `max_retries=3`

## 14. ML denoise task

The denoise task lives in `app/tasks/ml_ops.py`.

Task name:

- `app.tasks.ml_ops.denoise`

Queue:

- `ml_inference_queue` when ML isolation is enabled
- otherwise `default_queue`

Behavior:

1. ensure global model is loaded
2. download raw image from S3
3. apply EXIF orientation correction
4. convert image to RGB
5. optionally resize using the same width/height semantics
6. convert image to numpy array in `[0, 1]`
7. transpose HWC -> CHW
8. add batch dimension
9. run DnCNN inference under `torch.inference_mode()`
10. clamp output back to `[0, 1]`
11. convert tensor back to `uint8` image
12. upload as PNG using operation name `denoise`
13. return the processed S3 key

Retry behavior:

- `max_retries=3`

## 15. Metadata extraction task

The metadata task lives in `app/tasks/metadata.py`.

Task name:

- `app.tasks.metadata.extract_metadata`

This task has two modes.

### 15.1 Metadata-only mode

Triggered when the original request contained only `["metadata"]`.

Input:

- `mark_completed = true`

Behavior:

1. download raw image from S3
2. read EXIF data via Pillow
3. normalize selected metadata fields
4. open a synchronous SQLAlchemy session
5. update the job row:
   - `exif_metadata = extracted metadata`
   - `status = COMPLETED`
   - ensure `result_urls` exists
   - ensure `result_keys` exists
6. commit
7. if `webhook_url` exists:
   - call `notify_job_update(...)`
   - if delivery fails, reopen DB session and set `status = COMPLETED_WEBHOOK_FAILED`
8. emit end-to-end duration metric
9. increment final job status metric

### 15.2 Metadata-plus-pipeline mode

Triggered when request contained metadata and at least one non-metadata operation.

Input:

- `mark_completed = false`

Behavior:

1. extract EXIF metadata
2. update `job.exif_metadata`
3. commit
4. do not finalize the job
5. do not fire the completion webhook

Final job completion is still owned by `finalize_job` in this mode.

### 15.3 Extracted metadata fields

Current metadata extraction attempts to populate:

- `camera_make`
- `camera_model`
- `lens_model`
- `captured_at`
- `exposure_time`
- `aperture`
- `iso`
- `gps`
  - `latitude`
  - `longitude`

Retry behavior:

- `max_retries=2`

## 16. Finalization behavior

The final chord callback lives in `app/tasks/finalize.py`.

Task name:

- `app.tasks.finalize.finalize_job`

Inputs:

- `results`
  - list of S3 keys returned by the group tasks
- `job_id`

Behavior:

1. read Celery headers
2. parse `X-Job-Enqueued-At` for end-to-end timing
3. create a synchronous SQLAlchemy session
4. load the `jobs` row
5. derive the base original filename without extension
6. for each result S3 key:
   - derive `op_name` from the filename prefix
   - derive extension from the S3 key suffix
   - build a user-friendly download filename `pixtools_{op}_{originalBase}.{ext}`
   - generate a presigned download URL
   - populate `result_urls[op_name]` and `result_keys[op_name]`
7. set `job.status = COMPLETED`
8. write `job.result_urls` and `job.result_keys`
9. commit

### 16.1 Archive dispatch

If the job exists and there are any `result_keys`:

1. build a Celery signature for `app.tasks.archive.bundle_results`
2. attach kwargs:
   - `job_id`
   - `result_keys`
   - `original_filename`
3. attach header `X-Request-ID`
4. dispatch asynchronously

Archive generation is intentionally decoupled from primary job completion.

### 16.2 Webhook delivery

After the DB update:

1. if `webhook_url` exists, call `notify_job_update(...)`
2. if delivery fails, reopen DB session and set `status = COMPLETED_WEBHOOK_FAILED`

### 16.3 Metrics and logs

Finalization records:

- end-to-end duration histogram
- final job status counter
- job finalize start log
- job finalize completion log

## 17. Archive bundling behavior

The archive task lives in `app/tasks/archive.py`.

Task name:

- `app.tasks.archive.bundle_results`

Inputs:

- `job_id`
- `result_keys`
- `original_filename`

Behavior:

1. require at least one `result_key`
2. derive a base filename from `original_filename`
3. create an in-memory ZIP buffer
4. for each `operation -> s3_key`:
   - download raw bytes from S3
   - derive the file extension from the S3 key
   - write a member `pixtools_{operation}_{base}.{ext}`
5. upload the ZIP bytes to `archives/{job_id}/bundle.zip`
6. return the archive key

Retry behavior:

- `max_retries=2`

Important:

- archive creation does not change the job row
- `GET /api/jobs/:id` discovers the archive lazily by checking S3

## 18. `GET /api/jobs/:id` lifecycle

This endpoint is the browser polling path.

### 18.1 Input validation

1. parse `:id` as UUID
2. on parse failure, return `422 {"detail":"invalid job ID format"}`

### 18.2 Job lookup

1. query Postgres by `id`
2. on miss, return `404 {"detail":"Job <id> not found"}`

### 18.3 Response preparation

The Go API copies `job.result_urls` into a fresh map.

Then, if the job is terminal and has `result_keys`, it regenerates all presigned URLs.

Terminal statuses considered for URL regeneration:

- `COMPLETED`
- `COMPLETED_WEBHOOK_FAILED`

### 18.4 Presigned URL regeneration

For each `operation -> s3_key` in `result_keys`:

1. derive extension from the key suffix
2. derive original base filename from `original_filename`
3. build a download name `pixtools_{op}_{originalBase}.{ext}`
4. call Go `S3Service.GeneratePresignedURL(...)`

This ensures a fresh 24-hour download URL on every poll/read.

### 18.5 Archive detection

The Go API computes `archiveKey = archives/{job_id}/bundle.zip`.

Then:

1. call `HeadObject`
2. if present:
   - generate archive presigned URL
   - set `archive_url`
3. if absent:
   - `archive_url = null`

### 18.6 Metadata payload

If `job.exif_metadata` is nil:

- return empty object `{}`

### 18.7 Final response shape

Current response:

```json
{
  "job_id": "<uuid>",
  "status": "PENDING",
  "operations": ["webp", "metadata"],
  "result_urls": {},
  "archive_url": null,
  "metadata": {},
  "error_message": "",
  "created_at": "2026-03-03T12:34:56Z"
}
```

Important current behavior:

- while work is running, the status is usually still `PENDING`
- the frontend treats both `PENDING` and `PROCESSING` as keep-polling states
- the backend currently does not set `PROCESSING`

## 19. Frontend polling and result rendering

After a successful `POST /api/process`:

1. frontend stores `job_id`
2. frontend starts a 2-second polling interval
3. each poll calls `GET /api/jobs/{job_id}` with `X-API-Key` if configured

Poll handling:

- `PENDING` or `PROCESSING`
  - continue polling
- `FAILED`
  - stop polling, show error, re-enable form
- `COMPLETED` or `COMPLETED_WEBHOOK_FAILED`
  - render results and metadata
  - show webhook warning when appropriate
  - keep polling temporarily if result files exist but `archive_url` is still missing
  - stop after archive appears or after 30 archive-only follow-up polls

Result rendering:

- each `result_urls` entry becomes a result card
- the same presigned URL is used for preview and download
- if `archive_url` exists, the ZIP button is shown
- if metadata exists, the metadata panel is shown

History persistence:

1. downloadable jobs are stored in `localStorage["pixtools_jobs"]`
2. max 10 entries are retained
3. on page load the frontend refetches each job via `GET /api/jobs/{id}`
4. expired or incomplete jobs are discarded from rendered history

## 20. Webhook behavior

Webhooks are delivered by Python in `app/services/webhook.py`.

Entry point:

- `notify_job_update(webhook_url, job_id, status, result_urls)`

Payload shape:

```json
{
  "job_id": "<job-id>",
  "status": "COMPLETED",
  "result_urls": {
    "webp": "<presigned-url>"
  }
}
```

Delivery mechanism:

1. if no webhook URL:
   - count metric `no_webhook`
   - return `True`
2. otherwise call `deliver_webhook(...)`
3. `deliver_webhook` is wrapped by a `pybreaker.CircuitBreaker`
4. use `httpx.AsyncClient(timeout=10.0)`
5. `POST` JSON to the webhook URL
6. require HTTP success via `raise_for_status()`

Circuit breaker behavior:

- consecutive failures open the breaker
- open breaker short-circuits future attempts until reset timeout
- transitions are counted in Prometheus metrics

Job impact:

- webhook failure does not invalidate result generation
- it only upgrades final status to `COMPLETED_WEBHOOK_FAILED`

## 21. Health check internals

### 21.1 Database check

Go health handlers:

- fetch `sql.DB` from GORM
- call `PingContext` with 2-second timeout

### 21.2 Redis check

Go health handlers:

- call `IdempotencyService.Ping(ctx)`
- which calls Redis `PING`

### 21.3 RabbitMQ check

Go health handlers:

- open a short-lived AMQP connection
- 2-second dial timeout
- 5-second heartbeat
- close immediately if successful

### 21.4 S3 check

Go health handlers:

- call `HeadBucket` on the configured bucket

## 22. Observability and metrics

### 22.1 Go-side observability

When `OBSERVABILITY_ENABLED=true`:

- Go installs Gin OpenTelemetry middleware
- Go initializes OTLP HTTP exporter
- traces are exported using `OTEL_EXPORTER_OTLP_ENDPOINT`

Current Go-side observability scope:

- HTTP request traces
- not Prometheus metrics parity yet

### 22.2 Python-side observability

When `observability_enabled=true`:

- FastAPI legacy code instruments FastAPI, Celery, and `httpx`
- workers instrument Celery tracing

When `metrics_enabled=true`:

- legacy Python API exposes `/metrics`
- Celery worker task hooks populate custom Prometheus metrics

Current custom metrics include:

- `pixtools_api_request_latency_seconds`
- `pixtools_job_status_total`
- `pixtools_task_retry_total`
- `pixtools_task_failure_total`
- `pixtools_worker_task_processing_seconds`
- `pixtools_job_queue_wait_seconds`
- `pixtools_job_end_to_end_seconds`
- `pixtools_webhook_circuit_transition_total`
- `pixtools_webhook_delivery_total`
- `pixtools_rabbitmq_queue_depth`
- `pixtools_rabbitmq_queue_consumers`
- `pixtools_rabbitmq_up`

Important current limitation:

- `/metrics` parity is not yet implemented on the Go API
- the primary live HTTP surface is Go
- the public API currently does not expose the same metrics endpoint as the legacy FastAPI app

## 23. Retention and cleanup

### 23.1 S3 retention

Python S3 helper installs lifecycle rules for:

- `raw/`
- `processed/`
- `archives/`

Each expires objects after:

- `settings.s3_retention_days`

### 23.2 Postgres retention

Celery beat schedules `app.tasks.maintenance.prune_expired_jobs` hourly at minute `0`.

Behavior:

1. compute cutoff = `now - job_retention_hours`
2. delete old rows from `jobs`
3. commit

## 24. Failure behavior by stage

### 24.1 Before job row exists

Failures:

- multipart parse error
- invalid MIME type
- invalid operations
- invalid params
- invalid webhook URL
- same-format conversion
- Redis idempotency read error
- file open/read failure
- raw S3 upload failure
- DB insert failure

Effect:

- request fails immediately
- no successful task publish occurs

### 24.2 After job row exists but before queue publish completes

Failure:

- RabbitMQ publish or transaction failure

Effect:

1. API updates row:
   - `status = FAILED`
   - `error_message = "enqueue failed: ..."`
2. API returns `500`

### 24.3 After queue publish succeeds

Failure:

- Redis idempotency write failure

Effect:

- request still returns `202`
- job is still valid and queued
- future duplicate protection for that key may be lost

### 24.4 During worker execution

Failures:

- image decode failures
- parameter processing failures
- S3 download/upload failures
- ML inference failures
- DB session failures in metadata/finalize
- webhook delivery failure
- archive generation failure

Effects:

- normal task exceptions use Celery retry behavior
- final unrecovered failure increments failure metrics
- webhook failure downgrades final status to `COMPLETED_WEBHOOK_FAILED`
- archive failure does not invalidate the already-completed job

### 24.5 Spot and worker-loss resilience

Celery configuration is explicitly tuned for worker loss:

- `acks_late = True`
- `task_reject_on_worker_lost = True`
- `prefetch_multiplier = 1`

Implication:

- if a worker dies mid-task, RabbitMQ can re-deliver the task instead of losing it

## 25. Current end-to-end status semantics

### `PENDING`

Meaning in current code:

- job row exists
- work may still be queued, running, or partially complete

Important:

- this status currently covers both not-started-yet and in-progress

### `COMPLETED`

Meaning:

- all requested non-metadata processing tasks finished
- or metadata-only task finished with `mark_completed=true`
- DB row updated successfully
- webhook either succeeded or was not configured

### `COMPLETED_WEBHOOK_FAILED`

Meaning:

- processing completed successfully
- result URLs exist
- webhook delivery failed or circuit breaker prevented delivery

### `FAILED`

Meaning:

- either enqueue failed on the API side
- or a later unrecovered failure set terminal failure status

## 26. Exact high-level sequence

1. Browser loads `GET /`.
2. Browser loads `/app-config.js`.
3. Browser loads `/static/app.js`.
4. User selects file and operations.
5. Browser validates MIME, size, and same-format locally.
6. Browser sends `POST /api/process`.
7. Go middleware generates `X-Request-ID`.
8. Go middleware enforces `X-API-Key`.
9. Go handler validates form, operations, params, webhook URL, and source/target mismatch.
10. Go handler checks Redis idempotency.
11. Go handler reads the full file body.
12. Go handler uploads raw image to S3.
13. Go handler writes `jobs` row to Postgres.
14. Go handler publishes one or two Celery-compatible messages to RabbitMQ `default_queue`.
15. Go handler stores idempotency mapping in Redis.
16. Go handler returns `202` with `job_id`.
17. Browser starts polling `GET /api/jobs/{job_id}` every 2 seconds.
18. Python worker consumes router task and/or metadata task.
19. Router task builds a Celery chord for all non-metadata operations.
20. Standard workers run image conversions.
21. ML worker runs denoise when requested.
22. Metadata task writes EXIF metadata to Postgres.
23. Finalize task collects result S3 keys, generates presigned URLs, and writes them to Postgres.
24. Finalize task dispatches archive bundling.
25. Finalize task attempts webhook delivery.
26. Archive task uploads `archives/{job_id}/bundle.zip`.
27. Browser polls `GET /api/jobs/{job_id}` again.
28. Go API regenerates fresh presigned URLs and returns them.
29. Once the archive exists, Go also returns `archive_url`.
30. Browser renders previews, download links, metadata, and ZIP button.

## 27. Known current limitations

1. The Go API does not currently expose `/metrics` parity with the old FastAPI API.
2. The backend defines `PROCESSING` but does not currently set it.
3. Raw uploads are fully buffered in Go before S3 upload.
4. There is no transactional outbox; enqueue happens after DB insert and publish failure is compensated by marking the row failed.
5. Archive creation is best-effort and asynchronous after finalization.
6. Frontend API-key protection is operational gating, not strong client security, because the frontend is public.

## 28. Files that implement this workflow

Active HTTP/API path:

- `go-api/cmd/api/main.go`
- `go-api/internal/config/config.go`
- `go-api/internal/handlers/server.go`
- `go-api/internal/handlers/jobs.go`
- `go-api/internal/handlers/health.go`
- `go-api/internal/models/models.go`
- `go-api/internal/models/validation.go`
- `go-api/internal/services/celery.go`
- `go-api/internal/services/idempotency.go`
- `go-api/internal/services/s3.go`
- `go-api/static/index.html`
- `go-api/static/app.js`

Active async worker path:

- `app/tasks/celery_app.py`
- `app/tasks/router.py`
- `app/services/dag_builder.py`
- `app/tasks/image_ops.py`
- `app/tasks/ml_ops.py`
- `app/tasks/metadata.py`
- `app/tasks/finalize.py`
- `app/tasks/archive.py`
- `app/tasks/maintenance.py`
- `app/services/s3.py`
- `app/services/webhook.py`
- `app/models.py`

Legacy Python HTTP reference path:

- `app/main.py`
- `app/middleware.py`
- `app/metrics.py`
- `app/observability.py`
