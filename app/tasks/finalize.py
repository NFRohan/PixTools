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
    original_filename = None
    job_found = False

    with Session(engine) as session:
        # Fetch the job to get the original filename
        job = session.get(Job, job_id)
        orig_name = "image"
        if job and job.original_filename:
            orig_name = job.original_filename.rsplit(".", 1)[0]
            original_filename = job.original_filename

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
            job_found = True
            job.status = status
            job.result_urls = result_urls
            job.result_keys = result_keys
            webhook_url = job.webhook_url
            session.commit()

    if job_found and result_keys:
        headers = getattr(self.request, "headers", None) or {}
        request_id = headers.get("X-Request-ID", "N/A")
        celery_app.signature(
            "app.tasks.archive.bundle_results",
            kwargs={
                "job_id": job_id,
                "result_keys": result_keys,
                "original_filename": original_filename,
            },
            headers={"X-Request-ID": request_id},
        ).apply_async()

    # --- Fire Webhook (Non-blocking sync-over-async wrapper) ---
    webhook_failed = False
    if webhook_url:
        import asyncio

        try:
            # Celery workers are synchronous, so run async webhook delivery in a fresh loop.
            delivered = asyncio.run(
                notify_job_update(webhook_url, job_id, status.value, result_urls)
            )
            if not delivered:
                webhook_failed = True
        except Exception as e:
            logger.error("Error initiating webhook delivery: %s", str(e))
            webhook_failed = True

    if webhook_failed:
        with Session(engine) as session:
            job = session.get(Job, job_id)
            if job:
                job.status = JobStatus.COMPLETED_WEBHOOK_FAILED
                session.commit()
                status = JobStatus.COMPLETED_WEBHOOK_FAILED

    logger.info("Job %s: status → %s, %d result URLs", job_id, status.value, len(result_urls))

    return {"job_id": job_id, "status": status.value, "result_urls": result_urls}
