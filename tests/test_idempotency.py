from unittest.mock import MagicMock

import pytest

from app.services.idempotency import check_idempotency, set_idempotency


@pytest.fixture(autouse=True)
def mock_redis_service(mocker):
    """Mock the global Redis client used by the idempotency service."""
    mock_redis = MagicMock()
    # Patch the _get_redis function to return our mock
    mocker.patch("app.services.idempotency._get_redis", return_value=mock_redis)
    return mock_redis

def test_check_idempotency_not_found(mock_redis_service):
    """Test when idempotency key is not in Redis."""
    mock_redis_service.get.return_value = None

    result = check_idempotency("req-123")

    assert result is None
    mock_redis_service.get.assert_called_once_with("idempotency:req-123")

def test_check_idempotency_found(mock_redis_service):
    """Test when idempotency key exists."""
    mock_redis_service.get.return_value = "job-abc-456"

    result = check_idempotency("req-123")

    assert result == "job-abc-456"
    mock_redis_service.get.assert_called_once_with("idempotency:req-123")

def test_set_idempotency(mock_redis_service, monkeypatch, mock_settings):
    """Test saving idempotency key to Redis with TTL."""
    # Ensure a known TTL
    monkeypatch.setattr(mock_settings, "idempotency_ttl_seconds", 3600)

    set_idempotency("req-123", "job-abc-456")

    mock_redis_service.setex.assert_called_once_with(
        "idempotency:req-123",
        3600,
        "job-abc-456"
    )
