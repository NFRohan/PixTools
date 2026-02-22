"""DAG builder — composes Celery Canvas workflows from operation lists."""

import logging

from celery import chord, group

from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

# Map operation name → Celery task name
OPERATION_TASK_MAP = {
    "jpg": "app.tasks.image_ops.convert_jpg",
    "png": "app.tasks.image_ops.convert_png",
    "webp": "app.tasks.image_ops.convert_webp",
    "avif": "app.tasks.image_ops.convert_avif",
    "denoise": "app.tasks.ml_ops.denoise",
}


def build_dag(
    job_id: str,
    s3_raw_key: str,
    operations: list[str],
    request_id: str = "N/A",
    operation_params: dict[str, dict] | None = None,
) -> None:
    """Build and dispatch a Celery Canvas DAG for the given operations.

    Structure:
        group(op1, op2, op3, ...) | finalize_job
    All operations run in parallel (group), results are collected by
    the finalize chord callback.
    """
    task_signatures = []
    # Every task in the DAG inherits the X-Request-ID for correlation
    headers = {"X-Request-ID": request_id}

    op_params_map = operation_params or {}

    for op in operations:
        task_name = OPERATION_TASK_MAP.get(op)
        if task_name is None:
            logger.warning("Unknown operation '%s', skipping", op)
            continue
        task_params = op_params_map.get(op, {})
        sig = celery_app.signature(
            task_name,
            kwargs={"job_id": job_id, "s3_raw_key": s3_raw_key, "params": task_params},
            headers=headers
        )
        task_signatures.append(sig)

    if not task_signatures:
        logger.error("No valid operations for job %s", job_id)
        return

    finalize_sig = celery_app.signature(
        "app.tasks.finalize.finalize_job",
        kwargs={"job_id": job_id},
        headers=headers
    )

    # chord: run all tasks in parallel, then call finalize with the results
    workflow = chord(group(task_signatures))(finalize_sig)
    logger.info(
        "Dispatched DAG for job %s: %d tasks → finalize",
        job_id,
        len(task_signatures),
    )
    return workflow
