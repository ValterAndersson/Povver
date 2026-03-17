# tests/test_sse_contract.py
"""SSE protocol contract tests.

These tests verify that the agent service's SSE output matches
what the Firebase proxy (stream-agent-normalized.js) expects to parse.
The proxy reads event.type from the JSON data payload, NOT from
the SSE event: line. If these tests break, iOS will stop receiving events.

This was the source of CRITICAL bug #1 in the architecture redesign review.

The proxy's relayCloudRunStream does:
    const parsed = JSON.parse(dataStr);
    const eventType = parsed.type;   // <-- reads from JSON payload
    ...emit to iOS via SSE...

So every SSE event MUST have {"type": "<event_name>", ...} in its data field.
If `type` is missing or nested under a sub-key, iOS receives nothing.
"""

import json
import pytest
from app.agent_loop import sse_event, SSEEvent


# ---------------------------------------------------------------------------
# Helper: simulate what the Firebase proxy does when parsing SSE
# ---------------------------------------------------------------------------

def parse_sse_wire_format(encoded: str) -> dict:
    """Parse encoded SSE wire format and extract the JSON data payload.

    This simulates what relayCloudRunStream in stream-agent-normalized.js
    does: split on newlines, find the `data:` line, JSON.parse it, read `.type`.
    """
    lines = encoded.strip().split("\n")
    event_line = None
    data_line = None
    for line in lines:
        if line.startswith("event: "):
            event_line = line[len("event: "):]
        if line.startswith("data: "):
            data_line = line[len("data: "):]
    assert event_line is not None, "SSE must have an event: line"
    assert data_line is not None, "SSE must have a data: line"
    parsed = json.loads(data_line)
    return {"sse_event_type": event_line, "data": parsed}


# ---------------------------------------------------------------------------
# Contract: every event type has `type` at the top level of JSON data
# ---------------------------------------------------------------------------

class TestSSEEventTypeField:
    """Every SSE event's JSON data must include a top-level `type` field
    matching the event name. The Firebase proxy uses this to route events."""

    def test_message_event(self):
        evt = sse_event("message", "hello")
        data = json.loads(evt.data)
        assert data["type"] == "message"
        assert data["text"] == "hello"

    def test_tool_start_event(self):
        evt = sse_event("tool_start", {"tool": "search_exercises", "call_id": "abc"})
        data = json.loads(evt.data)
        assert data["type"] == "tool_start"
        assert data["tool"] == "search_exercises"
        assert data["call_id"] == "abc"

    def test_tool_end_event(self):
        evt = sse_event("tool_end", {
            "tool": "search_exercises",
            "call_id": "abc",
            "elapsed_ms": 150,
        })
        data = json.loads(evt.data)
        assert data["type"] == "tool_end"
        assert data["tool"] == "search_exercises"
        assert data["call_id"] == "abc"
        assert data["elapsed_ms"] == 150

    def test_done_event(self):
        evt = sse_event("done", {})
        data = json.loads(evt.data)
        assert data["type"] == "done"

    def test_error_event(self):
        evt = sse_event("error", {"code": "AGENT_ERROR", "message": "boom"})
        data = json.loads(evt.data)
        assert data["type"] == "error"
        assert data["code"] == "AGENT_ERROR"
        assert data["message"] == "boom"

    def test_status_event(self):
        evt = sse_event("status", {"text": "Loading..."})
        data = json.loads(evt.data)
        assert data["type"] == "status"
        assert data["text"] == "Loading..."

    def test_artifact_event(self):
        evt = sse_event("artifact", {
            "artifact_type": "routine",
            "artifact_id": "r1",
            "artifact_content": {"name": "Push Pull Legs"},
            "actions": [{"label": "Save", "action": "save_routine"}],
            "status": "proposed",
        })
        data = json.loads(evt.data)
        assert data["type"] == "artifact"
        assert data["artifact_type"] == "routine"
        assert data["artifact_id"] == "r1"
        assert data["artifact_content"] == {"name": "Push Pull Legs"}
        assert len(data["actions"]) == 1
        assert data["status"] == "proposed"

    def test_heartbeat_event(self):
        evt = sse_event("heartbeat", {})
        data = json.loads(evt.data)
        assert data["type"] == "heartbeat"


# ---------------------------------------------------------------------------
# Contract: fields are at the TOP LEVEL, not nested under `data`
# ---------------------------------------------------------------------------

class TestSSEFieldsTopLevel:
    """All fields must be at the top level of the JSON payload.
    The proxy and iOS client read fields directly (e.g., parsed.text,
    parsed.tool, parsed.code). Nesting under a `data` sub-key would break parsing.

    The sse_event() function spreads dict data with {type: event, **data}.
    This test catches regressions where data gets wrapped instead of spread."""

    def test_dict_fields_are_spread_not_nested(self):
        evt = sse_event("tool_start", {"tool": "search_exercises", "call_id": "abc"})
        data = json.loads(evt.data)
        # Fields must be at top level
        assert "tool" in data
        assert "call_id" in data
        # Must NOT be nested under a 'data' key
        assert "data" not in data or not isinstance(data.get("data"), dict)

    def test_string_data_becomes_text_field(self):
        evt = sse_event("message", "hello world")
        data = json.loads(evt.data)
        assert data["text"] == "hello world"
        # String data should NOT end up as a nested 'data' field
        assert data.get("data") != "hello world"

    def test_error_fields_at_top_level(self):
        evt = sse_event("error", {"code": "RATE_LIMIT", "message": "slow down"})
        data = json.loads(evt.data)
        assert data["code"] == "RATE_LIMIT"
        assert data["message"] == "slow down"


# ---------------------------------------------------------------------------
# Contract: SSE wire format is valid
# ---------------------------------------------------------------------------

class TestSSEWireFormat:
    """The .encode() method must produce valid SSE wire format:
    event: {type}\\ndata: {json}\\n\\n

    Malformed wire format would cause the browser/HTTP client EventSource
    parser to silently drop events."""

    def test_encode_format(self):
        evt = sse_event("message", "hello")
        encoded = evt.encode()
        # Must start with event: line
        assert encoded.startswith("event: message\n")
        # Must have data: line with valid JSON
        assert "\ndata: " in encoded
        # Must end with double newline (SSE record separator)
        assert encoded.endswith("\n\n")

    def test_encode_preserves_event_type(self):
        for event_type in ["message", "tool_start", "tool_end", "done",
                           "error", "status", "artifact", "heartbeat"]:
            evt = sse_event(event_type, {})
            encoded = evt.encode()
            assert encoded.startswith(f"event: {event_type}\n"), (
                f"Event type '{event_type}' not preserved in SSE event: line"
            )


# ---------------------------------------------------------------------------
# Contract: proxy event type extraction (end-to-end simulation)
# ---------------------------------------------------------------------------

class TestProxyEventExtraction:
    """Simulate the full path: sse_event() -> .encode() -> parse SSE ->
    extract data: line -> JSON.parse -> read .type.

    This is the exact flow that relayCloudRunStream follows. If this test
    passes, the proxy will correctly identify the event type."""

    @pytest.mark.parametrize("event_type,payload", [
        ("message", "hello"),
        ("tool_start", {"tool": "search_exercises", "call_id": "abc"}),
        ("tool_end", {"tool": "search_exercises", "call_id": "abc", "elapsed_ms": 150}),
        ("done", {}),
        ("error", {"code": "AGENT_ERROR", "message": "boom"}),
        ("status", {"text": "Loading..."}),
        ("artifact", {"artifact_type": "routine", "artifact_id": "r1",
                       "artifact_content": {}, "actions": [], "status": "proposed"}),
        ("heartbeat", {}),
    ])
    def test_proxy_extracts_correct_event_type(self, event_type, payload):
        evt = sse_event(event_type, payload)
        encoded = evt.encode()
        parsed = parse_sse_wire_format(encoded)

        # The SSE event: line should match
        assert parsed["sse_event_type"] == event_type

        # The JSON data.type field should match (this is what the proxy reads)
        assert parsed["data"]["type"] == event_type, (
            f"Proxy would read type='{parsed['data'].get('type')}' "
            f"but expected '{event_type}'. "
            f"This means iOS will not receive this event correctly."
        )

    def test_proxy_can_parse_all_data_fields(self):
        """Verify the proxy can access all fields it needs from tool_start events.
        The iOS client reads tool and call_id to show tool execution status."""
        evt = sse_event("tool_start", {"tool": "get_training_context", "call_id": "x1"})
        parsed = parse_sse_wire_format(evt.encode())
        data = parsed["data"]
        assert data["tool"] == "get_training_context"
        assert data["call_id"] == "x1"


# ---------------------------------------------------------------------------
# Contract: SSEEvent dataclass
# ---------------------------------------------------------------------------

class TestSSEEventDataclass:
    """SSEEvent is a simple dataclass with event and data fields.
    Downstream code depends on these field names."""

    def test_sse_event_has_event_field(self):
        evt = sse_event("message", "hi")
        assert hasattr(evt, "event")
        assert evt.event == "message"

    def test_sse_event_has_data_field(self):
        evt = sse_event("message", "hi")
        assert hasattr(evt, "data")
        assert isinstance(evt.data, str)

    def test_sse_event_data_is_valid_json(self):
        evt = sse_event("tool_end", {"tool": "x", "call_id": "y", "elapsed_ms": 100})
        parsed = json.loads(evt.data)
        assert isinstance(parsed, dict)
