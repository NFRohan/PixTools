# PixTools — Sprint Breakdown

## Sprint 1: Foundation & Local Dev Stack
> **Goal**: Project boots locally, DB connects, basic structure in place.

- [ ] Scaffold project dirs (`app/`, `tests/`, `k8s/`, `infra/`, `models/`, `alembic/`)
- [ ] `pyproject.toml` + `requirements.txt` (all deps pinned)
- [ ] `app/config.py` — Pydantic Settings
- [ ] `app/models.py` — SQLAlchemy `Job` model
- [ ] `app/schemas.py` — Pydantic request/response models
- [ ] `app/database.py` — async engine + session factory
- [ ] `app/main.py` — FastAPI app factory with lifespan
- [ ] `Dockerfile` — multi-stage build
- [ ] `docker-compose.yaml` — FastAPI + Postgres + Redis + RabbitMQ + LocalStack
- [ ] `.env.example`
- [ ] **Verify**: `docker-compose up` boots, `/docs` loads, DB connects

---

## Sprint 2: Core Pipeline (API → Celery → S3)
> **Goal**: End-to-end flow works — upload image, run tasks, get webhook.

- [ ] `app/routers/jobs.py` — `POST /process` + `GET /jobs/{id}`
- [ ] `app/services/s3.py` — upload_raw, download_raw, upload_processed
- [ ] `app/services/idempotency.py` — Redis check/set
- [ ] `app/services/dag_builder.py` — Canvas chain/chord builder
- [ ] `app/tasks/celery_app.py` — Celery config + queue routing
- [ ] `app/tasks/image_ops.py` — resize, convert_webp, convert_avif
- [ ] `app/tasks/finalize.py` — DB update + webhook POST
- [ ] `tests/test_api.py`, `tests/test_dag_builder.py`, `tests/test_tasks.py`
- [ ] **Verify**: Upload image → task runs → processed image in S3 → webhook fires

---

## Sprint 3: DnCNN ML Integration
> **Goal**: Denoise task runs real inference with `dncnn_color_blind.pth`.

- [ ] `app/ml/dncnn.py` — DnCNN model definition (20-layer, 64ch, RGB)
- [ ] `app/tasks/ml_ops.py` — denoise task with singleton model loading
- [ ] Place `dncnn_color_blind.pth` in `models/`
- [ ] ML worker queue isolation (`ml_inference_queue`, `--concurrency=1`)
- [ ] `docker-compose.yaml` — add ML worker service
- [ ] **Verify**: Upload noisy image with `["denoise"]` → denoised output in S3

---

## Sprint 4: Production Hardening
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

## Sprint 5: Infrastructure & Deployment
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
