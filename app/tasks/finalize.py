"""Finalize task — chord callback that updates DB and fires webhook."""

import logging

from sqlalchemy import create_engine, update
from sqlalchemy.orm import Session

from app.config import settings
from app.models import Job, JobStatus
from app.services.s3 import generate_presigned_url
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

# Sync engine for Celery tasks (Celery workers are sync, not async)
_sync_engine = None


def _get_sync_engine():
    global _sync_engine
    if _sync_engine is None:
        sync_url = settings.database_url.replace("+asyncpg", "+psycopg2")
        _sync_engine = create_engine(sync_url)
    return _sync_engine


@celery_app.task(name="app.tasks.finalize.finalize_job", bind=True, max_retries=3)
def finalize_job(self, results: list[str], job_id: str) -> dict:
    """Chord callback — receives list of S3 keys from all completed tasks.

    1. Generate presigned URLs for each result
    2. Update job status in Postgres
    3. Fire webhook (if configured)
    """
    logger.info("Job %s: finalizing with %d results", job_id, len(results))

    # Generate presigned download URLs
    result_urls = {}
    for s3_key in results:
        if not s3_key:
            continue
        # Extract operation name from key: processed/{job_id}/{op}_{hash}.ext
        parts = s3_key.split("/")[-1]  # e.g., "webp_abc123.webp"
        op_name = parts.split("_")[0]  # e.g., "webp"
        result_urls[op_name] = generate_presigned_url(s3_key)

    # Update job in DB
    status = JobStatus.COMPLETED
    engine = _get_sync_engine()
    with Session(engine) as session:
        session.execute(
            update(Job)
            .where(Job.id == job_id)
            .values(status=status, result_urls=result_urls)
        )
        session.commit()
    logger.info("Job %s: status → %s, %d result URLs", job_id, status.value, len(result_urls))

    return {"job_id": job_id, "status": status.value, "result_urls": result_urls}
