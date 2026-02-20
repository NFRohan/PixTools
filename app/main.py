"""FastAPI application factory."""

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.database import engine
from app.models import Base

logger = logging.getLogger(__name__)

STATIC_DIR = Path(__file__).parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    """Startup / shutdown lifecycle hook."""
    # Create tables (dev only — Alembic handles this in prod)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("Database tables ensured")
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

    # --- Mount static frontend ---
    if STATIC_DIR.exists():
        application.mount(
            "/static", StaticFiles(directory=str(STATIC_DIR)), name="static"
        )

    # --- Health check (minimal, Sprint 5 adds deep checks) ---
    @application.get("/health", tags=["ops"])
    async def health():
        return {"status": "ok"}

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
