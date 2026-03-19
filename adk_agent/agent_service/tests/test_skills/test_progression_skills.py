# tests/test_skills/test_progression_skills.py
"""Tests for progression_skills — background progression writes."""

import asyncio
import json

import httpx

from app.context import RequestContext
from app.http_client import FunctionsClient
from app.skills.progression_skills import (
    apply_progression,
    suggest_deload,
    suggest_weight_increase,
)


def _run(coro):
    return asyncio.run(coro)


def _ctx(**overrides):
    defaults = {
        "user_id": "u1",
        "conversation_id": "c1",
        "correlation_id": "r1",
    }
    defaults.update(overrides)
    return RequestContext(**defaults)


def _make_client(handler) -> FunctionsClient:
    client = FunctionsClient(base_url="http://test", api_key="test-key")
    client._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return client


def test_apply_progression_posts_correct_payload(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {
            "recommendationId": "rec1",
            "state": "applied",
            "applied": True,
        }})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.progression_skills.get_functions_client", lambda: mock_client)

    result = _run(
        apply_progression(
            ctx=_ctx(),
            target_type="template",
            target_id="t1",
            changes=[{"path": "exercises[0].sets[0].weight", "from": 80, "to": 85}],
            summary="Increase weight",
            rationale="Good form at RIR 0",
            trigger="post_workout",
        )
    )

    assert result["recommendationId"] == "rec1"
    assert result["applied"] is True

    payload = captured["body"]
    assert payload["userId"] == "u1"
    assert payload["targetType"] == "template"
    assert payload["targetId"] == "t1"
    assert len(payload["changes"]) == 1
    assert payload["autoApply"] is True


def test_apply_progression_uses_api_key(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"ok": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.progression_skills.get_functions_client", lambda: mock_client)

    _run(
        apply_progression(
            ctx=_ctx(),
            target_type="template",
            target_id="t1",
            changes=[{"path": "x", "from": 1, "to": 2}],
            summary="Test",
            rationale="Test",
        )
    )

    assert captured["headers"]["x-api-key"] == "test-key"


def test_suggest_weight_increase_builds_changes(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"recommendationId": "rec2", "applied": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.progression_skills.get_functions_client", lambda: mock_client)

    result = _run(
        suggest_weight_increase(
            ctx=_ctx(),
            template_id="t1",
            exercise_index=0,
            new_weight=85.0,
            rationale="All sets at RIR 0",
        )
    )
    assert result["applied"] is True

    payload = captured["body"]
    # Should generate changes for up to 4 sets
    assert len(payload["changes"]) == 4
    assert payload["changes"][0]["to"] == 85.0
    assert "Increase weight to 85.0kg" in payload["summary"]


def test_suggest_deload_calculates_60_percent(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"recommendationId": "rec3", "applied": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.progression_skills.get_functions_client", lambda: mock_client)

    result = _run(
        suggest_deload(
            ctx=_ctx(),
            template_id="t1",
            exercise_index=1,
            current_weight=100.0,
            rationale="Plateau detected",
        )
    )
    assert result["applied"] is True

    payload = captured["body"]
    # 60% of 100 = 60.0
    assert payload["changes"][0]["to"] == 60.0
    assert payload["changes"][0]["from"] == 100.0
    assert "Deload to 60.0kg" in payload["summary"]


def test_apply_progression_auto_apply_false(monkeypatch):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {
            "recommendationId": "rec4",
            "state": "pending_review",
            "applied": False,
        }})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.progression_skills.get_functions_client", lambda: mock_client)

    result = _run(
        apply_progression(
            ctx=_ctx(),
            target_type="routine",
            target_id="r1",
            changes=[{"path": "x", "from": 1, "to": 2}],
            summary="Test",
            rationale="Test",
            auto_apply=False,
        )
    )
    assert result["applied"] is False
    assert captured["body"]["autoApply"] is False
