import json
import uuid
from unittest.mock import AsyncMock, MagicMock

import pytest

from app.models import Job, JobStatus


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
    mock_conn = mocker.patch("app.routers.health.Connection")
    mock_conn.return_value.__enter__.return_value.connect = MagicMock(return_value=None)

    response = await client.get("/api/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    # Ensure database check passed either because of SELECT 1 or our test DB setup
    assert data["dependencies"]["database"] == "ok"
    assert data["dependencies"]["redis"] == "ok"
    assert data["dependencies"]["rabbitmq"] == "ok"
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
async def test_create_job_idempotency_header_hit(client, mocker):
    """Header-based idempotency should short-circuit to existing job id."""
    existing_job_id = str(uuid.uuid4())
    mocker.patch("app.routers.jobs.idempotency.check_idempotency", return_value=existing_job_id)
    mock_set = mocker.patch("app.routers.jobs.idempotency.set_idempotency")
    mock_upload = mocker.patch("app.routers.jobs.s3.upload_raw")
    mock_dag = mocker.patch("app.routers.jobs.build_dag")

    files = {"file": ("test.png", b"fake image data", "image/png")}
    data = {"operations": json.dumps(["webp"])}
    headers = {"Idempotency-Key": "demo-idempotency-key"}

    response = await client.post("/api/process", files=files, data=data, headers=headers)
    assert response.status_code == 202
    assert response.json()["job_id"] == existing_job_id
    mock_set.assert_not_called()
    mock_upload.assert_not_called()
    mock_dag.assert_not_called()

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
async def test_create_job_metadata_only_dispatch(client, mocker):
    """Metadata-only jobs should dispatch metadata task without DAG."""
    mock_dag = mocker.patch("app.routers.jobs.build_dag")
    mocker.patch("app.routers.jobs.s3.upload_raw", return_value="raw/test.png")
    mock_sig = MagicMock()
    mock_signature = mocker.patch("app.routers.jobs.celery_app.signature", return_value=mock_sig)

    files = {"file": ("test.png", b"fake image data", "image/png")}
    data = {"operations": json.dumps(["metadata"])}

    response = await client.post("/api/process", files=files, data=data)
    assert response.status_code == 202
    mock_dag.assert_not_called()
    mock_sig.apply_async.assert_called_once()
    _, called_kwargs = mock_signature.call_args
    assert called_kwargs["kwargs"]["mark_completed"] is True


@pytest.mark.asyncio
async def test_create_job_metadata_plus_conversion_dispatch(client, mocker):
    """Mixed jobs should dispatch DAG + metadata task."""
    mock_dag = mocker.patch("app.routers.jobs.build_dag")
    mocker.patch("app.routers.jobs.s3.upload_raw", return_value="raw/test.png")
    mock_sig = MagicMock()
    mock_signature = mocker.patch("app.routers.jobs.celery_app.signature", return_value=mock_sig)

    files = {"file": ("test.png", b"fake image data", "image/png")}
    data = {"operations": json.dumps(["webp", "metadata"])}

    response = await client.post("/api/process", files=files, data=data)
    assert response.status_code == 202
    mock_dag.assert_called_once()
    mock_sig.apply_async.assert_called_once()
    _, called_kwargs = mock_signature.call_args
    assert called_kwargs["kwargs"]["mark_completed"] is False

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


@pytest.mark.asyncio
async def test_get_job_includes_archive_url(client, db_session, mocker):
    """Archive URL should be present when archive key exists in S3."""
    job_id = uuid.uuid4()
    db_session.add(
        Job(
            id=job_id,
            status=JobStatus.COMPLETED,
            operations=["webp"],
            result_urls={},
            result_keys={"webp": "processed/job/webp_abc.webp"},
            webhook_url="",
            s3_raw_key="raw/job/input.png",
            original_filename="photo.png",
            retry_count=0,
        )
    )
    await db_session.commit()

    mocker.patch("app.routers.jobs.s3.object_exists", return_value=True)
    mock_presign = mocker.patch(
        "app.routers.jobs.s3.generate_presigned_url",
        side_effect=["http://result.webp", "http://bundle.zip"],
    )

    response = await client.get(f"/api/jobs/{job_id}")
    assert response.status_code == 200
    data = response.json()
    assert data["archive_url"] == "http://bundle.zip"
    assert data["result_urls"]["webp"] == "http://result.webp"
    assert data["metadata"] == {}
    assert mock_presign.call_count == 2


@pytest.mark.asyncio
async def test_get_job_includes_metadata(client, db_session, mocker):
    """Metadata should be exposed by GET /jobs/{id}."""
    job_id = uuid.uuid4()
    db_session.add(
        Job(
            id=job_id,
            status=JobStatus.COMPLETED,
            operations=["jpg"],
            result_urls={},
            result_keys={"jpg": "processed/job/jpg_abc.jpg"},
            exif_metadata={"camera_make": "Canon", "iso": 400},
            webhook_url="",
            s3_raw_key="raw/job/input.jpg",
            original_filename="photo.jpg",
            retry_count=0,
        )
    )
    await db_session.commit()

    mocker.patch("app.routers.jobs.s3.object_exists", return_value=False)
    mocker.patch("app.routers.jobs.s3.generate_presigned_url", return_value="http://result.jpg")

    response = await client.get(f"/api/jobs/{job_id}")
    assert response.status_code == 200
    data = response.json()
    assert data["metadata"]["camera_make"] == "Canon"
    assert data["metadata"]["iso"] == 400
