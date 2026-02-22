import logging

from PIL import Image

from app.config import settings
from app.services.s3 import download_raw, upload_processed
from app.tasks.celery_app import celery_app

import pillow_avif

logger = logging.getLogger(__name__)


def _parse_resize(params: dict | None) -> tuple[int | None, int | None] | None:
    """Parse and sanitize resize params from task payload."""
    if not params:
        return None

    resize = params.get("resize")
    if not isinstance(resize, dict):
        return None

    width = resize.get("width")
    height = resize.get("height")
    if width is None and height is None:
        return None

    if width is not None:
        width = int(width)
        if width <= 0:
            raise ValueError("resize.width must be > 0")
        width = min(width, settings.max_image_width)

    if height is not None:
        height = int(height)
        if height <= 0:
            raise ValueError("resize.height must be > 0")
        height = min(height, settings.max_image_height)

    return width, height


def _resize_image(
    image: Image.Image,
    resize_dims: tuple[int | None, int | None] | None,
) -> Image.Image:
    """Resize using requested dimensions; preserve aspect when one side is omitted."""
    if not resize_dims:
        return image

    width, height = resize_dims
    src_w, src_h = image.size
    if src_w <= 0 or src_h <= 0:
        return image

    if width is None and height is None:
        return image
    if width is None:
        width = max(1, int((height / src_h) * src_w))
    elif height is None:
        height = max(1, int((width / src_w) * src_h))

    return image.resize((width, height), Image.Resampling.LANCZOS)


def _extract_quality(params: dict | None) -> int | None:
    """Return validated quality for lossy formats."""
    if not params or "quality" not in params:
        return None

    quality = int(params["quality"])
    if quality < 1 or quality > 100:
        raise ValueError("quality must be between 1 and 100")
    return quality


def _convert(
    job_id: str,
    s3_raw_key: str,
    target_format: str,
    operation_name: str,
    params: dict | None = None,
) -> str:
    """Shared conversion logic for all format tasks."""
    logger.info("Job %s: starting %s conversion", job_id, operation_name)
    image = download_raw(s3_raw_key)
    image = _resize_image(image, _parse_resize(params))

    save_kwargs: dict = {}
    quality = _extract_quality(params)
    if quality is not None and operation_name in {"jpg", "webp"}:
        save_kwargs["quality"] = quality

    s3_key = upload_processed(
        image,
        job_id,
        operation_name,
        target_format,
        save_kwargs=save_kwargs,
    )
    logger.info("Job %s: %s complete -> %s", job_id, operation_name, s3_key)
    return s3_key


@celery_app.task(name="app.tasks.image_ops.convert_jpg", bind=True, max_retries=3)
def convert_jpg(self, job_id: str, s3_raw_key: str, params: dict | None = None) -> str:
    """Convert image to JPEG format."""
    try:
        return _convert(job_id, s3_raw_key, "JPEG", "jpg", params=params)
    except Exception as exc:
        raise self.retry(exc=exc)


@celery_app.task(name="app.tasks.image_ops.convert_png", bind=True, max_retries=3)
def convert_png(self, job_id: str, s3_raw_key: str, params: dict | None = None) -> str:
    """Convert image to PNG format."""
    try:
        return _convert(job_id, s3_raw_key, "PNG", "png", params=params)
    except Exception as exc:
        raise self.retry(exc=exc)


@celery_app.task(name="app.tasks.image_ops.convert_webp", bind=True, max_retries=3)
def convert_webp(self, job_id: str, s3_raw_key: str, params: dict | None = None) -> str:
    """Convert image to WebP format."""
    try:
        return _convert(job_id, s3_raw_key, "WEBP", "webp", params=params)
    except Exception as exc:
        raise self.retry(exc=exc)


@celery_app.task(name="app.tasks.image_ops.convert_avif", bind=True, max_retries=3)
def convert_avif(self, job_id: str, s3_raw_key: str, params: dict | None = None) -> str:
    """Convert image to AVIF format."""
    try:
        return _convert(job_id, s3_raw_key, "AVIF", "avif", params=params)
    except Exception as exc:
        raise self.retry(exc=exc)
