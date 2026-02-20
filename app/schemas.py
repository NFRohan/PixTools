"""Pydantic request/response schemas."""

import uuid
from datetime import datetime
from enum import Enum

from pydantic import BaseModel, HttpUrl


class OperationType(str, Enum):
    """Supported image operations."""

    RESIZE = "resize"
    WEBP = "webp"
    AVIF = "avif"
    DENOISE = "denoise"


class JobCreate(BaseModel):
    """Request body for POST /process (operations sent as form field)."""

    operations: list[OperationType]
    webhook_url: HttpUrl


class JobResponse(BaseModel):
    """Response for job creation and status polling."""

    job_id: uuid.UUID
    status: str
    created_at: datetime | None = None

    model_config = {"from_attributes": True}


class WebhookPayload(BaseModel):
    """Payload sent to the client's webhook URL."""

    job_id: uuid.UUID
    status: str
    result_urls: list[str]
    error_message: str | None = None


class HealthDependency(BaseModel):
    """Status of a single dependency."""

    status: str


class HealthResponse(BaseModel):
    """Response for GET /health."""

    status: str
    dependencies: dict[str, str]
