"""Application middleware registration."""

import uuid

from fastapi import FastAPI, Request

from app.logging_config import request_id_ctx


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
