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

@router.get("/health")
async def health_check():
    """Deep health check that validates connectivity to DB, Redis, and S3."""
    health_status = {
        "status": "healthy",
        "dependencies": {
            "database": "unknown",
            "redis": "unknown",
            "rabbitmq": "unknown",
            "s3": "unknown"
        }
    }

    # 1. Database Check
    try:
        async with AsyncSession(engine) as session:
            await session.execute(text("SELECT 1"))
        health_status["dependencies"]["database"] = "ok"
    except Exception:
        logger.error("Health check failed: Database unreachable", exc_info=True)
        health_status["dependencies"]["database"] = "unreachable"
        health_status["status"] = "unhealthy"

    # 2. Redis Check
    try:
        redis_client = Redis.from_url(settings.redis_url)
        await redis_client.ping()
        await redis_client.aclose()
        health_status["dependencies"]["redis"] = "ok"
    except Exception:
        logger.error("Health check failed: Redis unreachable", exc_info=True)
        health_status["dependencies"]["redis"] = "unreachable"
        health_status["status"] = "unhealthy"

    # 3. RabbitMQ Check
    try:
        with Connection(settings.rabbitmq_url, connect_timeout=5) as connection:
            connection.connect()
        health_status["dependencies"]["rabbitmq"] = "ok"
    except Exception:
        logger.error("Health check failed: RabbitMQ unreachable", exc_info=True)
        health_status["dependencies"]["rabbitmq"] = "unreachable"
        health_status["status"] = "unhealthy"

    # 4. S3 Check
    try:
        s3 = boto3.client(
            "s3",
            endpoint_url=settings.aws_endpoint_url,
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
        )
        s3.head_bucket(Bucket=settings.aws_s3_bucket)
        health_status["dependencies"]["s3"] = "ok"
    except Exception:
        logger.error("Health check failed: S3 unreachable", exc_info=True)
        health_status["dependencies"]["s3"] = "unreachable"
        health_status["status"] = "unhealthy"

    if health_status["status"] == "unhealthy":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=health_status
        )

    return health_status
