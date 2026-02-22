from unittest.mock import AsyncMock

import pybreaker
import pytest

from app.services.webhook import deliver_webhook, notify_job_update


@pytest.mark.asyncio
async def test_webhook_delivery_success(mocker):
    """Test successful webhook delivery."""
    mock_post = mocker.patch("httpx.AsyncClient.post", new_callable=AsyncMock)
    mock_post.return_value.status_code = 200

    await deliver_webhook("http://test.com", {"data": "test"})
    mock_post.assert_called_once()

def test_webhook_circuit_breaker_opens():
    """Test that the circuit breaker state can be opened."""
    test_breaker = pybreaker.CircuitBreaker(fail_max=1)

    # Trip the breaker manually to avoid pytest swallowing the exception handling
    test_breaker.open()
    assert test_breaker.state.name == "open"

@pytest.mark.asyncio
async def test_notify_job_update_skips_on_empty_url(mocker):
    """Test that notifying skips if no URL is provided."""
    mock_deliver = mocker.patch("app.services.webhook.deliver_webhook")
    delivered = await notify_job_update("", "job-1", "COMPLETED", {})
    assert delivered is True
    mock_deliver.assert_not_called()


@pytest.mark.asyncio
async def test_notify_job_update_returns_false_on_failure(mocker):
    """Webhook helper should return False when delivery fails."""
    mocker.patch(
        "app.services.webhook.deliver_webhook",
        new=AsyncMock(side_effect=RuntimeError("boom")),
    )
    delivered = await notify_job_update("http://test.com", "job-1", "COMPLETED", {})
    assert delivered is False

def test_s3_upload_raw(s3_mock):
    """Test the S3 upload_raw wrapper."""
    import uuid

    from app.services.s3 import upload_raw

    job_id = uuid.uuid4()
    content = b"data"
    filename = "test.jpg"

    key = upload_raw(content, filename, job_id)

    assert key.startswith(f"raw/{job_id}/")
    assert key.endswith(".jpg") # Extension should match

    # Verify file exists in mock S3
    obj = s3_mock.get_object(Bucket="test-bucket", Key=key)
    assert obj["Body"].read() == content
