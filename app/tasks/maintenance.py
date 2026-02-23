"""Periodic maintenance tasks."""

import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import create_engine, delete
from sqlalchemy.orm import Session

from app.config import settings
from app.models import Job
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

_sync_engine = None


def _get_sync_engine():
    global _sync_engine
    if _sync_engine is None:
        sync_url = settings.database_url.replace("+asyncpg", "+psycopg2")
        _sync_engine = create_engine(sync_url)
    return _sync_engine


@celery_app.task(name="app.tasks.maintenance.prune_expired_jobs", bind=True, max_retries=2)
def prune_expired_jobs(self) -> dict:
    """Delete jobs older than configured retention window."""
    cutoff = datetime.now(UTC) - timedelta(hours=settings.job_retention_hours)
    engine = _get_sync_engine()

    try:
        with Session(engine) as session:
            result = session.execute(delete(Job).where(Job.created_at < cutoff))
            session.commit()
            deleted = result.rowcount or 0
        logger.info("Pruned %d jobs older than %s", deleted, cutoff.isoformat())
        return {"deleted": deleted, "cutoff": cutoff.isoformat()}
    except Exception as exc:
        raise self.retry(exc=exc) from exc
