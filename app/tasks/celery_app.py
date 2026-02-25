"""Celery application configuration, queue routing, and DLQ setup."""
# ruff: noqa: I001

import logging
import threading
import time

from celery import Celery
from celery.schedules import crontab
from celery.signals import (
    after_setup_logger,
    after_setup_task_logger,
    task_failure,
    task_postrun,
    task_prerun,
    task_retry,
)
from kombu import Exchange, Queue

from app.config import settings
from app.logging_config import job_id_ctx, request_id_ctx, setup_logging
from app.metrics import (
    job_queue_wait_seconds,
    task_failure_total,
    task_retry_total,
    worker_task_processing_seconds,
)
from app.observability import setup_celery_observability

# --- Celery App ---
celery_app = Celery(
    "pixtools",
    broker=settings.rabbitmq_url,
    backend=settings.redis_url,
)

# --- Queue definitions with Dead Letter Exchange ---
default_exchange = Exchange("default", type="direct")
dlx_exchange = Exchange("dlx", type="direct")

celery_app.conf.task_queues = [
    Queue(
        "default_queue",
        exchange=default_exchange,
        routing_key="default",
        queue_arguments={
            "x-dead-letter-exchange": "dlx",
            "x-dead-letter-routing-key": "dead_letter",
        },
    ),
    Queue(
        "ml_inference_queue",
        exchange=default_exchange,
        routing_key="ml_inference",
        queue_arguments={
            "x-dead-letter-exchange": "dlx",
            "x-dead-letter-routing-key": "dead_letter",
        },
    ),
    Queue(
        "dead_letter",
        exchange=dlx_exchange,
        routing_key="dead_letter",
    ),
]

# --- Routing table ---
ml_queue_name = "ml_inference_queue" if settings.ml_queue_isolation_enabled else "default_queue"
celery_app.conf.task_routes = {
    "app.tasks.ml_ops.denoise": {"queue": ml_queue_name},
    "app.tasks.image_ops.*": {"queue": "default_queue"},
    "app.tasks.archive.*": {"queue": "default_queue"},
    "app.tasks.metadata.*": {"queue": "default_queue"},
    "app.tasks.maintenance.*": {"queue": "default_queue"},
    "app.tasks.finalize.*": {"queue": "default_queue"},
}

celery_app.conf.beat_schedule = {
    "prune-expired-jobs-hourly": {
        "task": "app.tasks.maintenance.prune_expired_jobs",
        "schedule": crontab(minute=0),
    }
}

# --- Spot-instance resilience ---
celery_app.conf.task_acks_late = True
celery_app.conf.task_reject_on_worker_lost = True
celery_app.conf.worker_prefetch_multiplier = 1
celery_app.conf.broker_connection_retry_on_startup = True

# Disable AMQP heartbeats so RabbitMQ doesn't drop the connection when
# the solo-pool worker is blocked for >60 seconds running ML inference.
celery_app.conf.broker_heartbeat = 0

# --- Serialization ---
celery_app.conf.accept_content = ["json"]
celery_app.conf.task_serializer = "json"
celery_app.conf.result_serializer = "json"

# --- Task limits ---
celery_app.conf.task_time_limit = 300  # hard kill after 300s (5m)
celery_app.conf.task_soft_time_limit = 290  # raise SoftTimeLimitExceeded at 290s
celery_app.conf.task_default_retry_delay = 5  # 5s between retries

# --- Observability ---
setup_celery_observability()

# --- Logging & task lifecycle telemetry ---
logger = logging.getLogger(__name__)
_task_start_times: dict[str, float] = {}
_task_start_lock = threading.Lock()


def _parse_enqueued_at(headers: dict | None) -> float | None:
    if not headers:
        return None
    raw = headers.get("X-Job-Enqueued-At")
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


# --- Import task modules so they register with the app ---
import app.tasks.archive  # noqa: E402,F401
import app.tasks.finalize  # noqa: E402,F401
import app.tasks.image_ops  # noqa: E402,F401
import app.tasks.maintenance  # noqa: E402,F401
import app.tasks.metadata  # noqa: E402,F401
import app.tasks.ml_ops  # noqa: E402,F401


@after_setup_logger.connect
@after_setup_task_logger.connect
def setup_celery_logging(*args, **kwargs):  # noqa: ARG001
    """Ensure all worker and task logs use our structured JSON logging."""
    setup_logging()


@task_prerun.connect
def on_task_prerun(task_id=None, task=None, args=None, kwargs=None, **extra):  # noqa: ARG001
    """
    Pick up correlation IDs from task headers or kwargs
    and set them in the ContextVar for the JSON logger.
    """
    if task is None:
        return

    task_kwargs = kwargs or {}
    headers = getattr(task.request, "headers", None) or {}

    job_id = str(task_kwargs.get("job_id", headers.get("X-Job-ID", "N/A")))
    job_id_ctx.set(job_id)

    request_id = str(headers.get("X-Request-ID", task_kwargs.get("request_id", "N/A")))
    request_id_ctx.set(request_id)

    task_name = getattr(task, "name", "unknown")
    worker_id = str(getattr(task.request, "hostname", "unknown"))
    retry_count = int(getattr(task.request, "retries", 0))
    started_at = time.time()

    enqueued_at = _parse_enqueued_at(headers)
    if enqueued_at is not None:
        queue_wait_seconds = max(0.0, started_at - enqueued_at)
        job_queue_wait_seconds.labels(task_name=task_name).observe(queue_wait_seconds)

    if task_id:
        with _task_start_lock:
            _task_start_times[task_id] = time.monotonic()

    logger.info(
        "task_start",
        extra={
            "event": "task_start",
            "data": {
                "task_id": task_id,
                "task_name": task_name,
                "job_id": job_id,
                "enqueue_time": enqueued_at,
                "start_time": started_at,
                "retry_count": retry_count,
                "worker_id": worker_id,
            },
        },
    )


@task_postrun.connect
def on_task_postrun(task_id=None, task=None, state=None, **extra):  # noqa: ARG001
    """Record task duration and reset correlation context."""
    finished_at = time.time()
    duration_seconds = None
    if task_id:
        with _task_start_lock:
            started_monotonic = _task_start_times.pop(task_id, None)
        if started_monotonic is not None:
            duration_seconds = max(0.0, time.monotonic() - started_monotonic)
            task_name = getattr(task, "name", "unknown")
            worker_task_processing_seconds.labels(task_name=task_name).observe(duration_seconds)

    logger.info(
        "task_finish",
        extra={
            "event": "task_finish",
            "data": {
                "task_id": task_id,
                "task_name": getattr(task, "name", "unknown"),
                "job_id": job_id_ctx.get(),
                "finish_time": finished_at,
                "processing_duration_seconds": duration_seconds,
                "retry_count": int(getattr(task.request, "retries", 0)) if task else 0,
                "worker_id": (
                    str(getattr(task.request, "hostname", "unknown"))
                    if task
                    else "unknown"
                ),
                "state": state,
            },
        },
    )

    request_id_ctx.set("N/A")
    job_id_ctx.set("N/A")


@task_retry.connect
def on_task_retry(request=None, reason=None, **extra):  # noqa: ARG001
    """Track task retries for benchmarking retry storm behavior."""
    task_name = str(getattr(request, "task", "unknown"))
    task_retry_total.labels(task_name=task_name).inc()
    logger.warning(
        "task_retry",
        extra={
            "event": "task_retry",
            "data": {
                "task_name": task_name,
                "task_id": getattr(request, "id", None),
                "job_id": (getattr(request, "kwargs", {}) or {}).get("job_id"),
                "retry_count": int(getattr(request, "retries", 0)),
                "reason": str(reason) if reason else "unknown",
                "worker_id": str(getattr(request, "hostname", "unknown")),
            },
        },
    )


@task_failure.connect
def on_task_failure(
    sender=None,
    task_id=None,
    exception=None,
    kwargs=None,
    einfo=None,
    **extra,
):  # noqa: ARG001
    """Track terminal task failures."""
    task_name = str(getattr(sender, "name", sender or "unknown"))
    task_failure_total.labels(task_name=task_name).inc()
    logger.error(
        "task_failure",
        extra={
            "event": "task_failure",
            "data": {
                "task_id": task_id,
                "task_name": task_name,
                "job_id": (kwargs or {}).get("job_id"),
                "error": str(exception) if exception else "unknown",
                "worker_id": "unknown",
                "traceback": str(einfo) if einfo else None,
            },
        },
    )
