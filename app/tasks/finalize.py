"""Finalize task - chord callback that updates DB and fires webhook."""

import logging
import time

from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from app.config import settings
from app.metrics import job_end_to_end_seconds, job_status_total
from app.models import Job, JobStatus
from app.services.s3 import generate_presigned_url
from app.services.webhook import notify_job_update
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

_sync_engine = None


def _get_sync_engine():
    global _sync_engine
    if _sync_engine is None:
        sync_url = settings.database_url.replace("+asyncpg", "+psycopg2")
        _sync_engine = create_engine(sync_url)
    return _sync_engine


def _parse_enqueued_at(headers: dict | None) -> float | None:
    if not headers:
        return None
    raw = headers.get("X-Job-Enqueued-At")
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


@celery_app.task(name="app.tasks.finalize.finalize_job", bind=True, max_retries=3)
def finalize_job(self, results: list[str], job_id: str) -> dict:
    """Finalize job state and dispatch webhook/archive side effects."""
    headers = getattr(self.request, "headers", None) or {}
    enqueued_at = _parse_enqueued_at(headers)
    retry_count = int(getattr(self.request, "retries", 0))
    worker_id = str(getattr(self.request, "hostname", "unknown"))

    logger.info(
        "Job %s: finalizing with %d results",
        job_id,
        len(results),
        extra={
            "event": "job_finalize_start",
            "data": {
                "job_id": job_id,
                "enqueue_time": enqueued_at,
                "start_time": time.time(),
                "retry_count": retry_count,
                "worker_id": worker_id,
            },
        },
    )

    status = JobStatus.COMPLETED
    engine = _get_sync_engine()
    result_urls: dict[str, str] = {}
    webhook_url = ""
    original_filename = None
    job_found = False

    with Session(engine) as session:
        job = session.get(Job, job_id)
        orig_name = "image"
        if job and job.original_filename:
            orig_name = job.original_filename.rsplit(".", 1)[0]
            original_filename = job.original_filename

        result_keys: dict[str, str] = {}
        for s3_key in results:
            if not s3_key:
                continue
            parts = s3_key.split("/")[-1]
            op_name = parts.split("_")[0]
            ext = parts.split(".")[-1]
            dl_name = f"pixtools_{op_name}_{orig_name}.{ext}"
            result_urls[op_name] = generate_presigned_url(s3_key, download_filename=dl_name)
            result_keys[op_name] = s3_key

        if job:
            job_found = True
            job.status = status
            job.result_urls = result_urls
            job.result_keys = result_keys
            webhook_url = job.webhook_url
            session.commit()

    if job_found and result_keys:
        request_id = headers.get("X-Request-ID", "N/A")
        try:
            celery_app.signature(
                "app.tasks.archive.bundle_results",
                kwargs={
                    "job_id": job_id,
                    "result_keys": result_keys,
                    "original_filename": original_filename,
                },
                headers={"X-Request-ID": request_id},
            ).apply_async()
        except Exception:
            logger.exception("Job %s: failed to dispatch archive bundling task", job_id)

    webhook_failed = False
    if webhook_url:
        import asyncio

        try:
            delivered = asyncio.run(
                notify_job_update(webhook_url, job_id, status.value, result_urls)
            )
            if not delivered:
                webhook_failed = True
        except Exception as exc:
            logger.error("Error initiating webhook delivery: %s", str(exc))
            webhook_failed = True

    if webhook_failed:
        with Session(engine) as session:
            job = session.get(Job, job_id)
            if job:
                job.status = JobStatus.COMPLETED_WEBHOOK_FAILED
                session.commit()
                status = JobStatus.COMPLETED_WEBHOOK_FAILED

    if enqueued_at is not None:
        job_end_to_end_seconds.observe(max(0.0, time.time() - enqueued_at))
    job_status_total.labels(status=status.value).inc()

    logger.info(
        "Job %s: status -> %s, %d result URLs",
        job_id,
        status.value,
        len(result_urls),
        extra={
            "event": "job_finalize_complete",
            "data": {
                "job_id": job_id,
                "enqueue_time": enqueued_at,
                "finish_time": time.time(),
                "retry_count": retry_count,
                "worker_id": worker_id,
                "status": status.value,
                "result_count": len(result_urls),
            },
        },
    )

    return {"job_id": job_id, "status": status.value, "result_urls": result_urls}

