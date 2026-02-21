"""Idempotency service — Redis-backed duplicate request detection."""

import logging

import redis

from app.config import settings

logger = logging.getLogger(__name__)

_redis_client = None


def _get_redis():
    """Lazy-init Redis client."""
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.from_url(settings.redis_url, decode_responses=True)
    return _redis_client


def check_idempotency(key: str) -> str | None:
    """Check if a request with this key was already processed.

    Returns the existing job_id if found, None otherwise.
    """
    return _get_redis().get(f"idempotency:{key}")


def set_idempotency(key: str, job_id: str) -> None:
    """Store the idempotency key → job_id mapping with TTL."""
    _get_redis().setex(
        f"idempotency:{key}",
        settings.idempotency_ttl_seconds,
        job_id,
    )
    logger.info("Set idempotency key: %s → %s", key, job_id)
