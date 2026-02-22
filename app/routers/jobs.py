"""Jobs router - POST /process and GET /jobs/{job_id}."""

import json
import logging
import uuid
from typing import Annotated
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, File, Form, HTTPException, Header, UploadFile, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import get_db
from app.models import Job, JobStatus
from app.schemas import OperationType
from app.services import idempotency, s3
from app.services.dag_builder import build_dag
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

router = APIRouter(tags=["jobs"])

# Map file extension -> format for source/target validation.
EXT_TO_FORMAT = {
    "jpg": "jpg",
    "jpeg": "jpg",
    "png": "png",
    "webp": "webp",
    "avif": "avif",
}
QUALITY_SUPPORTED_OPS = {"jpg", "webp"}
RESIZE_SUPPORTED_OPS = {"jpg", "png", "webp", "avif", "denoise"}


def _validate_webhook_url(webhook_url: str | None) -> str:
    """Accept only absolute http(s) webhook URLs, else empty string."""
    if not webhook_url:
        return ""

    parsed = urlparse(webhook_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="webhook_url must be a valid http(s) URL",
        )
    return webhook_url


def _parse_operation_params(raw_params: str | None, ops: list[OperationType]) -> dict[str, dict]:
    """Parse and validate operation params payload."""
    if not raw_params:
        return {}

    try:
        parsed = json.loads(raw_params)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Invalid operation_params JSON: {exc}",
        ) from exc

    if not isinstance(parsed, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="operation_params must be a JSON object",
        )

    allowed = {op.value for op in ops}
    normalized: dict[str, dict] = {}

    for op_name, op_params in parsed.items():
        if op_name not in allowed:
            continue
        if not isinstance(op_params, dict):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"operation_params['{op_name}'] must be an object",
            )

        out: dict = {}
        quality = op_params.get("quality")
        if quality is not None:
            if op_name not in QUALITY_SUPPORTED_OPS:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"operation_params['{op_name}'].quality is only supported for jpg/webp",
                )
            try:
                quality_int = int(quality)
            except (TypeError, ValueError) as exc:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"operation_params['{op_name}'].quality must be an integer",
                ) from exc
            if quality_int < 1 or quality_int > 100:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"operation_params['{op_name}'].quality must be 1..100",
                )
            out["quality"] = quality_int

        resize = op_params.get("resize")
        if resize is not None:
            if op_name not in RESIZE_SUPPORTED_OPS:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"operation_params['{op_name}'].resize is only supported for jpg/png/webp/avif/denoise",
                )
            if not isinstance(resize, dict):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"operation_params['{op_name}'].resize must be an object",
                )

            width = resize.get("width")
            height = resize.get("height")
            if width is None and height is None:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"operation_params['{op_name}'].resize requires width or height",
                )

            resize_out: dict[str, int] = {}
            if width is not None:
                try:
                    width = int(width)
                except (TypeError, ValueError) as exc:
                    raise HTTPException(
                        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                        detail=f"operation_params['{op_name}'].resize.width must be an integer",
                    ) from exc
                if width <= 0:
                    raise HTTPException(
                        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                        detail=f"operation_params['{op_name}'].resize.width must be > 0",
                    )
                resize_out["width"] = width

            if height is not None:
                try:
                    height = int(height)
                except (TypeError, ValueError) as exc:
                    raise HTTPException(
                        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                        detail=f"operation_params['{op_name}'].resize.height must be an integer",
                    ) from exc
                if height <= 0:
                    raise HTTPException(
                        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                        detail=f"operation_params['{op_name}'].resize.height must be > 0",
                    )
                resize_out["height"] = height

            out["resize"] = resize_out

        if out:
            normalized[op_name] = out

    return normalized


@router.post("/process", status_code=status.HTTP_202_ACCEPTED)
async def create_job(
    file: Annotated[UploadFile, File(description="Image file to process")],
    operations: Annotated[
        str,
        Form(description='JSON array of operations, e.g. ["webp","denoise"]'),
    ],
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    operation_params: Annotated[
        str | None,
        Form(description='Optional JSON object keyed by op, e.g. {"webp":{"quality":75}}'),
    ] = None,
    webhook_url: Annotated[str | None, Form(description="Optional http(s) webhook URL")] = None,
    db: AsyncSession = Depends(get_db),
):
    """Upload an image and queue processing operations."""
    file_bytes = await file.read()

    if len(file_bytes) > settings.max_upload_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File exceeds {settings.max_upload_bytes // (1024 * 1024)}MB limit",
        )

    if file.content_type not in settings.accepted_mime_types:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported file type: {file.content_type}. Accepted: {settings.accepted_mime_types}",
        )

    try:
        ops_list = json.loads(operations)
        ops = [OperationType(op) for op in ops_list]
    except (json.JSONDecodeError, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Invalid operations: {exc}",
        ) from exc

    if not ops:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="At least one operation is required",
        )

    op_params = _parse_operation_params(operation_params, ops)
    validated_webhook_url = _validate_webhook_url(webhook_url)

    source_ext = file.filename.rsplit(".", 1)[-1].lower() if file.filename and "." in file.filename else None
    source_format = EXT_TO_FORMAT.get(source_ext) if source_ext else None
    conversion_ops = [op for op in ops if op not in {OperationType.DENOISE, OperationType.METADATA}]
    for op in conversion_ops:
        if op.value == source_format:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Cannot convert {source_ext} to {op.value} - source and target formats are the same",
            )

    if idempotency_key:
        existing_job_id = idempotency.check_idempotency(idempotency_key)
        if existing_job_id:
            logger.info("Idempotent hit: key=%s -> job=%s", idempotency_key, existing_job_id)
            return {"job_id": existing_job_id, "status": "PENDING"}

    job_id = uuid.uuid4()
    s3_raw_key = s3.upload_raw(file_bytes, file.filename or "upload.bin", job_id)

    job = Job(
        id=job_id,
        status=JobStatus.PENDING,
        operations=[op.value for op in ops],
        s3_raw_key=s3_raw_key,
        original_filename=file.filename,
        webhook_url=validated_webhook_url,
    )
    db.add(job)
    await db.flush()

    if idempotency_key:
        idempotency.set_idempotency(idempotency_key, str(job_id))

    from app.logging_config import request_id_ctx

    request_id = request_id_ctx.get()
    op_values = [op.value for op in ops]
    pipeline_ops = [op for op in op_values if op != OperationType.METADATA.value]
    metadata_requested = OperationType.METADATA.value in op_values

    if pipeline_ops:
        build_dag(
            str(job_id),
            s3_raw_key,
            pipeline_ops,
            request_id=request_id,
            operation_params=op_params,
        )

    if metadata_requested:
        celery_app.signature(
            "app.tasks.metadata.extract_metadata",
            kwargs={
                "job_id": str(job_id),
                "s3_raw_key": s3_raw_key,
                "mark_completed": not pipeline_ops,
            },
            headers={"X-Request-ID": request_id},
        ).apply_async()

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
    # regenerate them on demand while files still exist in S3.
    result_urls = job.result_urls or {}
    archive_url = None
    if job.status in [JobStatus.COMPLETED, JobStatus.COMPLETED_WEBHOOK_FAILED] and job.result_keys:
        fresh_urls = {}
        original_base = job.original_filename.rsplit(".", 1)[0] if job.original_filename else "image"

        for op, s3_key in job.result_keys.items():
            ext = s3_key.split(".")[-1]
            dl_name = f"pixtools_{op}_{original_base}.{ext}"
            fresh_urls[op] = s3.generate_presigned_url(s3_key, download_filename=dl_name)

        result_urls = fresh_urls

        archive_key = s3.get_archive_key(str(job.id))
        if s3.object_exists(archive_key):
            archive_name = f"pixtools_bundle_{original_base}.zip"
            archive_url = s3.generate_presigned_url(archive_key, download_filename=archive_name)

    return {
        "job_id": str(job.id),
        "status": job.status.value,
        "operations": job.operations,
        "result_urls": result_urls,
        "archive_url": archive_url,
        "metadata": job.exif_metadata or {},
        "error_message": job.error_message,
        "created_at": job.created_at.isoformat() if job.created_at else None,
    }
