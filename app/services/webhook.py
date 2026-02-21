import logging
from typing import Any

import httpx
import pybreaker

logger = logging.getLogger(__name__)

# Define the circuit breaker: opens after 5 failures, resets after 60 seconds
webhook_breaker = pybreaker.CircuitBreaker(
    fail_max=5,
    reset_timeout=60,
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

async def notify_job_update(webhook_url: str, job_id: str, status: str, result_urls: dict[str, str]):
    """Higher-level helper to format and send the webhook."""
    if not webhook_url:
        return

    payload = {
        "job_id": job_id,
        "status": status,
        "result_urls": result_urls
    }

    try:
        await deliver_webhook(webhook_url, payload)
    except pybreaker.CircuitBreakerError:
        logger.error("Circuit breaker is OPEN. Skipping webhook delivery to %s", webhook_url)
    except Exception as e:
        logger.error("Failed to deliver webhook: %s", str(e), exc_info=True)
