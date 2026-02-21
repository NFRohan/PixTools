import asyncio
import os

import boto3
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from moto import mock_aws
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker

import app.services.s3 as s3_service
from app.config import settings
from app.database import get_db
from app.main import create_app
from app.models import Base

# Use a file-based sqlite for sharing between sync/async connections
TEST_DB_FILE = "test_pixtools.db"
TEST_DATABASE_URL = f"sqlite+aiosqlite:///{TEST_DB_FILE}"

@pytest.fixture(scope="session", autouse=True)
def setup_test_db():
    """Create a clean test database file for the session."""
    if os.path.exists(TEST_DB_FILE):
        os.remove(TEST_DB_FILE)
    yield
    if os.path.exists(TEST_DB_FILE):
        os.remove(TEST_DB_FILE)

@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()

@pytest_asyncio.fixture(scope="session")
async def test_engine(setup_test_db):
    engine = create_async_engine(TEST_DATABASE_URL, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()

@pytest_asyncio.fixture
async def db_session(test_engine):
    async_session = sessionmaker(
        test_engine, class_=AsyncSession, expire_on_commit=False
    )
    async with async_session() as session:
        yield session
        await session.rollback()

@pytest_asyncio.fixture
async def client(db_session):
    app = create_app()
    async def override_get_db():
        yield db_session
    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac

@pytest.fixture(autouse=True)
def mock_settings(monkeypatch):
    """Ensure tests don't touch real infrastructure."""
    monkeypatch.setattr(settings, "aws_s3_bucket", "test-bucket")
    monkeypatch.setattr(settings, "database_url", TEST_DATABASE_URL)
    monkeypatch.setattr(settings, "redis_url", "redis://localhost:6379/1")
    monkeypatch.setattr(settings, "aws_endpoint_url", None)

    # Clear S3 client cache to ensure it picks up mock settings
    monkeypatch.setattr(s3_service, "_s3_client", None)
    return settings

@pytest.fixture
def s3_mock(mock_settings):
    with mock_aws():
        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket=mock_settings.aws_s3_bucket)
        yield s3

@pytest.fixture(autouse=True)
def patch_s3_client(s3_mock, monkeypatch):
    """Force the S3 service to use our mocked client instance."""
    monkeypatch.setattr(s3_service, "_get_client", lambda: s3_mock)
    monkeypatch.setattr(s3_service, "_s3_client", s3_mock)
