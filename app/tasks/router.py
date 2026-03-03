"""Celery router task to bridge Go API to Python Celery Canvas."""

import logging

from app.services.dag_builder import build_dag
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


def _parse_enqueued_at(value: float | str | None) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

@celery_app.task(name="app.tasks.router.start_pipeline")
def start_pipeline(
    job_id: str,
    s3_raw_key: str,
    operations: list[str],
    operation_params: dict,
    request_id: str = "N/A",
    enqueued_at: float | str | None = None,
):
    """
    Router task invoked by the Go API to orchestrate the DAG.

    The Go API fires this single, simple task with basic kwargs.
    Python receives it and constructs the complex parallel chord/group
    which native gocelery struggles to serialize directly.
    """
    logger.info("Go API requested pipeline start for job %s", job_id)

    build_dag(
        job_id=job_id,
        s3_raw_key=s3_raw_key,
        operations=operations,
        request_id=request_id,
        operation_params=operation_params,
        enqueued_at=_parse_enqueued_at(enqueued_at),
    )

    logger.info("Pipeline DAG dispatched successfully for job %s", job_id)
