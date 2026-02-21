"""FastAPI application factory."""

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.database import engine
from app.models import Base
from app.logging_config import setup_logging, request_id_ctx

# Initialize structured logging globally
setup_logging()

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

    # --- Middleware ---
    from fastapi import Request
    import uuid

    @application.middleware("http")
    async def request_id_middleware(request: Request, call_next):
        """Extracts or generates X-Request-ID for log correlation."""
        rid = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        token = request_id_ctx.set(rid)
        try:
            response = await call_next(request)
            response.headers["X-Request-ID"] = rid
            return response
        finally:
            request_id_ctx.reset(token)

    # --- Register routers ---
    from app.routers.jobs import router as jobs_router
    from app.routers.health import router as health_router

    application.include_router(jobs_router, prefix="/api")
    application.include_router(health_router, prefix="/api")

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
