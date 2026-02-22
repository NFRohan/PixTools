"""ZIP archive bundling task for completed job artifacts."""

import io
import logging
import zipfile

from app.services import s3
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


@celery_app.task(name="app.tasks.archive.bundle_results", bind=True, max_retries=2)
def bundle_results(
    self,
    job_id: str,
    result_keys: dict[str, str],
    original_filename: str | None = None,
) -> str:
    """Download processed artifacts, build ZIP archive, and upload back to S3."""
    if not result_keys:
        raise ValueError("No result keys provided for archive bundling")

    try:
        base_name = original_filename.rsplit(".", 1)[0] if original_filename else "image"
        buffer = io.BytesIO()

        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for operation, s3_key in result_keys.items():
                artifact_bytes = s3.download_object_bytes(s3_key)
                ext = s3_key.rsplit(".", 1)[-1]
                archive_member = f"pixtools_{operation}_{base_name}.{ext}"
                zf.writestr(archive_member, artifact_bytes)

        archive_key = s3.upload_archive_bytes(buffer.getvalue(), job_id)
        logger.info("Job %s: archive created -> %s", job_id, archive_key)
        return archive_key
    except Exception as exc:
        raise self.retry(exc=exc)
