"""Celery application configuration, queue routing, and DLQ setup."""

from celery import Celery
from kombu import Exchange, Queue

from app.config import settings

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
    "app.tasks.finalize.*": {"queue": "default_queue"},
}

# --- Spot-instance resilience ---
celery_app.conf.task_acks_late = True
celery_app.conf.task_reject_on_worker_lost = True
celery_app.conf.worker_prefetch_multiplier = 1
celery_app.conf.broker_connection_retry_on_startup = True

# --- Serialization ---
celery_app.conf.accept_content = ["json"]
celery_app.conf.task_serializer = "json"
celery_app.conf.result_serializer = "json"

# --- Task limits ---
celery_app.conf.task_time_limit = 60  # hard kill after 60s
celery_app.conf.task_soft_time_limit = 55  # raise SoftTimeLimitExceeded at 55s
celery_app.conf.task_default_retry_delay = 5  # 5s between retries

# --- Import task modules so they register with the app ---
import app.tasks.image_ops  # noqa: F401
import app.tasks.finalize  # noqa: F401

# ml_ops imported in Sprint 4 when ready
