# ---------- Stage 1: Builder ----------
FROM python:3.12-slim AS builder

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml README.md ./
COPY app/ ./app/
COPY models/ ./models/
RUN apt-get update && apt-get install -y \
    libheif-dev \
    libaom-dev \
    pkg-config \
    gcc \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir .

# ---------- Stage 2: Runtime ----------
FROM python:3.12-slim AS runtime

WORKDIR /app

# Copy virtualenv from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN apt-get update && apt-get install -y \
    libheif1 \
    libaom3 \
    && rm -rf /var/lib/apt/lists/*

# Copy application code
COPY app/ ./app/
COPY models/ ./models/
COPY alembic/ ./alembic/
COPY alembic.ini .

# Default: run FastAPI via Uvicorn
# Override CMD for Celery workers in docker-compose / K8s
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
