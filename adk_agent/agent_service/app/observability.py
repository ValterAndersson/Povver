# app/observability.py
"""Structured logging and tracing for the agent service."""

from __future__ import annotations

import json
import logging
import time
import uuid
from contextlib import contextmanager
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


def set_trace_id(tid: str) -> None:
    """Set trace_id ContextVar explicitly — use inside async generators
    where the ContextVar from the parent coroutine may not propagate."""
    _trace_id.set(tid)


def get_trace_id() -> str:
    return _trace_id.get("")


@contextmanager
def timed_section(section_name: str):
    """Context manager that logs elapsed time for a named section.

    Usage:
        with timed_section("context_build"):
            result = await build_system_context(...)
    Emits: {"message": "section_complete", "section": "context_build", "elapsed_ms": 142}
    """
    start = time.monotonic()
    yield
    elapsed_ms = int((time.monotonic() - start) * 1000)
    logger = logging.getLogger("agent.timing")
    logger.info(
        "section_complete",
        extra={"extra_fields": {
            "section": section_name,
            "elapsed_ms": elapsed_ms,
        }},
    )


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


def log_request_complete(
    lane: str, elapsed_ms: int, success: bool, tool_count: int = 0, error: str = ""
):
    """Log request completion with total elapsed time."""
    logger = logging.getLogger("agent.request")
    fields: dict[str, Any] = {
        "lane": lane,
        "elapsed_ms": elapsed_ms,
        "success": success,
        "tool_count": tool_count,
    }
    if error:
        fields["error"] = error
    level = logging.INFO if success else logging.ERROR
    logger.log(
        level,
        "request_complete",
        extra={"extra_fields": fields},
    )


def log_tool_call(
    tool_name: str, elapsed_ms: int, success: bool, error: str = ""
):
    """Log tool execution with timing and success/failure."""
    logger = logging.getLogger("agent.tool")
    fields: dict[str, Any] = {
        "tool": tool_name,
        "elapsed_ms": elapsed_ms,
        "success": success,
    }
    if error:
        fields["error"] = error
    level = logging.INFO if success else logging.WARNING
    logger.log(
        level,
        "tool_call",
        extra={"extra_fields": fields},
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


def log_tools_available(tool_names: list[str], workout_mode: bool):
    """Log which tools are available for this request."""
    logger = logging.getLogger("agent.tools")
    logger.info(
        "tools_available",
        extra={"extra_fields": {
            "tools": tool_names,
            "count": len(tool_names),
            "workout_mode": workout_mode,
        }},
    )
