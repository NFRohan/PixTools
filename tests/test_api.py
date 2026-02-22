import json
import uuid
from unittest.mock import AsyncMock, MagicMock

import pytest


@pytest.mark.asyncio
async def test_health_check(client, mocker, test_engine):
    """Test the deep health check endpoint."""
    # Patch the engine directly in the health router
    mocker.patch("app.routers.health.engine", test_engine)

    # Mock Redis PING
    mock_redis = mocker.patch("app.routers.health.Redis.from_url")
    mock_redis.return_value.ping = AsyncMock(return_value=True)
    mock_redis.return_value.aclose = AsyncMock()

    # Mock S3 head_bucket
    mock_s3 = mocker.patch("app.routers.health.boto3.client")
    mock_s3.return_value.head_bucket = MagicMock(return_value={})

    response = await client.get("/api/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    # Ensure database check passed either because of SELECT 1 or our test DB setup
    assert data["dependencies"]["database"] == "ok"
    assert data["dependencies"]["redis"] == "ok"
    assert data["dependencies"]["s3"] == "ok"

@pytest.mark.asyncio
async def test_create_job_success(client, s3_mock, mocker):
    """Test successful job creation and dispatch."""
    # Mock build_dag
    mock_dag = mocker.patch("app.routers.jobs.build_dag")

    # Patch upload_raw in the jobs router (where s3 is the module)
    mocker.patch("app.routers.jobs.s3.upload_raw", return_value="raw/test.png")

    file_content = b"fake image data"
    files = {"file": ("test.png", file_content, "image/png")}
    data = {"operations": json.dumps(["webp"])}

    response = await client.post("/api/process", files=files, data=data)

    assert response.status_code == 202
    res_data = response.json()
    assert "job_id" in res_data

    # Verify DAG was dispatched
    mock_dag.assert_called_once()

@pytest.mark.asyncio
async def test_get_job_not_found(client):
    """Test 404 for non-existent job."""
    random_id = str(uuid.uuid4())
    response = await client.get(f"/api/jobs/{random_id}")
    assert response.status_code == 404

@pytest.mark.asyncio
async def test_create_job_invalid_ops(client):
    """Test validation error for invalid operations."""
    files = {"file": ("test.png", b"data", "image/png")}
    data = {"operations": json.dumps(["invalid_op"])}

    response = await client.post("/api/process", files=files, data=data)
    assert response.status_code == 422 # Use int to avoid status code attribute issues
    assert "Invalid operations" in response.json()["detail"]

@pytest.mark.asyncio
async def test_create_job_with_params_and_webhook(client, mocker):
    """Test optional operation_params and webhook_url passthrough."""
    mock_dag = mocker.patch("app.routers.jobs.build_dag")
    mocker.patch("app.routers.jobs.s3.upload_raw", return_value="raw/test.png")

    files = {"file": ("test.png", b"fake image data", "image/png")}
    data = {
        "operations": json.dumps(["webp"]),
        "operation_params": json.dumps({"webp": {"quality": 75, "resize": {"width": 640}}}),
        "webhook_url": "https://example.com/webhook",
    }

    response = await client.post("/api/process", files=files, data=data)
    assert response.status_code == 202
    mock_dag.assert_called_once()
    kwargs = mock_dag.call_args.kwargs
    assert kwargs["operation_params"]["webp"]["quality"] == 75

@pytest.mark.asyncio
async def test_create_job_invalid_webhook_url(client):
    """Test validation error for malformed webhook URL."""
    files = {"file": ("test.png", b"data", "image/png")}
    data = {
        "operations": json.dumps(["webp"]),
        "webhook_url": "ftp://invalid-endpoint",
    }
    response = await client.post("/api/process", files=files, data=data)
    assert response.status_code == 422
    assert "webhook_url" in response.json()["detail"]

@pytest.mark.asyncio
async def test_create_job_rejects_quality_for_png(client):
    """Quality should only be accepted for jpg/webp operations."""
    files = {"file": ("test.png", b"data", "image/png")}
    data = {
        "operations": json.dumps(["png"]),
        "operation_params": json.dumps({"png": {"quality": 90}}),
    }
    response = await client.post("/api/process", files=files, data=data)
    assert response.status_code == 422
    assert "only supported for jpg/webp" in response.json()["detail"]
