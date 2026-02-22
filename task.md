# PixTools — Sprint Breakdown

## Sprint 1: Foundation & Local Dev Stack ✅
> **Goal**: Project boots locally, DB connects, basic structure in place.

- [x] Scaffold project dirs (`app/`, `tests/`, `k8s/`, `infra/`, `models/`, `alembic/`)
- [x] `pyproject.toml` + `requirements.txt` (all deps pinned)
- [x] `app/config.py` — Pydantic Settings
- [x] `app/models.py` — SQLAlchemy `Job` model
- [x] `app/schemas.py` — Pydantic request/response models
- [x] `app/database.py` — async engine + session factory
- [x] `app/main.py` — FastAPI app factory with lifespan
- [x] `Dockerfile` — multi-stage build
- [x] `docker-compose.yaml` — FastAPI + Postgres + Redis + RabbitMQ + LocalStack
- [x] `.env.example`
- [x] **Verify**: `docker-compose up` boots, `/docs` loads, DB connects

---

## Sprint 2: Core Pipeline (API → Celery → S3) ✅
> **Goal**: End-to-end flow works — upload image, run tasks, get webhook.

- [x] `app/routers/jobs.py` — `POST /process` + `GET /jobs/{id}`
- [x] `app/services/s3.py` — upload_raw, download_raw, upload_processed
- [x] `app/services/idempotency.py` — Redis check/set
- [x] `app/services/dag_builder.py` — Canvas chain/chord builder
- [x] `app/tasks/celery_app.py` — Celery config + queue routing
- [x] `app/tasks/image_ops.py` — convert_jpg, convert_png, convert_webp, convert_avif
- [x] `app/tasks/finalize.py` — DB update + webhook POST
- [ ] `tests/test_api.py`, `tests/test_dag_builder.py`, `tests/test_tasks.py`
- [x] **Verify**: Upload image → task runs → processed image in S3 → job COMPLETED with presigned URLs

---

## Sprint 3: Frontend (Neobrutalism) ✅
> **Goal**: Upload UI with preview, operation selection, result cards with download.

- [x] `app/static/index.html` — single-page layout (upload → processing → results)
- [x] `app/static/style.css` — neobrutalism design system
- [x] `app/static/app.js` — drag-drop, polling, result card rendering
- [x] Mount `StaticFiles` in `app/main.py`
- [x] **Verify**: Upload image via UI → see processing state → download results

---

## Sprint 4: DnCNN ML Integration ✅
> **Goal**: Denoise task runs real inference with `dncnn_color_blind.pth`.

- [x] `app/ml/dncnn.py` — DnCNN model definition (20-layer, 64ch, RGB)
- [x] `app/tasks/ml_ops.py` — denoise task with singleton model loading
- [x] Place `dncnn_color_blind.pth` in `models/`
- [x] ML worker queue isolation (`ml_inference_queue`, `--concurrency=1`)
- [x] **Verify**: Upload noisy image with `["denoise"]` → denoised output in S3

---

## Sprint 5: Production Hardening ✅
> **Goal**: Fault tolerance, observability, and code quality gates.

- [x] `app/logging_config.py` — structured JSON logging (`python-json-logger`)
- [x] `app/services/webhook.py` — Implement **Circuit Breaker** (using `pybreaker`) for webhook deliveries
- [x] Health check endpoint (`GET /api/health`) with DB/Redis/S3 reachability checks
- [x] Celery `Task.on_failure` hooks for global error reporting
- [x] **Verify**: Logs appear as JSON in console; webhooks trip "Open" status if target is down
- [ ] `app/middleware.py` — RequestID middleware (correlation IDs)
- [ ] `app/routers/health.py` — deep dependency health check
- [ ] `app/services/webhook.py` — circuit breaker (pybreaker)

---

## Sprint 6: Testing *(IN PROGRESS)*
> **Goal**: 80%+ coverage and automated verification.

- [x] Add testing dependencies to `requirements.txt`
- [x] `tests/conftest.py` — Shared fixtures (mock DB, S3, client)
- [x] `tests/test_api.py` — REST endpoint verification
- [x] `tests/test_tasks.py` — Celery task logic verification
- [x] `tests/test_services.py` — Webhook and S3 service verification
- [x] **Verify**: All tests pass via `pytest`
- [x] Dead Letter Queue config in `celery_app.py`
- [x] `alembic/` — env.py + initial migration
- [x] `tests/test_idempotency.py`
- [x] `pyproject.toml` — ruff + mypy config
- [x] **Verify**: Failing webhook trips circuit breaker, DLQ catches poison messages

---

## Sprint 6: Infrastructure & Deployment <!-- task_id: infrastructure -->
> **Goal**: Full K3s + AWS IaC, monitoring, CI pipeline.

- [ ] `k8s/namespace.yaml`
- [ ] `k8s/rabbitmq/` — deployment + service
- [ ] `k8s/redis/` — deployment + service
- [ ] `k8s/workers/worker-standard.yaml` + `worker-ml.yaml`
- [ ] `k8s/api/` — deployment + service
- [ ] `k8s/keda/scaledobject.yaml`
- [ ] `k8s/monitoring/` — Prometheus, Grafana, celery-exporter configs
- [ ] `infra/main.tf` — provider, VPC, subnets
- [ ] `infra/asg.tf` — launch template + ASG + spot + user data (K3s bootstrap)
- [ ] `infra/rds.tf` — Postgres (app DB + K3s state)
- [ ] `infra/s3.tf` — image bucket + manifest bucket
- [ ] `infra/sns.tf` — EventBridge + SNS interruption alerts
- [ ] `infra/security_groups.tf`
- [ ] `.github/workflows/ci.yaml` — lint + type check + test + build + tf validate
- [ ] `README.md`
- [ ] **Verify**: `terraform validate`, `kubectl apply --dry-run`, CI pipeline passes

---

## Sprint 7: S3 Storage Optimization <!-- task_id: storage -->
> **Goal**: Prevent storage bloat by cleaning up orphan files.

- [x] Implement automated S3 orphan file cleanup <!-- task_id: cleanup -->
    - [x] Create implementation plan <!-- task_id: cleanup_plan -->
    - [x] Configure S3 Lifecycle Rules in `s3.py` <!-- task_id: cleanup_impl -->
    - [x] Add `s3_retention_days` to `config.py` <!-- task_id: cleanup_config -->
    - [x] Verify lifecycle policy via CLI/tests <!-- task_id: cleanup_verify -->

---

## Sprint 8: Anonymous Persistence & History <!-- task_id: persistence_sprint -->
> **Goal**: Persistent job history across refreshes with expiration awareness.

- [x] Implement Anonymous Job Persistence <!-- task_id: anon_persistence -->
    - [x] Create implementation plan <!-- task_id: persistence_plan -->
    - [x] Create Alembic migration for `result_keys` <!-- task_id: persistence_migration -->
    - [x] Update `Job` model and `finalize_job` task <!-- task_id: persistence_backend -->
    - [x] Update `GET /jobs/{id}` for dynamic presigning <!-- task_id: persistence_api -->
    - [x] Implement `localStorage` logic in `app.js` <!-- task_id: persistence_ui -->
    - [x] Add "Expired" badge logic for items > 24h <!-- task_id: persistence_expiry -->
    - [x] **Verify**: Clear local storage, run job, refresh page, verify data remains.

---

## Sprint 9: Maintenance & Cleanup <!-- task_id: cleanup_sprint -->
> **Goal**: Declutter codebase and improve maintainability.

- [x] Remove temporary log files (`*.txt`, `*.log`) from root <!-- task_id: root_cleanup -->
- [x] Remove accidental SQLite artifacts (`alembic.db`) <!-- task_id: db_cleanup -->

---

## Sprint 10: Documentation & Handover <!-- task_id: documentation_sprint -->
> **Goal**: Provide a professional final state for the repository.

- [x] Draft comprehensive git commit message <!-- task_id: git_commit -->
- [x] Expand and professionalize `README.md` <!-- task_id: readme_expansion -->

---

## Sprint 11: Cloud Readiness & Advanced Features <!-- task_id: cloud_readiness_sprint -->
> **Goal**: Final polish and observability before cloud migration.

- [ ] Implement Operation Parameterization (Quality/Resize) <!-- task_id: op_params -->
- [ ] Implement ZIP Result Bundling <!-- task_id: zip_bundle -->
- [ ] Implement Advanced Image Metadata (EXIF) <!-- task_id: exif_metadata -->
- [ ] Implement Custom Webhook Sandbox <!-- task_id: webhook_sandbox -->
- [ ] Implement Prometheus Metrics Exporter <!-- task_id: prometheus_metrics -->
