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

## Sprint 4: DnCNN ML Integration
> **Goal**: Denoise task runs real inference with `dncnn_color_blind.pth`.

- [ ] `app/ml/dncnn.py` — DnCNN model definition (20-layer, 64ch, RGB)
- [ ] `app/tasks/ml_ops.py` — denoise task with singleton model loading
- [ ] Place `dncnn_color_blind.pth` in `models/`
- [ ] ML worker queue isolation (`ml_inference_queue`, `--concurrency=1`)
- [ ] **Verify**: Upload noisy image with `["denoise"]` → denoised output in S3

---

## Sprint 5: Production Hardening
> **Goal**: Fault tolerance, observability, and code quality gates.

- [ ] `app/logging_config.py` — structured JSON logging
- [ ] `app/middleware.py` — RequestID middleware (correlation IDs)
- [ ] `app/routers/health.py` — deep dependency health check
- [ ] `app/services/webhook.py` — circuit breaker (pybreaker)
- [ ] Dead Letter Queue config in `celery_app.py`
- [ ] `alembic/` — env.py + initial migration
- [ ] `tests/test_idempotency.py`
- [ ] `pyproject.toml` — ruff + mypy config
- [ ] **Verify**: Failing webhook trips circuit breaker, DLQ catches poison messages

---

## Sprint 6: Infrastructure & Deployment
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
