from fastapi import APIRouter, HTTPException, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from redis.asyncio import Redis
import boto3
import logging

from app.database import engine
from app.config import settings

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
            "s3": "unknown"
        }
    }
    
    # 1. Database Check
    try:
        async with AsyncSession(engine) as session:
            await session.execute(text("SELECT 1"))
        health_status["dependencies"]["database"] = "ok"
    except Exception as e:
        logger.error("Health check failed: Database unreachable", exc_info=True)
        health_status["dependencies"]["database"] = "unreachable"
        health_status["status"] = "unhealthy"

    # 2. Redis Check
    try:
        redis_client = Redis.from_url(settings.redis_url)
        await redis_client.ping()
        await redis_client.aclose()
        health_status["dependencies"]["redis"] = "ok"
    except Exception as e:
        logger.error("Health check failed: Redis unreachable", exc_info=True)
        health_status["dependencies"]["redis"] = "unreachable"
        health_status["status"] = "unhealthy"

    # 3. S3 Check
    try:
        s3 = boto3.client(
            "s3",
            endpoint_url=settings.aws_endpoint_url,
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
        )
        s3.head_bucket(Bucket=settings.aws_s3_bucket)
        health_status["dependencies"]["s3"] = "ok"
    except Exception as e:
        logger.error("Health check failed: S3 unreachable", exc_info=True)
        health_status["dependencies"]["s3"] = "unreachable"
        health_status["status"] = "unhealthy"

    if health_status["status"] == "unhealthy":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=health_status
        )
        
    return health_status
