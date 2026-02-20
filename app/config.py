"""Application settings loaded from environment variables."""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Central configuration — all values come from env vars or .env file."""

    # AWS
    aws_access_key_id: str = "test"
    aws_secret_access_key: str = "test"
    aws_region: str = "us-east-1"
    aws_s3_bucket: str = "pixtools-images"
    aws_endpoint_url: str | None = None  # set for LocalStack

    # Database (RDS)
    database_url: str = "postgresql+asyncpg://pixtools:pixtools@localhost:5432/pixtools"

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # RabbitMQ
    rabbitmq_url: str = "amqp://guest:guest@localhost:5672//"

    # Idempotency
    idempotency_ttl_seconds: int = 86400  # 24 hours

    # Webhook circuit breaker
    webhook_cb_fail_threshold: int = 5
    webhook_cb_reset_timeout: int = 60

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()
