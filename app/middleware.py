"""Application middleware registration."""

from time import perf_counter
import uuid

from fastapi import FastAPI, Request

from app.logging_config import request_id_ctx
from app.metrics import api_request_latency_seconds, refresh_queue_depth_metrics


def _route_template(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", request.url.path)


def register_request_id_middleware(app: FastAPI) -> None:
    """Attach request correlation middleware to the FastAPI app."""

    @app.middleware("http")
    async def request_id_middleware(request: Request, call_next):
        rid = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        token = request_id_ctx.set(rid)
        try:
            response = await call_next(request)
            response.headers["X-Request-ID"] = rid
            return response
        finally:
            request_id_ctx.reset(token)


def register_request_metrics_middleware(app: FastAPI) -> None:
    """Attach request latency middleware and on-scrape queue metric refresh."""

    @app.middleware("http")
    async def request_metrics_middleware(request: Request, call_next):
        # Keep queue depth gauges current for each /metrics scrape.
        if request.url.path == "/metrics":
            refresh_queue_depth_metrics()

        start = perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            latency = perf_counter() - start
            api_request_latency_seconds.labels(
                method=request.method,
                path=_route_template(request),
                status_code=str(status_code),
            ).observe(latency)
