import logging
from typing import Any

import httpx
import pybreaker

from app.config import settings
from app.metrics import webhook_circuit_transition_total, webhook_delivery_total

logger = logging.getLogger(__name__)


class _WebhookCircuitMetricsListener(pybreaker.CircuitBreakerListener):
    """Emit metrics/logs when circuit breaker changes state."""

    def state_change(self, cb, old_state, new_state):
        old_name = old_state.name if old_state else "unknown"
        new_name = new_state.name if new_state else "unknown"
        webhook_circuit_transition_total.labels(old_state=old_name, new_state=new_name).inc()
        logger.warning(
            "Webhook circuit breaker transition: %s -> %s",
            old_name,
            new_name,
            extra={
                "event": "webhook_circuit_transition",
                "data": {"old_state": old_name, "new_state": new_name},
            },
        )


webhook_breaker = pybreaker.CircuitBreaker(
    fail_max=settings.webhook_cb_fail_threshold,
    reset_timeout=settings.webhook_cb_reset_timeout,
    name="WebhookCircuitBreaker",
    listeners=[_WebhookCircuitMetricsListener()],
)


@webhook_breaker
async def deliver_webhook(webhook_url: str, payload: dict[str, Any]):
    """Delivers job status update via POST with circuit breaker protection."""
    logger.info("Delivering webhook to %s", webhook_url, extra={"webhook_url": webhook_url})

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(webhook_url, json=payload)
        response.raise_for_status()

    logger.info("Webhook delivered successfully")

async def notify_job_update(
    webhook_url: str,
    job_id: str,
    status: str,
    result_urls: dict[str, str],
) -> bool:
    """Format and send a webhook payload.

    Returns True when delivered (or when no URL is configured), False on failure.
    """
    if not webhook_url:
        webhook_delivery_total.labels(result="no_webhook").inc()
        return True

    payload = {
        "job_id": job_id,
        "status": status,
        "result_urls": result_urls,
    }

    try:
        await deliver_webhook(webhook_url, payload)
        webhook_delivery_total.labels(result="success").inc()
        return True
    except pybreaker.CircuitBreakerError:
        webhook_delivery_total.labels(result="circuit_open").inc()
        logger.error("Circuit breaker is OPEN. Skipping webhook delivery to %s", webhook_url)
        return False
    except Exception as exc:
        webhook_delivery_total.labels(result="error").inc()
        logger.error("Failed to deliver webhook: %s", str(exc), exc_info=True)
        return False
