"""Image format conversion tasks — JPG, PNG, WebP, AVIF."""

import logging

from app.services.s3 import download_raw, upload_processed
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


def _convert(job_id: str, s3_raw_key: str, target_format: str, operation_name: str) -> str:
    """Shared conversion logic for all format tasks."""
    logger.info("Job %s: starting %s conversion", job_id, operation_name)
    image = download_raw(s3_raw_key)
    s3_key = upload_processed(image, job_id, operation_name, target_format)
    logger.info("Job %s: %s complete → %s", job_id, operation_name, s3_key)
    return s3_key


@celery_app.task(name="app.tasks.image_ops.convert_jpg", bind=True, max_retries=3)
def convert_jpg(self, job_id: str, s3_raw_key: str) -> str:
    """Convert image to JPEG format."""
    try:
        return _convert(job_id, s3_raw_key, "JPEG", "jpg")
    except Exception as exc:
        raise self.retry(exc=exc)


@celery_app.task(name="app.tasks.image_ops.convert_png", bind=True, max_retries=3)
def convert_png(self, job_id: str, s3_raw_key: str) -> str:
    """Convert image to PNG format."""
    try:
        return _convert(job_id, s3_raw_key, "PNG", "png")
    except Exception as exc:
        raise self.retry(exc=exc)


@celery_app.task(name="app.tasks.image_ops.convert_webp", bind=True, max_retries=3)
def convert_webp(self, job_id: str, s3_raw_key: str) -> str:
    """Convert image to WebP format."""
    try:
        return _convert(job_id, s3_raw_key, "WEBP", "webp")
    except Exception as exc:
        raise self.retry(exc=exc)


@celery_app.task(name="app.tasks.image_ops.convert_avif", bind=True, max_retries=3)
def convert_avif(self, job_id: str, s3_raw_key: str) -> str:
    """Convert image to AVIF format."""
    try:
        return _convert(job_id, s3_raw_key, "AVIF", "avif")
    except Exception as exc:
        raise self.retry(exc=exc)
