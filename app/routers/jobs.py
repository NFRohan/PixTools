"""Jobs router — POST /process and GET /jobs/{job_id}."""

import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import get_db
from app.models import Job, JobStatus
from app.schemas import OperationType
from app.services import idempotency, s3
from app.services.dag_builder import build_dag

logger = logging.getLogger(__name__)

router = APIRouter(tags=["jobs"])

# Map file extension → MIME type for source format detection
EXT_TO_FORMAT = {
    "jpg": "jpg",
    "jpeg": "jpg",
    "png": "png",
    "webp": "webp",
    "avif": "avif",
}


@router.post("/process", status_code=status.HTTP_202_ACCEPTED)
async def create_job(
    file: Annotated[UploadFile, File(description="Image file to process")],
    operations: Annotated[str, Form(description='JSON array of operations, e.g. ["webp","denoise"]')],
    idempotency_key: Annotated[str | None, Form()] = None,
    db: AsyncSession = Depends(get_db),
):
    """Upload an image and queue processing operations."""
    import json

    # --- Validate file size ---
    file_bytes = await file.read()
    if len(file_bytes) > settings.max_upload_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File exceeds {settings.max_upload_bytes // (1024 * 1024)}MB limit",
        )

    # --- Validate MIME type ---
    if file.content_type not in settings.accepted_mime_types:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported file type: {file.content_type}. Accepted: {settings.accepted_mime_types}",
        )

    # --- Parse operations ---
    try:
        ops_list = json.loads(operations)
        ops = [OperationType(op) for op in ops_list]
    except (json.JSONDecodeError, ValueError) as e:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Invalid operations: {e}",
        )

    if not ops:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="At least one operation is required",
        )

    # --- Same-format rejection ---
    source_ext = file.filename.rsplit(".", 1)[-1].lower() if file.filename and "." in file.filename else None
    source_format = EXT_TO_FORMAT.get(source_ext) if source_ext else None
    conversion_ops = [op for op in ops if op != OperationType.DENOISE]
    for op in conversion_ops:
        if op.value == source_format:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Cannot convert {source_ext} to {op.value} — source and target formats are the same",
            )

    # --- Idempotency check ---
    if idempotency_key:
        existing_job_id = idempotency.check_idempotency(idempotency_key)
        if existing_job_id:
            logger.info("Idempotent hit: key=%s → job=%s", idempotency_key, existing_job_id)
            return {"job_id": existing_job_id, "status": "PENDING"}

    # --- Upload to S3 ---
    job_id = uuid.uuid4()
    s3_raw_key = s3.upload_raw(file_bytes, file.filename or "upload.bin", job_id)

    # --- Create job record ---
    job = Job(
        id=job_id,
        status=JobStatus.PENDING,
        operations=[op.value for op in ops],
        s3_raw_key=s3_raw_key,
        original_filename=file.filename,
        webhook_url="internal://frontend",  # webhook is internal to frontend
    )
    db.add(job)
    await db.flush()

    # --- Set idempotency key ---
    if idempotency_key:
        idempotency.set_idempotency(idempotency_key, str(job_id))

    # --- Dispatch DAG ---
    from app.logging_config import request_id_ctx
    rid = request_id_ctx.get()

    build_dag(str(job_id), s3_raw_key, [op.value for op in ops], request_id=rid)
    logger.info("Job %s created and dispatched", job_id)

    return {"job_id": str(job_id), "status": "PENDING"}


@router.get("/jobs/{job_id}")
async def get_job(job_id: uuid.UUID, db: AsyncSession = Depends(get_db)):
    """Poll job status and results."""
    result = await db.execute(select(Job).where(Job.id == job_id))
    job = result.scalar_one_or_none()

    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found",
        )

    # If result_urls are missing or expired (stored signed URLs have a TTL), 
    # we regenerate them on the fly if we have result_keys.
    # This ensures history links work as long as the file exists in S3.
    result_urls = job.result_urls or {}
    if job.status in [JobStatus.COMPLETED, JobStatus.COMPLETED_WEBHOOK_FAILED] and job.result_keys:
        fresh_urls = {}
        original_base = job.original_filename.rsplit(".", 1)[0] if job.original_filename else "image"
        
        for op, s3_key in job.result_keys.items():
            ext = s3_key.split(".")[-1]
            dl_name = f"pixtools_{op}_{original_base}.{ext}"
            fresh_urls[op] = s3.generate_presigned_url(s3_key, download_filename=dl_name)
        
        result_urls = fresh_urls

    return {
        "job_id": str(job.id),
        "status": job.status.value,
        "operations": job.operations,
        "result_urls": result_urls,
        "error_message": job.error_message,
        "created_at": job.created_at.isoformat() if job.created_at else None,
    }
