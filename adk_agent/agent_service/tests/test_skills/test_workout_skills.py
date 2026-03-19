# tests/test_skills/test_workout_skills.py
"""Tests for workout_skills — LLM-directed workout operations."""

import asyncio
import json

import httpx

from app.context import RequestContext
from app.http_client import FunctionsClient
from app.skills.workout_skills import (
    add_exercise,
    complete_workout,
    get_workout_state,
    prescribe_set,
    swap_exercise,
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


def test_get_workout_state(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["method"] = request.method
        return httpx.Response(200, json={"data": {"success": True, "workout": {"exercises": []}}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    result = _run(get_workout_state(ctx=_ctx()))
    assert result["success"] is True
    assert "getActiveWorkout" in captured["url"]


def test_swap_exercise(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"event_id": "ev1"}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    result = _run(
        swap_exercise(
            ctx=_ctx(),
            exercise_instance_id="ex1",
            new_exercise_id="ex2",
            new_exercise_name="Incline Press",
        )
    )
    assert result["event_id"] == "ev1"
    assert captured["body"]["workout_id"] == "w1"
    assert captured["body"]["new_exercise_id"] == "ex2"


def test_add_exercise(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"success": True, "event_id": "ev2"}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    result = _run(
        add_exercise(
            ctx=_ctx(),
            exercise_id="lateral_raise",
            name="Lateral Raise",
            sets=4,
            reps=12,
            weight_kg=10.0,
        )
    )
    assert result["success"] is True
    payload = captured["body"]
    assert payload["name"] == "Lateral Raise"
    assert len(payload["sets"]) == 4
    assert all(s["set_type"] == "working" for s in payload["sets"])
    assert all(s["target_reps"] == 12 for s in payload["sets"])
    assert all(s["target_weight"] == 10.0 for s in payload["sets"])


def test_prescribe_set_weight_only(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"success": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    result = _run(
        prescribe_set(
            ctx=_ctx(),
            exercise_instance_id="ex1",
            set_id="s2",
            weight_kg=85.0,
        )
    )
    assert result["success"] is True
    payload = captured["body"]
    assert len(payload["ops"]) == 1
    assert payload["ops"][0]["op"] == "set_field"
    assert payload["ops"][0]["field"] == "weight"
    assert payload["ops"][0]["value"] == 85.0


def test_prescribe_set_reps_only(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"success": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    result = _run(
        prescribe_set(
            ctx=_ctx(),
            exercise_instance_id="ex1",
            set_id="s2",
            reps=6,
        )
    )
    assert result["success"] is True
    payload = captured["body"]
    assert len(payload["ops"]) == 1
    assert payload["ops"][0]["op"] == "set_field"
    assert payload["ops"][0]["field"] == "reps"
    assert payload["ops"][0]["value"] == 6


def test_complete_workout(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"workout_id": "w1", "archived": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    result = _run(complete_workout(ctx=_ctx()))
    assert result["archived"] is True
    assert "completeActiveWorkout" in captured["url"]


def test_headers_include_user_id(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"ok": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.workout_skills.get_functions_client", lambda: mock_client)

    _run(get_workout_state(ctx=_ctx(user_id="user42")))
    assert captured["headers"]["x-user-id"] == "user42"
