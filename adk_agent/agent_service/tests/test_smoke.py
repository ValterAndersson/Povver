# tests/test_smoke.py
"""Pre-deploy smoke tests — verify real integration boundaries.

Run against a live service (local or Cloud Run):
    SMOKE_URL=http://localhost:8080 python3 -m pytest tests/test_smoke.py -v
    SMOKE_URL=https://agent-service-xxx.run.app python3 -m pytest tests/test_smoke.py -v

These tests verify the exact boundary bugs that unit tests miss because
they mock the boundaries. Each test targets a specific integration point.

Requires:
- SMOKE_URL: Base URL of the agent service
- SMOKE_USER_ID: A real Firestore user ID with profile data
- MYON_API_KEY: API key for tool calls to Firebase Functions
"""

from __future__ import annotations

import json
import os
import time

import httpx
import pytest

SMOKE_URL = os.getenv("SMOKE_URL", "")
SMOKE_USER_ID = os.getenv("SMOKE_USER_ID", "")
MYON_API_KEY = os.getenv("MYON_API_KEY", "")

pytestmark = pytest.mark.skipif(
    not SMOKE_URL, reason="SMOKE_URL not set — skipping smoke tests"
)


def parse_sse_events(text: str) -> list[dict]:
    """Parse SSE text into list of event dicts."""
    events = []
    for block in text.strip().split("\n\n"):
        lines = block.strip().split("\n")
        data_line = None
        for line in lines:
            if line.startswith("data: "):
                data_line = line[6:]
        if data_line:
            try:
                events.append(json.loads(data_line))
            except json.JSONDecodeError:
                pass
    return events


class TestHealthCheck:
    """Verify the service is up and dependencies are reachable."""

    def test_basic_health(self):
        resp = httpx.get(f"{SMOKE_URL}/health", timeout=5.0)
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_deep_health(self):
        """Verify Firestore connectivity from Cloud Run."""
        resp = httpx.get(f"{SMOKE_URL}/health?deep=1", timeout=10.0)
        data = resp.json()
        assert resp.status_code == 200, f"Deep health failed: {data}"
        assert data["checks"]["firestore"] == "ok"


class TestSSEStreamContract:
    """Verify the SSE stream produces valid events with correct shape."""

    @pytest.fixture
    def simple_request(self):
        return {
            "user_id": SMOKE_USER_ID or "smoke-test-user",
            "conversation_id": f"smoke-{int(time.time())}",
            "message": "Say hello in one sentence.",
            "correlation_id": f"smoke-trace-{int(time.time())}",
        }

    def test_stream_returns_sse_content_type(self, simple_request):
        resp = httpx.post(
            f"{SMOKE_URL}/stream",
            json=simple_request,
            timeout=30.0,
        )
        assert resp.status_code == 200
        assert "text/event-stream" in resp.headers.get("content-type", "")

    def test_stream_returns_trace_id(self, simple_request):
        resp = httpx.post(
            f"{SMOKE_URL}/stream",
            json=simple_request,
            timeout=30.0,
        )
        trace_id = resp.headers.get("x-trace-id", "")
        assert trace_id, "X-Trace-Id header missing from response"
        assert trace_id == simple_request["correlation_id"]

    def test_stream_has_message_and_done(self, simple_request):
        """Every valid stream must end with a done event."""
        resp = httpx.post(
            f"{SMOKE_URL}/stream",
            json=simple_request,
            timeout=60.0,
        )
        events = parse_sse_events(resp.text)
        event_types = [e.get("type") for e in events]

        assert "done" in event_types, f"No done event. Got types: {event_types}"
        # Should have at least one message or error
        assert any(t in event_types for t in ("message", "error")), (
            f"No message or error event. Got types: {event_types}"
        )

    def test_every_event_has_type_field(self, simple_request):
        """Contract: every SSE data payload must contain a 'type' field."""
        resp = httpx.post(
            f"{SMOKE_URL}/stream",
            json=simple_request,
            timeout=60.0,
        )
        events = parse_sse_events(resp.text)
        for i, evt in enumerate(events):
            assert "type" in evt, f"Event {i} missing 'type': {evt}"

    def test_validation_rejects_missing_fields(self):
        resp = httpx.post(
            f"{SMOKE_URL}/stream",
            json={"user_id": "x"},  # missing conversation_id and message
            timeout=5.0,
        )
        assert resp.status_code == 400


@pytest.mark.skipif(
    not SMOKE_USER_ID, reason="SMOKE_USER_ID not set — skipping profile tests"
)
class TestContextBuild:
    """Verify context building works with real Firestore data."""

    def test_tool_call_flow(self):
        """Send a message that should trigger tool use and verify tool events."""
        resp = httpx.post(
            f"{SMOKE_URL}/stream",
            json={
                "user_id": SMOKE_USER_ID,
                "conversation_id": f"smoke-tools-{int(time.time())}",
                "message": "What does my current routine look like?",
                "correlation_id": f"smoke-tools-{int(time.time())}",
            },
            timeout=120.0,
        )
        events = parse_sse_events(resp.text)
        event_types = [e.get("type") for e in events]

        # Should complete without error
        assert "error" not in event_types, (
            f"Got error: {[e for e in events if e.get('type') == 'error']}"
        )
        assert "done" in event_types

        # Should have used at least one tool (planning context is auto-loaded,
        # but the LLM should call get_planning_context or similar)
        has_tool = "tool_start" in event_types or "status" in event_types
        if has_tool:
            # Verify tool events come in pairs
            starts = [e for e in events if e.get("type") == "tool_start"]
            ends = [e for e in events if e.get("type") == "tool_end"]
            assert len(starts) == len(ends), (
                f"Mismatched tool events: {len(starts)} starts, {len(ends)} ends"
            )


@pytest.mark.skipif(
    not MYON_API_KEY, reason="MYON_API_KEY not set — skipping API key tests"
)
class TestAPIKeyAuth:
    """Verify API key auth works for tool calls to Firebase Functions."""

    def test_api_key_accepted(self):
        """Direct call to a Firebase Function with API key — same path tools use."""
        functions_url = os.getenv(
            "MYON_FUNCTIONS_BASE_URL",
            "https://us-central1-myon-53d85.cloudfunctions.net",
        )
        resp = httpx.get(
            f"{functions_url}/getActiveWorkout",
            params={"workout_id": "nonexistent"},
            headers={
                "x-api-key": MYON_API_KEY,
                "x-user-id": SMOKE_USER_ID or "smoke-test",
            },
            timeout=10.0,
        )
        # We expect 404 or a valid response — NOT 403 (auth failure)
        assert resp.status_code != 403, (
            f"API key rejected by Firebase Functions (403). "
            f"Tool calls will fail in production."
        )
