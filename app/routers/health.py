import logging

import boto3
from fastapi import APIRouter, HTTPException, status
from kombu import Connection
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import engine

router = APIRouter(tags=["ops"])
logger = logging.getLogger(__name__)


async def _check_database() -> bool:
    try:
        async with AsyncSession(engine) as session:
            await session.execute(text("SELECT 1"))
        return True
    except Exception:
        logger.error("Health check failed: database unreachable", exc_info=True)
        return False


async def _check_redis() -> bool:
    try:
        redis_client = Redis.from_url(settings.redis_url)
        await redis_client.ping()
        await redis_client.aclose()  # type: ignore[attr-defined]
        return True
    except Exception:
        logger.error("Health check failed: redis unreachable", exc_info=True)
        return False


def _check_rabbitmq() -> bool:
    try:
        with Connection(settings.rabbitmq_url, connect_timeout=2) as connection:
            connection.connect()
        return True
    except Exception:
        logger.error("Health check failed: rabbitmq unreachable", exc_info=True)
        return False


def _check_s3() -> bool:
    try:
        s3 = boto3.client(
            "s3",
            endpoint_url=settings.aws_endpoint_url,
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
        )
        s3.head_bucket(Bucket=settings.aws_s3_bucket)
        return True
    except Exception:
        logger.error("Health check failed: s3 unreachable", exc_info=True)
        return False


def _build_response(dependencies: dict[str, str]) -> dict:
    healthy = all(state == "ok" for state in dependencies.values())
    return {
        "status": "healthy" if healthy else "unhealthy",
        "dependencies": dependencies,
    }


@router.get("/livez")
async def livez():
    """Fast liveness endpoint for kubelet probes."""
    return {"status": "alive"}


@router.get("/readyz")
async def readyz():
    """Readiness endpoint: checks only core dependencies required to serve traffic."""
    dependencies = {
        "database": "ok" if await _check_database() else "unreachable",
        "redis": "ok" if await _check_redis() else "unreachable",
        "rabbitmq": "ok" if _check_rabbitmq() else "unreachable",
    }
    status_payload = _build_response(dependencies)
    if status_payload["status"] == "unhealthy":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=status_payload,
        )
    return status_payload


@router.get("/health")
async def health_check():
    """Deep health endpoint for diagnostics (includes S3)."""
    dependencies = {
        "database": "ok" if await _check_database() else "unreachable",
        "redis": "ok" if await _check_redis() else "unreachable",
        "rabbitmq": "ok" if _check_rabbitmq() else "unreachable",
        "s3": "ok" if _check_s3() else "unreachable",
    }
    status_payload = _build_response(dependencies)
    if status_payload["status"] == "unhealthy":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=status_payload,
        )
    return status_payload
