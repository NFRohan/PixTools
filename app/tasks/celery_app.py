"""Celery application configuration, queue routing, and DLQ setup."""
# ruff: noqa: I001

from celery import Celery
from celery.schedules import crontab
from kombu import Exchange, Queue

from app.config import settings
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
celery_app.conf.task_routes = {
    "app.tasks.ml_ops.denoise": {"queue": "ml_inference_queue"},
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

# --- Import task modules so they register with the app ---
# --- Logging & Correlation ID propagation ---
from celery.signals import after_setup_logger, after_setup_task_logger, task_postrun, task_prerun  # noqa: E402

import app.tasks.archive  # noqa: E402,F401
import app.tasks.finalize  # noqa: E402,F401
import app.tasks.image_ops  # noqa: E402,F401
import app.tasks.maintenance  # noqa: E402,F401
import app.tasks.metadata  # noqa: E402,F401
import app.tasks.ml_ops  # noqa: E402,F401
from app.logging_config import job_id_ctx, request_id_ctx, setup_logging  # noqa: E402


@after_setup_logger.connect
@after_setup_task_logger.connect
def setup_celery_logging(logger, **kwargs):
    """Ensure all worker and task logs use our structured JSON logging."""
    setup_logging()

@task_prerun.connect
def on_task_prerun(task_id, task, *args, **kwargs):
    """
    Pick up correlation IDs from task headers or kwargs
    and set them in the ContextVar for the JSON logger.
    """
    # 1. Job ID: passed as a kwarg in all our tasks
    job_id = kwargs.get("job_id", "N/A")
    job_id_ctx.set(job_id)

    # 2. Request ID: passed via headers['X-Request-ID'] or kwargs
    # Search in headers (passed via apply_async)
    request_stack = task.request_stack.top
    headers = (request_stack.headers if request_stack else {}) or {}
    request_id = headers.get("X-Request-ID", kwargs.get("request_id", "N/A"))
    request_id_ctx.set(request_id)

@task_postrun.connect
def on_task_postrun(task_id, task, *args, **kwargs):
    """Reset context after task execution."""
    request_id_ctx.set("N/A")
    job_id_ctx.set("N/A")
