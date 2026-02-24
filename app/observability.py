"""OpenTelemetry and metrics wiring for API + Celery runtimes."""

import logging

from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.celery import CeleryInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_fastapi_instrumentator import Instrumentator

from app.config import settings

logger = logging.getLogger(__name__)

_api_instrumented = False
_celery_instrumented = False
_httpx_instrumented = False


def _init_tracing(service_name: str) -> None:
    """Configure OTLP trace exporter for the current process."""
    endpoint = f"{settings.otel_exporter_otlp_endpoint.rstrip('/')}/v1/traces"
    resource = Resource.create({"service.name": service_name})
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=endpoint)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    logger.info("OpenTelemetry tracing enabled for %s", service_name)


def setup_api_observability(app: FastAPI) -> None:
    """Attach tracing + metrics instrumentation to FastAPI app."""
    global _api_instrumented, _httpx_instrumented

    if settings.observability_enabled and not _api_instrumented:
        _init_tracing(settings.otel_service_name_api)
        FastAPIInstrumentor.instrument_app(app)
        if not _httpx_instrumented:
            HTTPXClientInstrumentor().instrument()
            _httpx_instrumented = True
        _api_instrumented = True

    if settings.metrics_enabled:
        if not any(getattr(route, "path", None) == "/metrics" for route in app.routes):
            Instrumentator().instrument(app).expose(
                app,
                endpoint="/metrics",
                include_in_schema=False,
            )
            logger.info("Prometheus /metrics endpoint exposed")


def setup_celery_observability() -> None:
    """Attach tracing instrumentation for Celery workers."""
    global _celery_instrumented

    if not settings.observability_enabled or _celery_instrumented:
        return

    _init_tracing(settings.otel_service_name_worker)
    CeleryInstrumentor().instrument()
    _celery_instrumented = True
