"""Finalize task — chord callback that updates DB and fires webhook."""

import logging

from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from app.config import settings
from app.models import Job, JobStatus
from app.services.s3 import generate_presigned_url
from app.services.webhook import notify_job_update
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

    status = JobStatus.COMPLETED
    engine = _get_sync_engine()
    result_urls = {}
    webhook_url = ""

    with Session(engine) as session:
        # Fetch the job to get the original filename
        job = session.get(Job, job_id)
        orig_name = "image"
        if job and job.original_filename:
            orig_name = job.original_filename.rsplit(".", 1)[0]

        # Generate presigned download URLs with correct disposition filename
        result_keys = {}
        for s3_key in results:
            if not s3_key:
                continue
            parts = s3_key.split("/")[-1]  # e.g., "webp_abc123.webp"
            op_name = parts.split("_")[0]  # e.g., "webp"
            ext = parts.split(".")[-1]

            dl_name = f"pixtools_{op_name}_{orig_name}.{ext}"
            result_urls[op_name] = generate_presigned_url(s3_key, download_filename=dl_name)
            result_keys[op_name] = s3_key

        # Update job
        if job:
            job.status = status
            job.result_urls = result_urls
            job.result_keys = result_keys
            webhook_url = job.webhook_url
            session.commit()

    # --- Fire Webhook (Non-blocking sync-over-async wrapper) ---
    if webhook_url:
        import asyncio
        try:
            # Celery workers are synchronous, so we run the async webhook delivery using a new event loop
            asyncio.run(notify_job_update(webhook_url, job_id, status.value, result_urls))
        except Exception as e:
            logger.error("Error initiating webhook delivery: %s", str(e))

    logger.info("Job %s: status → %s, %d result URLs", job_id, status.value, len(result_urls))

    return {"job_id": job_id, "status": status.value, "result_urls": result_urls}
