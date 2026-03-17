# tests/test_observability.py
import json
import logging
import pytest
from app.observability import (
    StructuredFormatter, setup_logging, new_trace_id,
    get_trace_id, log_request, log_tool_call, log_tokens,
)


def test_new_trace_id_sets_and_returns():
    tid = new_trace_id()
    assert len(tid) == 16
    assert get_trace_id() == tid


def test_structured_formatter_produces_json():
    formatter = StructuredFormatter()
    record = logging.LogRecord(
        name="test", level=logging.INFO, pathname="", lineno=0,
        msg="hello", args=(), exc_info=None,
    )
    output = formatter.format(record)
    parsed = json.loads(output)
    assert parsed["severity"] == "INFO"
    assert parsed["message"] == "hello"
    assert parsed["logger"] == "test"


def test_structured_formatter_includes_extra_fields():
    formatter = StructuredFormatter()
    record = logging.LogRecord(
        name="test", level=logging.INFO, pathname="", lineno=0,
        msg="with_extra", args=(), exc_info=None,
    )
    record.extra_fields = {"user_id": "u1", "model": "gemini"}
    output = formatter.format(record)
    parsed = json.loads(output)
    assert parsed["user_id"] == "u1"
    assert parsed["model"] == "gemini"


def test_log_tokens_does_not_raise():
    """log_tokens should not raise even without setup_logging."""
    log_tokens("gemini-2.5-flash", 100, 50)


def test_log_tool_call_does_not_raise():
    log_tool_call("get_routine", 150, True)


def test_log_request_does_not_raise():
    log_request("u1", "c1", "slow", "gemini-2.5-flash")
