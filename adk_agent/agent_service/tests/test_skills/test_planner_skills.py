# tests/test_skills/test_planner_skills.py
"""Tests for planner_skills — write tools that create artifacts."""

import asyncio
import json

import httpx
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from app.context import RequestContext
from app.http_client import FunctionsClient
from app.skills.planner_skills import (
    _build_exercise_blocks,
    _coerce_int,
    _extract_reps,
    _slugify,
    propose_routine,
    propose_workout,
    update_routine,
    update_template,
)


def _run(coro):
    return asyncio.run(coro)


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


@pytest.fixture
def sample_exercises():
    return [
        {
            "name": "Bench Press",
            "exercise_id": "bench-press",
            "sets": 3,
            "reps": 8,
            "rir": 2,
            "weight_kg": 80,
            "category": "compound",
        },
        {
            "name": "Lateral Raise",
            "exercise_id": "lateral-raise",
            "sets": 3,
            "reps": 12,
            "rir": 1,
            "weight_kg": 10,
        },
    ]


def _make_client(handler) -> FunctionsClient:
    client = FunctionsClient(base_url="http://test", api_key="test-key")
    client._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return client


# ============================================================================
# Helper tests
# ============================================================================


def test_coerce_int_valid():
    assert _coerce_int("5", 0) == 5
    assert _coerce_int(3.7, 0) == 3


def test_coerce_int_invalid():
    assert _coerce_int("abc", 7) == 7
    assert _coerce_int(None, 4) == 4


def test_slugify():
    assert _slugify("Bench Press") == "bench-press"
    assert _slugify("   ") == "exercise"  # empty slug falls back
    assert len(_slugify("A" * 100)) <= 48


def test_extract_reps_int():
    assert _extract_reps(10) == 10
    assert _extract_reps(0) == 1  # min clamp


def test_extract_reps_string():
    assert _extract_reps("8-12") == 12  # takes last number
    assert _extract_reps("no digits", 6) == 6


def test_build_exercise_blocks_basic(sample_exercises):
    blocks = _build_exercise_blocks(sample_exercises)
    assert len(blocks) == 2
    assert blocks[0]["name"] == "Bench Press"
    assert blocks[0]["exercise_id"] == "bench-press"
    # Bench press: compound, 80kg >= 40 => 2 warmup + 3 working = 5 sets
    assert len(blocks[0]["sets"]) == 5
    warmup_sets = [s for s in blocks[0]["sets"] if s["type"] == "warmup"]
    working_sets = [s for s in blocks[0]["sets"] if s["type"] == "working"]
    assert len(warmup_sets) == 2
    assert len(working_sets) == 3


def test_build_exercise_blocks_skips_non_dicts():
    blocks = _build_exercise_blocks(["not a dict", 42, None])
    assert blocks == []


def test_build_exercise_blocks_missing_weight():
    blocks = _build_exercise_blocks([{"name": "Pullup", "sets": 3, "reps": 10}])
    assert len(blocks) == 1
    # No weight => no warmup sets (even though idx < 2 => is_compound)
    assert all(s["type"] == "working" for s in blocks[0]["sets"])


# ============================================================================
# propose_workout tests
# ============================================================================


def test_propose_workout_returns_artifact(ctx, sample_exercises):
    mock_fs = MagicMock()
    mock_fs.save_artifact = AsyncMock()

    async def _test():
        with patch("app.skills.planner_skills.get_firestore_client", return_value=mock_fs):
            result = await propose_workout(
                ctx=ctx,
                title="Push Day",
                exercises=sample_exercises,
            )
        assert result["artifact_type"] == "session_plan"
        assert result["content"]["title"] == "Push Day"
        assert result["status"] == "proposed"
        assert result["exercises"] == 2
        mock_fs.save_artifact.assert_awaited_once()

    _run(_test())


def test_propose_workout_dry_run(ctx, sample_exercises):
    async def _test():
        result = await propose_workout(
            ctx=ctx,
            title="Push Day",
            exercises=sample_exercises,
            dry_run=True,
        )
        assert result["dry_run"] is True
        assert result["status"] == "preview"
        assert "artifact_type" not in result  # not persisted
        assert result["preview"]["title"] == "Push Day"

    _run(_test())


def test_propose_workout_empty_exercises(ctx):
    async def _test():
        result = await propose_workout(
            ctx=ctx, title="Empty", exercises=[]
        )
        assert "error" in result

    _run(_test())


# ============================================================================
# propose_routine tests
# ============================================================================


def test_propose_routine_with_multiple_workouts(ctx, sample_exercises):
    mock_fs = MagicMock()
    mock_fs.save_artifact = AsyncMock()

    async def _test():
        with patch("app.skills.planner_skills.get_firestore_client", return_value=mock_fs):
            result = await propose_routine(
                ctx=ctx,
                name="PPL",
                frequency=3,
                workouts=[
                    {"title": "Push", "exercises": sample_exercises},
                    {"title": "Pull", "exercises": sample_exercises},
                ],
            )
        assert result["artifact_type"] == "routine_summary"
        assert result["content"]["name"] == "PPL"
        assert result["content"]["frequency"] == 3
        assert len(result["content"]["workouts"]) == 2
        assert result["workout_count"] == 2
        mock_fs.save_artifact.assert_awaited_once()

    _run(_test())


def test_propose_routine_dry_run(ctx, sample_exercises):
    async def _test():
        result = await propose_routine(
            ctx=ctx,
            name="PPL",
            frequency=3,
            workouts=[{"title": "Push", "exercises": sample_exercises}],
            dry_run=True,
        )
        assert result["dry_run"] is True
        assert "artifact_type" not in result

    _run(_test())


def test_propose_routine_all_empty_workouts(ctx):
    async def _test():
        result = await propose_routine(
            ctx=ctx,
            name="Bad Routine",
            frequency=2,
            workouts=[{"title": "Day 1", "exercises": []}],
        )
        assert "error" in result

    _run(_test())


def test_propose_routine_no_workouts(ctx):
    async def _test():
        result = await propose_routine(
            ctx=ctx, name="Empty", frequency=1, workouts=[]
        )
        assert "error" in result

    _run(_test())


# ============================================================================
# update_routine tests (MockTransport)
# ============================================================================


def test_update_routine_calls_http(ctx, monkeypatch):
    """update_routine POSTs to the Firebase Function via shared client."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"ok": True, "routineId": "r1"}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.planner_skills.get_functions_client", lambda: mock_client)

    async def _test():
        return await update_routine(
            ctx=ctx,
            routine_id="r1",
            routine_name="PPL Updated",
            workouts=[{"title": "Push", "exercises": []}],
        )

    result = _run(_test())
    assert result["ok"] is True
    assert captured["body"]["userId"] == "u1"
    assert captured["body"]["routineId"] == "r1"
    assert "updateRoutine" in captured["url"]


# ============================================================================
# update_template tests (MockTransport)
# ============================================================================


def test_update_template_calls_http(ctx, sample_exercises, monkeypatch):
    """update_template POSTs to patchTemplate Firebase Function via shared client."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"ok": True, "templateId": "t1"}})

    mock_client = _make_client(handler)
    monkeypatch.setattr("app.skills.planner_skills.get_functions_client", lambda: mock_client)

    async def _test():
        return await update_template(
            ctx=ctx,
            template_id="t1",
            exercises=sample_exercises,
        )

    result = _run(_test())
    assert result["ok"] is True
    assert captured["body"]["userId"] == "u1"
    assert captured["body"]["templateId"] == "t1"
    assert isinstance(captured["body"]["exercises"], list)
    assert "patchTemplate" in captured["url"]
