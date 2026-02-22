"""S3 service — upload/download helpers using boto3."""

import io
import logging
import uuid

import boto3
from botocore.exceptions import ClientError
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
        
        _setup_lifecycle_policy(_s3_client)
    return _s3_client


def _setup_lifecycle_policy(client):
    """
    Configure S3 Lifecycle rules to automatically expire/delete old objects.
    This prevents storage bloat from temporary raw and processed images.
    """
    try:
        client.put_bucket_lifecycle_configuration(
            Bucket=settings.aws_s3_bucket,
            LifecycleConfiguration={
                "Rules": [
                    {
                        "ID": "ExpireRawImages",
                        "Filter": {"Prefix": "raw/"},
                        "Status": "Enabled",
                        "Expiration": {"Days": settings.s3_retention_days},
                    },
                    {
                        "ID": "ExpireProcessedImages",
                        "Filter": {"Prefix": "processed/"},
                        "Status": "Enabled",
                        "Expiration": {"Days": settings.s3_retention_days},
                    },
                    {
                        "ID": "ExpireArchives",
                        "Filter": {"Prefix": "archives/"},
                        "Status": "Enabled",
                        "Expiration": {"Days": settings.s3_retention_days},
                    },
                ]
            },
        )
        logger.info(
            "Configured S3 lifecycle policy (retention: %d days)",
            settings.s3_retention_days,
        )
    except Exception as e:
        logger.warning("Failed to configure S3 lifecycle policy: %s", e)


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


def download_object_bytes(s3_key: str) -> bytes:
    """Download object bytes from S3 for arbitrary key."""
    response = _get_client().get_object(
        Bucket=settings.aws_s3_bucket,
        Key=s3_key,
    )
    return response["Body"].read()


def upload_processed(
    image: Image.Image,
    job_id: str,
    operation: str,
    fmt: str,
    save_kwargs: dict | None = None,
) -> str:
    """Save a processed PIL Image to S3. Returns the S3 key."""
    buffer = io.BytesIO()
    save_opts = dict(save_kwargs or {})
    if fmt.upper() == "JPEG":
        save_opts.setdefault("quality", 85)
        image = image.convert("RGB")  # strip alpha for JPEG
    elif fmt.upper() == "WEBP":
        save_opts.setdefault("quality", 80)
    elif fmt.upper() == "PNG":
        save_opts.setdefault("optimize", True)

    image.save(buffer, format=fmt.upper(), **save_opts)
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


def get_archive_key(job_id: str) -> str:
    """Deterministic S3 key for a job's ZIP bundle."""
    return f"archives/{job_id}/bundle.zip"


def upload_archive_bytes(archive_bytes: bytes, job_id: str) -> str:
    """Upload ZIP archive bytes and return archive key."""
    key = get_archive_key(job_id)
    _get_client().put_object(
        Bucket=settings.aws_s3_bucket,
        Key=key,
        Body=archive_bytes,
        ContentType="application/zip",
    )
    logger.info("Uploaded archive: %s", key)
    return key


def object_exists(s3_key: str) -> bool:
    """Return True if S3 key exists."""
    try:
        _get_client().head_object(Bucket=settings.aws_s3_bucket, Key=s3_key)
        return True
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code")
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def generate_presigned_url(s3_key: str, download_filename: str | None = None) -> str:
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
