"""S3 service — upload/download helpers using boto3."""

import io
import logging
import uuid

import boto3
from PIL import Image

from app.config import settings

logger = logging.getLogger(__name__)

_s3_client = None


def _get_client():
    """Lazy-init S3 client (supports LocalStack via endpoint override)."""
    global _s3_client
    if _s3_client is None:
        kwargs = {
            "region_name": settings.aws_region,
            "aws_access_key_id": settings.aws_access_key_id,
            "aws_secret_access_key": settings.aws_secret_access_key,
        }
        if settings.aws_endpoint_url:
            kwargs["endpoint_url"] = settings.aws_endpoint_url
        _s3_client = boto3.client("s3", **kwargs)
        # Ensure bucket exists (LocalStack dev)
        try:
            _s3_client.head_bucket(Bucket=settings.aws_s3_bucket)
        except Exception:
            _s3_client.create_bucket(Bucket=settings.aws_s3_bucket)
            logger.info("Created S3 bucket: %s", settings.aws_s3_bucket)
    return _s3_client


def upload_raw(file_bytes: bytes, original_filename: str, job_id: uuid.UUID) -> str:
    """Upload the raw user image to S3. Returns the S3 key."""
    ext = original_filename.rsplit(".", 1)[-1].lower() if "." in original_filename else "bin"
    key = f"raw/{job_id}/{uuid.uuid4().hex}.{ext}"
    _get_client().put_object(
        Bucket=settings.aws_s3_bucket,
        Key=key,
        Body=file_bytes,
    )
    logger.info("Uploaded raw image: %s", key)
    return key


def download_raw(s3_key: str) -> Image.Image:
    """Download a raw image from S3 and return a PIL Image."""
    response = _get_client().get_object(
        Bucket=settings.aws_s3_bucket,
        Key=s3_key,
    )
    image_bytes = response["Body"].read()
    return Image.open(io.BytesIO(image_bytes))


def upload_processed(image: Image.Image, job_id: str, operation: str, fmt: str) -> str:
    """Save a processed PIL Image to S3. Returns the S3 key."""
    buffer = io.BytesIO()
    save_kwargs = {}
    if fmt.upper() == "JPEG":
        save_kwargs["quality"] = 85
        image = image.convert("RGB")  # strip alpha for JPEG
    elif fmt.upper() == "WEBP":
        save_kwargs["quality"] = 80
    elif fmt.upper() == "PNG":
        save_kwargs["optimize"] = True

    image.save(buffer, format=fmt.upper(), **save_kwargs)
    buffer.seek(0)

    ext = fmt.lower()
    if ext == "jpeg":
        ext = "jpg"
    key = f"processed/{job_id}/{operation}_{uuid.uuid4().hex[:8]}.{ext}"

    _get_client().put_object(
        Bucket=settings.aws_s3_bucket,
        Key=key,
        Body=buffer.getvalue(),
    )
    logger.info("Uploaded processed image: %s", key)
    return key


def generate_presigned_url(s3_key: str, download_filename: str = None) -> str:
    """Generate a presigned download URL for a processed image."""
    params = {"Bucket": settings.aws_s3_bucket, "Key": s3_key}
    if download_filename:
        params["ResponseContentDisposition"] = f'attachment; filename="{download_filename}"'

    url = _get_client().generate_presigned_url(
        "get_object",
        Params=params,
        ExpiresIn=settings.presigned_url_expiry_seconds,
    )
    
    # Patch for local dev: browser needs to route to localhost, not the Docker service name
    if settings.aws_endpoint_url and "localstack" in settings.aws_endpoint_url:
        url = url.replace("http://localstack:4566", "http://localhost:4566")
        
    return url
