# test_gemini_backend.py
import pytest
from comparative.backends.gemini_backend import parse_sse_events


def test_parse_message_events():
    lines = [
        'event: message',
        'data: {"type": "message", "text": "Your bench"}',
        '',
        'event: message',
        'data: {"type": "message", "text": " is progressing."}',
        '',
        'event: done',
        'data: {"type": "done"}',
        '',
    ]
    text, tools = parse_sse_events(lines)
    assert text == "Your bench is progressing."
    assert tools == []


def test_parse_tool_events():
    lines = [
        'event: tool_start',
        'data: {"type": "tool_start", "tool": "tool_get_exercise_progress", "call_id": "c1"}',
        '',
        'event: tool_end',
        'data: {"type": "tool_end", "tool": "tool_get_exercise_progress", "call_id": "c1", "elapsed_ms": 300}',
        '',
        'event: message',
        'data: {"type": "message", "text": "Bench is up 5%."}',
        '',
        'event: done',
        'data: {"type": "done"}',
        '',
    ]
    text, tools = parse_sse_events(lines)
    assert text == "Bench is up 5%."
    assert tools == ["tool_get_exercise_progress"]


def test_parse_error_event():
    lines = [
        'event: error',
        'data: {"type": "error", "code": "TIMEOUT", "message": "Request timed out"}',
        '',
    ]
    text, tools = parse_sse_events(lines)
    assert "timed out" in text.lower() or "error" in text.lower()
