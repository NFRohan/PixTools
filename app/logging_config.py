import logging
import sys
from contextvars import ContextVar

from pythonjsonlogger import jsonlogger

# Context variables to store correlation IDs
request_id_ctx: ContextVar[str] = ContextVar("request_id", default="N/A")
job_id_ctx: ContextVar[str] = ContextVar("job_id", default="N/A")

class CorrelationIdFilter(logging.Filter):
    """Filter that injects request_id and job_id from context into log records."""
    def filter(self, record):
        record.request_id = request_id_ctx.get()
        record.job_id = job_id_ctx.get()
        return True

def setup_logging():
    """Configure structured JSON logging for both FastAPI and Celery."""
    log_handler = logging.StreamHandler(sys.stdout)

    # Define JSON format (mapped from standard logging fields)
    # Using 'json' style allows us to rename keys directly in the record
    formatter = jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s %(request_id)s %(job_id)s",
        rename_fields={"levelname": "level", "asctime": "timestamp"},
        datefmt="%Y-%m-%dT%H:%M:%SZ"
    )
    log_handler.setFormatter(formatter)

    # Root logger configuration
    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)

    # Remove existing handlers (to avoid duplicate logs from Uvicorn/FastAPI defaults)
    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)

    root_logger.addHandler(log_handler)
    root_logger.addFilter(CorrelationIdFilter())

    # Quiet down noisy third-party libraries
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)
    logging.getLogger("pydantic").setLevel(logging.WARNING)

    logging.info("Logging configured with JSON structure and ContextVars correlation")
