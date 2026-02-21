from io import BytesIO
from unittest.mock import MagicMock, patch

import pytest
from PIL import Image

from app.models import Job, JobStatus
from app.tasks.image_ops import convert_webp


@pytest.fixture
def mock_image_bytes():
    """Generates valid PNG bytes for testing."""
    img = Image.new("RGB", (10, 10), color="red")
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()

def test_convert_webp_logic(mock_image_bytes):
    """Test the image conversion logic without real S3."""
    job_id = "test-job"
    s3_key = "raw/test.png"

    with patch("app.tasks.image_ops.download_raw", return_value=mock_image_bytes) as mock_dl, \
         patch("app.tasks.image_ops.upload_processed", return_value="processed/test.webp") as mock_ul:

        result = convert_webp(job_id, s3_key)

        assert result == "processed/test.webp"
        mock_dl.assert_called_once()
        mock_ul.assert_called_once()

        # Verify it was saved as WEBP
        args, kwargs = mock_ul.call_args
        assert args[3] == "WEBP" # fmt argument

def test_finalize_job_logic(db_session):
    """Test the job finalization logic and DB updates."""
    # Celery tasks use sync engines, but our test session is async.
    # We will mock the DB interactions in finalize_job to test the logic flow.
    job_id = "test-final-job"
    results = ["processed/webp_random.webp"]

    # 1. Prepare job in mock DB (conftest uses sqlite which is fine)
    # Note: finalize_job uses its own internal sync session.
    # For this test, we'll patch the Session in finalize.py

    with patch("app.tasks.finalize.Session") as mock_session_cls, \
         patch("app.tasks.finalize.generate_presigned_url", return_value="http://presigned.url"), \
         patch("app.tasks.finalize.notify_job_update"):

        mock_session = MagicMock()
        mock_session_cls.return_value.__enter__.return_value = mock_session

        mock_job = MagicMock(spec=Job)
        mock_job.original_filename = "test.png"
        mock_job.webhook_url = "http://webhook.site"
        mock_job.status = JobStatus.PENDING
        mock_session.get.return_value = mock_job

        # Manual run of the task
        from app.tasks.finalize import finalize_job
        res = finalize_job(results, job_id)

        assert res["status"] == "COMPLETED"
        assert "webp" in res["result_urls"]
        assert mock_job.status == JobStatus.COMPLETED
        mock_session.commit.assert_called_once()
