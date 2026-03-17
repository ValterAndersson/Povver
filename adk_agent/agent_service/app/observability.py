# app/observability.py
"""Structured logging and tracing for the agent service."""

from __future__ import annotations

import json
import logging
import time
import uuid
from contextvars import ContextVar
from functools import wraps
from typing import Any

# Request-scoped trace ID for log correlation
_trace_id: ContextVar[str] = ContextVar("trace_id", default="")


class StructuredFormatter(logging.Formatter):
    """JSON log formatter for Cloud Logging."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "trace_id": _trace_id.get(""),
        }
        if hasattr(record, "extra_fields"):
            log_entry.update(record.extra_fields)
        return json.dumps(log_entry)


def setup_logging():
    """Configure structured JSON logging."""
    handler = logging.StreamHandler()
    handler.setFormatter(StructuredFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(logging.INFO)


def new_trace_id() -> str:
    """Generate and set a new trace ID for the current request."""
    tid = uuid.uuid4().hex[:16]
    _trace_id.set(tid)
    return tid


def get_trace_id() -> str:
    return _trace_id.get("")


def log_request(user_id: str, conversation_id: str, lane: str, model: str):
    """Log request metadata."""
    logger = logging.getLogger("agent.request")
    logger.info(
        "request_start",
        extra={"extra_fields": {
            "user_id": user_id,
            "conversation_id": conversation_id,
            "lane": lane,
            "model": model,
        }},
    )


def log_tool_call(tool_name: str, elapsed_ms: int, success: bool):
    """Log tool execution."""
    logger = logging.getLogger("agent.tool")
    logger.info(
        "tool_call",
        extra={"extra_fields": {
            "tool": tool_name,
            "elapsed_ms": elapsed_ms,
            "success": success,
        }},
    )


def log_tokens(model: str, input_tokens: int, output_tokens: int):
    """Log token usage."""
    logger = logging.getLogger("agent.tokens")
    logger.info(
        "token_usage",
        extra={"extra_fields": {
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
        }},
    )
