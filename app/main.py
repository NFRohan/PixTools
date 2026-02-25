"""FastAPI application factory."""

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.database import engine
from app.logging_config import setup_logging
from app.middleware import register_request_id_middleware, register_request_metrics_middleware
from app.models import Base
from app.observability import setup_api_observability

# Initialize structured logging globally
setup_logging()

logger = logging.getLogger(__name__)

STATIC_DIR = Path(__file__).parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    """Startup / shutdown lifecycle hook."""
    # For sqlite local development, auto-create tables.
    # For Postgres deployments, rely on Alembic migrations.
    if settings.database_url.startswith("sqlite"):
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        logger.info("Database tables ensured (sqlite auto-create)")
    else:
        logger.info("Skipping metadata.create_all for non-sqlite database")

    # Ensure S3 bucket and lifecycle policies are set up
    from app.services.s3 import _get_client

    _get_client()
    logger.info("S3 bucket and lifecycle policies ensured")
    yield
    await engine.dispose()
    logger.info("Database engine disposed")


def create_app() -> FastAPI:
    """Build and return the FastAPI application instance."""
    application = FastAPI(
        title="PixTools",
        description="Hybrid-cloud distributed image processing pipeline",
        version="0.1.0",
        lifespan=lifespan,
    )

    # --- Middleware ---
    register_request_id_middleware(application)
    register_request_metrics_middleware(application)

    # --- Register routers ---
    from app.routers.health import router as health_router
    from app.routers.jobs import router as jobs_router

    application.include_router(jobs_router, prefix="/api")
    application.include_router(health_router, prefix="/api")

    # --- Observability ---
    setup_api_observability(application)

    # --- Mount static frontend ---
    if STATIC_DIR.exists():
        application.mount(
            "/static", StaticFiles(directory=str(STATIC_DIR)), name="static"
        )

    # --- Root redirect to frontend ---
    from fastapi.responses import FileResponse

    @application.get("/", include_in_schema=False)
    async def root():
        index = STATIC_DIR / "index.html"
        if index.exists():
            return FileResponse(str(index))
        return {"message": "PixTools API", "docs": "/docs"}

    return application


app = create_app()
