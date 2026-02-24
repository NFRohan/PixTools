"""Application settings loaded from environment variables."""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Central configuration — all values come from env vars or .env file."""

    # AWS
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None
    aws_region: str = "us-east-1"
    aws_s3_bucket: str = "pixtools-images"
    aws_endpoint_url: str | None = None  # set for LocalStack

    # Database (RDS)
    database_url: str = "sqlite+aiosqlite:///pixtools.db"

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # RabbitMQ
    rabbitmq_url: str = "amqp://guest:guest@localhost:5672//"

    # Idempotency
    idempotency_ttl_seconds: int = 86400  # 24 hours

    # Webhook circuit breaker
    webhook_cb_fail_threshold: int = 5
    webhook_cb_reset_timeout: int = 60

    # Upload constraints
    max_upload_bytes: int = 10 * 1024 * 1024  # 10 MB
    accepted_mime_types: list[str] = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/avif",
    ]

    # Auth
    api_key: str = "pixtools-dev-key"

    # Image processing
    max_image_width: int = 1920
    max_image_height: int = 1080
    task_timeout_seconds: int = 60

    # Data retention
    presigned_url_expiry_seconds: int = 86400  # 24 hours
    job_retention_hours: int = 24
    s3_retention_days: int = 1

    # Notifications (optional)
    alert_email: str | None = None

    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore"
    }


settings = Settings()
