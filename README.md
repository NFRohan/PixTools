# PixTools 🎨

PixTools is a high-performance, distributed, hybrid-cloud image processing pipeline. Built for scalability and resilience, it allows users to upload images and chain multiple transformations (like format conversion and AI-powered denoising) via an asynchronous Directed Acyclic Graph (DAG) execution model.

Currently serving an intuitive Neobrutalist UI, the backend is orchestrated via FastAPI and Celery.

## 🌟 Key Features

*   **Asynchronous Processing Pipeline**: Leverages Celery chords and chains to distribute image transformations across isolated worker queues (Standard IO vs. Heavy ML compute).
*   **AI Denoising (DnCNN)**: Integrates an active PyTorch inference worker utilizing a pretrained DnCNN model to algorithmically clean noisy images.
*   **Resilience & Fault Tolerance**:
    *   **Circuit Breaker**: Outbound webhooks are protected by `pybreaker`, preventing cascading failures when external notification sinks are offline.
    *   **Dead Letter Queue (DLQ)**: Poisonous RabbitMQ payloads are safely quarantined to a `dlx` exchange rather than dropped or infinitely retried.
    *   **Idempotency Checks**: A `redis`-backed 24-hour cache layer ignores repeat HTTP requests for the same computational job payload, saving DB IO and cloud compute.
*   **Portability First**: All blob storage interactions are abstracted behind an S3 wrapper, completely functional offline via `moto` testing and `localstack`.

## 🏗 Architecture & Stack

*   **API Layer**: FastAPI (Async ecosystem)
*   **Database**: PostgreSQL via SQLAlchemy Async Engine (`asyncpg`) & Alembic Migrations
*   **Broker**: RabbitMQ
*   **Cache / State Backend**: Redis (Used for Idempotency and Celery Chords)
*   **Storage**: Amazon S3 (Simulated locally via LocalStack)
*   **Workers**: Celery (Sync wrappers with solo pools for ML)
*   **Testing**: Pytest (100% green with 87% coverage), Ruff (Formatting), MyPy (Strict Typings)

## 🐳 Local Development Setup

The easiest way to boot the ecosystem is via Docker Compose, which spins up the API, Celery Workers, Postgres, Redis, RabbitMQ, and LocalStack.

### 1. Boot the Infrastructure
```bash
docker compose up -d
```
*   **Frontend / API**: `http://localhost:8000`
*   **API Docs**: `http://localhost:8000/docs`
*   **RabbitMQ UI**: `http://localhost:15672` (guest/guest)

### 2. Apply Database Migrations
Initialize the Postgres schemas via Alembic:
```bash
alembic upgrade head
```

## 🧪 Testing and QA

The project contains a comprehensive test suite covering the async API boundaries, synchronous Celery tasks, S3 interactions, and webhook resilience layers. 

### Running Tests
To run the automated suite with coverage:
```bash
python -m pip install -e .[dev]
pytest -v --cov=app tests/
```

### Static Analysis
Ensure code quality before committing:
```bash
ruff check app tests
mypy app
```

## 🚀 Usage Guide

1.  Navigate to `http://localhost:8000` to access the Neobrutalist Web UI.
2.  Drag and drop an image file.
3.  Select desired conversions (e.g., `WEBP`, `AVIF`, or `DENOISE`).
4.  Submit the job. The UI will instantly poll for the job status.
5.  Watch real-time asynchronous background processing generate the output artifacts and presigned S3 download URLs.
