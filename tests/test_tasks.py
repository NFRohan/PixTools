from unittest.mock import MagicMock, patch

import pytest
from PIL import Image

from app.models import Job, JobStatus
from app.tasks.image_ops import convert_webp


@pytest.fixture
def mock_image():
    """Generates a valid PIL image for testing."""
    return Image.new("RGB", (10, 10), color="red")

def test_convert_webp_logic(mock_image):
    """Test the image conversion logic without real S3."""
    job_id = "test-job"
    s3_key = "raw/test.png"
    params = {"quality": 72, "resize": {"width": 8}}

    with patch("app.tasks.image_ops.download_raw", return_value=mock_image) as mock_dl, \
         patch("app.tasks.image_ops.upload_processed", return_value="processed/test.webp") as mock_ul:

        result = convert_webp(job_id, s3_key, params)

        assert result == "processed/test.webp"
        mock_dl.assert_called_once()
        mock_ul.assert_called_once()

        # Verify it was saved as WEBP
        args, kwargs = mock_ul.call_args
        assert args[3] == "WEBP" # fmt argument
        assert kwargs["save_kwargs"]["quality"] == 72

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
         patch("app.tasks.finalize.notify_job_update"), \
         patch("app.tasks.finalize.celery_app.signature") as mock_signature:

        mock_session = MagicMock()
        mock_session_cls.return_value.__enter__.return_value = mock_session

        mock_job = MagicMock(spec=Job)
        mock_job.original_filename = "test.png"
        mock_job.webhook_url = "http://webhook.site"
        mock_job.status = JobStatus.PENDING
        mock_session.get.return_value = mock_job

        # Mock archive dispatch signature
        mock_sig = MagicMock()
        mock_signature.return_value = mock_sig

        # Manual run of the task
        from app.tasks.finalize import finalize_job
        res = finalize_job(results, job_id)

        assert res["status"] == "COMPLETED"
        assert "webp" in res["result_urls"]
        assert mock_job.status == JobStatus.COMPLETED
        mock_session.commit.assert_called_once()
        assert mock_signature.call_count == 1
        assert mock_sig.apply_async.call_count == 1


def test_bundle_results_logic():
    """Test ZIP bundling task logic without real S3."""
    result_keys = {
        "webp": "processed/job/webp_abc.webp",
        "png": "processed/job/png_xyz.png",
    }

    with patch("app.tasks.archive.s3.download_object_bytes", return_value=b"file-bytes") as mock_dl, \
         patch("app.tasks.archive.s3.upload_archive_bytes", return_value="archives/job/bundle.zip") as mock_ul:
        from app.tasks.archive import bundle_results

        archive_key = bundle_results("job-123", result_keys, "sample.png")

        assert archive_key == "archives/job/bundle.zip"
        assert mock_dl.call_count == 2
        mock_ul.assert_called_once()


def test_extract_metadata_logic():
    """EXIF task should persist parsed metadata to the job row."""
    with patch("app.tasks.metadata.download_raw") as mock_download, \
         patch("app.tasks.metadata.Session") as mock_session_cls:
        from app.tasks.metadata import extract_metadata

        mock_img = MagicMock()
        mock_img.getexif.return_value = {}
        mock_download.return_value = mock_img

        mock_session = MagicMock()
        mock_session_cls.return_value.__enter__.return_value = mock_session
        mock_job = MagicMock(spec=Job)
        mock_session.get.return_value = mock_job

        result = extract_metadata("job-123", "raw/job/input.jpg")

        assert result == {}
        assert mock_job.exif_metadata == {}
        mock_session.commit.assert_called_once()


def test_extract_metadata_mark_completed_logic():
    """Metadata-only completion should mark job completed."""
    with patch("app.tasks.metadata.download_raw") as mock_download, \
         patch("app.tasks.metadata.Session") as mock_session_cls:
        from app.tasks.metadata import extract_metadata

        mock_img = MagicMock()
        mock_img.getexif.return_value = {}
        mock_download.return_value = mock_img

        mock_session = MagicMock()
        mock_session_cls.return_value.__enter__.return_value = mock_session
        mock_job = MagicMock(spec=Job)
        mock_job.result_urls = None
        mock_job.result_keys = None
        mock_job.webhook_url = ""
        mock_job.status = JobStatus.PENDING
        mock_session.get.return_value = mock_job

        result = extract_metadata("job-123", "raw/job/input.jpg", mark_completed=True)

        assert result == {}
        assert mock_job.status == JobStatus.COMPLETED
        assert mock_job.result_urls == {}
        assert mock_job.result_keys == {}


def test_gps_parser_handles_non_dict():
    """GPS parser should tolerate non-dict GPSInfo values."""
    from app.tasks.metadata import _gps_to_decimal

    assert _gps_to_decimal(12345) is None
