import logging
from typing import Any

import httpx
import pybreaker

from app.config import settings

logger = logging.getLogger(__name__)

# Define the circuit breaker with configurable thresholds.
webhook_breaker = pybreaker.CircuitBreaker(
    fail_max=settings.webhook_cb_fail_threshold,
    reset_timeout=settings.webhook_cb_reset_timeout,
    name="WebhookCircuitBreaker"
)

@webhook_breaker
async def deliver_webhook(webhook_url: str, payload: dict[str, Any]):
    """Delivers job status update via POST with circuit breaker protection."""
    logger.info("Delivering webhook to %s", webhook_url, extra={"webhook_url": webhook_url})

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(webhook_url, json=payload)
        response.raise_for_status()

    logger.info("Webhook delivered successfully")

async def notify_job_update(webhook_url: str, job_id: str, status: str, result_urls: dict[str, str]) -> bool:
    """Format and send a webhook payload.

    Returns True when delivered (or when no URL is configured), False on failure.
    """
    if not webhook_url:
        return True

    payload = {
        "job_id": job_id,
        "status": status,
        "result_urls": result_urls
    }

    try:
        await deliver_webhook(webhook_url, payload)
        return True
    except pybreaker.CircuitBreakerError:
        logger.error("Circuit breaker is OPEN. Skipping webhook delivery to %s", webhook_url)
        return False
    except Exception as e:
        logger.error("Failed to deliver webhook: %s", str(e), exc_info=True)
        return False
