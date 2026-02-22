"""EXIF metadata extraction task."""

import logging

from PIL import ExifTags
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from app.config import settings
from app.models import Job, JobStatus
from app.services.s3 import download_raw
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


def _to_float(value) -> float | None:
    """Best-effort conversion of EXIF rational-ish values to float."""
    if value is None:
        return None
    try:
        if hasattr(value, "numerator") and hasattr(value, "denominator"):
            if value.denominator == 0:
                return None
            return float(value.numerator) / float(value.denominator)
        if isinstance(value, tuple) and len(value) == 2:
            num, den = value
            den_f = float(den)
            if den_f == 0:
                return None
            return float(num) / den_f
        return float(value)
    except Exception:
        return None


def _format_exposure(value) -> str | None:
    if value is None:
        return None
    try:
        if hasattr(value, "numerator") and hasattr(value, "denominator"):
            if value.denominator:
                return f"{value.numerator}/{value.denominator}s"
        if isinstance(value, tuple) and len(value) == 2 and value[1]:
            return f"{value[0]}/{value[1]}s"
        return f"{float(value):.4f}s"
    except Exception:
        return None


def _gps_to_decimal(gps_info) -> dict | None:
    """Convert EXIF GPS triplets to decimal lat/lon."""
    if not gps_info or not isinstance(gps_info, dict):
        return None

    gps_tags = {
        ExifTags.GPSTAGS.get(k, k): v for k, v in gps_info.items()
    }

    def convert(coord, ref):
        if not coord or ref is None or len(coord) != 3:
            return None
        d = _to_float(coord[0])
        m = _to_float(coord[1])
        s = _to_float(coord[2])
        if d is None or m is None or s is None:
            return None
        decimal = d + (m / 60.0) + (s / 3600.0)
        if ref in {"S", "W"}:
            decimal *= -1.0
        return round(decimal, 6)

    lat = convert(gps_tags.get("GPSLatitude"), gps_tags.get("GPSLatitudeRef"))
    lon = convert(gps_tags.get("GPSLongitude"), gps_tags.get("GPSLongitudeRef"))
    if lat is None and lon is None:
        return None
    return {"latitude": lat, "longitude": lon}


def _extract_exif_metadata(s3_raw_key: str) -> dict:
    """Extract selected EXIF metadata fields from source image."""
    image = download_raw(s3_raw_key)
    exif = image.getexif()
    if not exif:
        return {}

    exif_map = {ExifTags.TAGS.get(tag_id, tag_id): value for tag_id, value in exif.items()}
    metadata: dict = {}

    if exif_map.get("Make"):
        metadata["camera_make"] = str(exif_map["Make"]).strip()
    if exif_map.get("Model"):
        metadata["camera_model"] = str(exif_map["Model"]).strip()
    if exif_map.get("LensModel"):
        metadata["lens_model"] = str(exif_map["LensModel"]).strip()
    if exif_map.get("DateTimeOriginal"):
        metadata["captured_at"] = str(exif_map["DateTimeOriginal"])

    exposure = _format_exposure(exif_map.get("ExposureTime"))
    if exposure:
        metadata["exposure_time"] = exposure

    f_number = _to_float(exif_map.get("FNumber"))
    if f_number is not None:
        metadata["aperture"] = f"f/{round(f_number, 2)}"

    iso_value = exif_map.get("ISOSpeedRatings") or exif_map.get("PhotographicSensitivity")
    if isinstance(iso_value, (tuple, list)) and iso_value:
        iso_value = iso_value[0]
    if iso_value is not None:
        try:
            metadata["iso"] = int(iso_value)
        except Exception:
            pass

    gps_info = None
    # PIL may expose GPS in a dedicated IFD even when "GPSInfo" is a numeric pointer.
    try:
        if hasattr(exif, "get_ifd") and hasattr(ExifTags, "IFD"):
            gps_info = exif.get_ifd(ExifTags.IFD.GPSInfo)
    except Exception:
        gps_info = None
    if gps_info is None:
        gps_info = exif_map.get("GPSInfo")

    gps_decimal = _gps_to_decimal(gps_info)
    if gps_decimal:
        metadata["gps"] = gps_decimal

    return metadata


@celery_app.task(name="app.tasks.metadata.extract_metadata", bind=True, max_retries=2)
def extract_metadata(self, job_id: str, s3_raw_key: str, mark_completed: bool = False) -> dict:
    """Extract EXIF metadata and persist it on the job row."""
    try:
        metadata = _extract_exif_metadata(s3_raw_key)
        engine = _get_sync_engine()
        webhook_url = ""
        with Session(engine) as session:
            job = session.get(Job, job_id)
            if not job:
                logger.warning("Job %s not found while saving EXIF metadata", job_id)
                return {}
            job.exif_metadata = metadata
            if mark_completed:
                job.status = JobStatus.COMPLETED
                job.result_urls = job.result_urls or {}
                job.result_keys = job.result_keys or {}
                webhook_url = job.webhook_url
            session.commit()

        if mark_completed and webhook_url:
            import asyncio
            try:
                delivered = asyncio.run(
                    notify_job_update(webhook_url, job_id, JobStatus.COMPLETED.value, {})
                )
                if not delivered:
                    with Session(engine) as session:
                        job = session.get(Job, job_id)
                        if job:
                            job.status = JobStatus.COMPLETED_WEBHOOK_FAILED
                            session.commit()
            except Exception as exc:
                logger.error("Failed metadata-only webhook for job %s: %s", job_id, exc, exc_info=True)
                with Session(engine) as session:
                    job = session.get(Job, job_id)
                    if job:
                        job.status = JobStatus.COMPLETED_WEBHOOK_FAILED
                        session.commit()

        logger.info("Job %s: EXIF metadata extracted (%d fields)", job_id, len(metadata))
        return metadata
    except Exception as exc:
        raise self.retry(exc=exc)
