# Implementation Plan - Cloud Readiness & Advanced Features

The goal is to transition PixTools into a production-ready system by adding advanced processing controls, aggregate operations (ZIP), observability (Prometheus), and user-defined integrations (Webhooks).

## Proposed Changes

### 1. Operation Parameterization
Enhance the processing engine to support dynamic parameters for each operation.
- **[MODIFY] [app/tasks/standard.py](file:///d:/Github/PixTools/app/tasks/standard.py)**:
    - Update `process_image` to accept a `params` dict.
    - Implement `quality` (1-100) for JPG and WebP conversions.
    - Implement `resize` logic (width/height) using Pillow.
- **[MODIFY] [app/static/app.js](file:///d:/Github/PixTools/app/static/app.js)**:
    - Update UI to show sliders (Quality) and inputs (Resize) when an operation is selected.

### 2. Result Bundling (ZIP)
Allow users to download all results in a single archive.
- **[NEW] [app/tasks/archive.py](file:///d:/Github/PixTools/app/tasks/archive.py)**:
    - Create a Celery task that fetches completed artifacts from S3, zips them, and uploads the `.zip` to a new `archives/` prefix.
- **[MODIFY] [app/static/app.js](file:///d:/Github/PixTools/app/static/app.js)**:
    - Add a "DOWNLOAD ALL (.ZIP)" button to the results area.

### 3. Advanced Metadata (EXIF)
Extract and display photographic metadata.
- **[NEW] [app/tasks/metadata.py](file:///d:/Github/PixTools/app/tasks/metadata.py)**:
    - Create a task to extract EXIF data (Make, Model, GPS, Exposure) using `Pillow`.
- **[MODIFY] [app/routers/jobs.py](file:///d:/Github/PixTools/app/routers/jobs.py)**:
    - Ensure job results include a `metadata` field.
- **[MODIFY] [app/static/app.js](file:///d:/Github/PixTools/app/static/app.js)**:
    - Display a "Metadata" panel in the UI results section.

### 4. Custom Webhook Sandbox
Allow users to test integration with their own endpoints.
- **[MODIFY] [app/static/app.js](file:///d:/Github/PixTools/app/static/app.js)**:
    - Add an optional "Webhook URL" field to the upload area.
- **[MODIFY] [app/routers/jobs.py](file:///d:/Github/PixTools/app/routers/jobs.py)**:
    - Pass the user-provided URL to the job entity. 

### 5. Observability: LGTM Stack Integration
Transition from simple logs/metrics to a modern, unified observability suite.
- **[L] Loki (Logs)**: 
    - Configure `promtail` or `fluent-bit` to scrape Docker/K8s logs and push to Loki.
    - Ensure structured JSON logs from Sprint 5 are correctly parsed with labels (`job_id`, `status`).
- **[G] Grafana (Visualization)**:
    - Centralize data sources (Loki, Tempo, Mimir).
    - Create a unified "Job Lifecycle" dashboard combining logs, traces, and metrics.
- **[T] Tempo (Tracing)**:
    - **[MODIFY] [app/main.py](file:///d:/Github/PixTools/app/main.py)** & **[app/tasks/celery_app.py](file:///d:/Github/PixTools/app/tasks/celery_app.py)**:
        - Integrate OpenTelemetry (OTLP) instrumentation.
        - Propagate trace contexts across FastAPI and Celery tasks.
- **[M] Mimir (Metrics)**:
    - **[NEW] [app/metrics.py](file:///d:/Github/PixTools/app/metrics.py)**:
        - Export Prometheus metrics (high-cardinality) to Mimir for long-term storage and scalability.
- **[MODIFY] [docker-compose.yaml](file:///d:/Github/PixTools/docker-compose.yaml)**:
    - Add LGTM stack services for local verification.

---

## Verification Plan

### Automated Tests
- **Parameterization**: Unit tests for Quality and Resize tasks.
- **ZIP**: Integration test to verify ZIP generation from S3 sources.
- **Metrics/Scaling**: Verify `/metrics` data flows into Mimir and can be queried in Grafana.
- **Distributed Tracing**: Verify trace spans link from FastAPI request to Celery task execution in Tempo.

### Manual Verification
1. **Dynamic UI**: Verify sliders/inputs appear/disappear correctly based on operation selection.
2. **ZIP Bundle**: Download a ZIP and verify all processed formats are present.
3. **Webhook**: Provide a `webhook.site` URL and verify delivery upon job completion.
