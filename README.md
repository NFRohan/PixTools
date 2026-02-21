# PixTools 🎨

PixTools is a production-hardened, distributed image processing orchestrator. Built for high-volume transformation pipelines, it combines the speed of **FastAPI** with the massive parallelism of **Celery** to deliver a seamless, asynchronous image manipulation suite.

---

## 🚀 Specialized Capabilities

### ⚡ Distributed Execution Model
Uses an asynchronous **Directed Acyclic Graph (DAG)** model to chain transformations. Complex multi-format conversions (WEBP, AVIF, PNG) and AI inference jobs are distributed across specific worker queues (Standard IO vs. Heavy ML compute).

### 🧠 Deep Learning Denoising
Integrates a dedicated ML worker-pool utilizing a **PyTorch-based DnCNN model**. This provides algorithmic noise reduction for low-light or high-ISO captures, isolated on a dedicated queue with concurrency controls for optimal GPU/CPU utilization.

### 💾 Automated Storage Optimization
Implements **S3 Lifecycle Engines** to prevent cloud storage bloat.
- **Auto-Cleanup**: Temporary raw and processed artifacts are automatically expired after **24 hours**.
- **Self-Healing Policies**: Storage buckets and lifecycle rules are enforced automatically upon application startup.

### 🕵️ Anonymous Persistence & History
Track your work without the friction of account creation.
- **Client-Side Memory**: Leverages `localStorage` to persist your job history across browser sessions.
- **Dynamic Link Healing**: The API dynamically regenerates S3 presigned URLs on every request, ensuring links work for the full duration of their retention window.
- **Expiration Awareness**: Visual badges flag jobs passed their 24h retention window, preventing broken link frustration.

### 🛡️ Resilience Architecture
*   **Circuit Breakers**: Outbound webhooks (webhook-sink-agnostic) are protected by `pybreaker` logic.
*   **Dead Letter Queues (DLQ)**: Poisonous RabbitMQ payloads are quarantined to a `dlx` exchange for forensics.
*   **Atomic Idempotency**: A Redis-backed 24-hour cache layer enforces strict job idempotency.

---

## 🏗 Technology Stack

| Layer | Technology |
| :--- | :--- |
| **Backend** | Python 3.12 (FastAPI, Celery, SQLAlchemy) |
| **Inference** | PyTorch (Pre-trained DnCNN) |
| **UI** | Vanilla JS (Neobrutalist Styling) |
| **Storage** | Amazon S3 / LocalStack |
| **DB / Cache** | PostgreSQL, Redis, RabbitMQ |
| **DevOps** | Docker, Alembic, Ruff, MyPy |

---

## 🐳 Getting Started

### 1. Boot the Ecosystem
Spin up the orchestration plane and workers:
```bash
docker compose up -d
```

### 2. Synchronize Schemas
Ensure the database and persistence layers are in their latest revision:
```bash
docker compose exec api alembic upgrade head
```

### 3. Access the Tools
- **Main App**: [http://localhost:8000](http://localhost:8000)
- **Interactive API Docs**: [http://localhost:8000/docs](http://localhost:8000/docs)

---

## 🧪 Testing & Quality Assurance

PixTools maintains a rigorous testing protocol with **87%+ code coverage**.

### Automated Suite
```bash
# Run the full integration suite
pytest -v --cov=app tests/
```

### Static Analysis
```bash
ruff check app tests
mypy app
```

---

## 🛡 License
Internal Project - All Rights Reserved.
