"""Custom Prometheus metrics for PixTools runtime and load testing."""

from __future__ import annotations

import logging
import threading
import time

from kombu import Connection
from prometheus_client import Counter, Gauge, Histogram

from app.config import settings

logger = logging.getLogger(__name__)

# API latency measured at middleware level with route-normalized path labels.
api_request_latency_seconds = Histogram(
    "pixtools_api_request_latency_seconds",
    "API request latency in seconds.",
    ["method", "path", "status_code"],
    buckets=(
        0.005,
        0.01,
        0.025,
        0.05,
        0.1,
        0.25,
        0.5,
        1.0,
        2.5,
        5.0,
        10.0,
    ),
)

job_status_total = Counter(
    "pixtools_job_status_total",
    "Total jobs observed by final status.",
    ["status"],
)

task_retry_total = Counter(
    "pixtools_task_retry_total",
    "Total Celery task retries.",
    ["task_name"],
)

task_failure_total = Counter(
    "pixtools_task_failure_total",
    "Total Celery task failures.",
    ["task_name"],
)

worker_task_processing_seconds = Histogram(
    "pixtools_worker_task_processing_seconds",
    "Worker task processing time in seconds.",
    ["task_name"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0),
)

job_queue_wait_seconds = Histogram(
    "pixtools_job_queue_wait_seconds",
    "Queue wait time from enqueue to worker start.",
    ["task_name"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0),
)

job_end_to_end_seconds = Histogram(
    "pixtools_job_end_to_end_seconds",
    "End-to-end job duration from enqueue to finalize.",
    buckets=(0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0),
)

webhook_circuit_transition_total = Counter(
    "pixtools_webhook_circuit_transition_total",
    "Circuit breaker transition count.",
    ["old_state", "new_state"],
)

webhook_delivery_total = Counter(
    "pixtools_webhook_delivery_total",
    "Webhook delivery attempts by outcome.",
    ["result"],
)

rabbitmq_queue_depth = Gauge(
    "pixtools_rabbitmq_queue_depth",
    "RabbitMQ queue depth.",
    ["queue"],
)

rabbitmq_queue_consumers = Gauge(
    "pixtools_rabbitmq_queue_consumers",
    "RabbitMQ queue consumers.",
    ["queue"],
)

rabbitmq_up = Gauge(
    "pixtools_rabbitmq_up",
    "RabbitMQ broker connectivity (1=up, 0=down).",
)

_QUEUE_NAMES = ("default_queue", "ml_inference_queue", "dead_letter")
_queue_refresh_lock = threading.Lock()
_last_queue_refresh_monotonic = 0.0


def refresh_queue_depth_metrics(force: bool = False) -> None:
    """Refresh queue depth/consumer gauges from RabbitMQ.

    Called from API middleware when /metrics is scraped. Refreshing is rate-limited
    to avoid opening a broker connection on every scrape.
    """
    global _last_queue_refresh_monotonic

    now = time.monotonic()
    with _queue_refresh_lock:
        if not force and (now - _last_queue_refresh_monotonic) < 5:
            return
        _last_queue_refresh_monotonic = now

    try:
        with Connection(settings.rabbitmq_url, connect_timeout=3) as connection:
            with connection.channel() as channel:
                for queue_name in _QUEUE_NAMES:
                    _, message_count, consumer_count = channel.queue_declare(
                        queue=queue_name,
                        passive=True,
                    )
                    rabbitmq_queue_depth.labels(queue=queue_name).set(message_count)
                    rabbitmq_queue_consumers.labels(queue=queue_name).set(consumer_count)
        rabbitmq_up.set(1)
    except Exception:
        rabbitmq_up.set(0)
        logger.warning("Failed to refresh RabbitMQ queue depth metrics", exc_info=True)

