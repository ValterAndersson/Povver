# tests/test_skills/test_copilot_skills.py
"""Tests for copilot_skills — Fast Lane HTTP skills."""

import asyncio
import json

import httpx

from app.context import RequestContext
from app.http_client import FunctionsClient
from app.skills.copilot_skills import (
    get_next_set,
    log_set,
    log_set_shorthand,
    parse_shorthand,
)


def _run(coro):
    return asyncio.run(coro)


def _ctx(**overrides):
    defaults = {
        "user_id": "u1",
        "conversation_id": "c1",
        "correlation_id": "r1",
        "workout_id": "w1",
        "workout_mode": True,
    }
    defaults.update(overrides)
    return RequestContext(**defaults)


def _make_client(handler) -> FunctionsClient:
    client = FunctionsClient(base_url="http://test", api_key="test-key")
    client._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return client


def test_log_set_posts_correct_payload(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"success": True, "totals": {"sets": 3}}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.copilot_skills.get_functions_client", lambda: mock_client)

    async def _test():
        return await log_set(
            ctx=_ctx(),
            exercise_instance_id="ex1",
            set_id="s1",
            reps=8,
            weight_kg=100.0,
            rir=1,
        )

    result = _run(_test())
    assert result["success"] is True

    payload = captured["body"]
    assert payload["workout_id"] == "w1"
    assert payload["exercise_instance_id"] == "ex1"
    assert payload["set_id"] == "s1"
    assert payload["values"]["reps"] == 8
    assert payload["values"]["weight"] == 100.0
    assert payload["values"]["rir"] == 1
    assert "idempotency_key" in payload


def test_log_set_shorthand_calls_complete_current_set(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {"success": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.copilot_skills.get_functions_client", lambda: mock_client)

    async def _test():
        return await log_set_shorthand(ctx=_ctx(), reps=8, weight_kg=100.0)

    result = _run(_test())
    assert result["success"] is True
    assert "completeCurrentSet" in captured["url"]


def test_get_next_set_calls_get_active_workout(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["method"] = request.method
        return httpx.Response(200, json={"data": {"success": True, "workout": {"exercises": []}}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.copilot_skills.get_functions_client", lambda: mock_client)

    async def _test():
        return await get_next_set(ctx=_ctx())

    result = _run(_test())
    assert result["success"] is True
    assert captured["method"] == "GET"
    assert "getActiveWorkout" in captured["url"]


def test_get_next_set_passes_user_headers(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"success": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.copilot_skills.get_functions_client", lambda: mock_client)

    _run(get_next_set(ctx=_ctx()))
    assert captured["headers"]["x-user-id"] == "u1"


def test_parse_shorthand_kg():
    result = parse_shorthand("8@100")
    assert result == {"reps": 8, "weight": 100.0, "unit": "kg"}


def test_parse_shorthand_lbs():
    result = parse_shorthand("5 @ 225lbs")
    assert result == {"reps": 5, "weight": 225.0, "unit": "lbs"}


def test_parse_shorthand_no_match():
    assert parse_shorthand("hello world") is None
