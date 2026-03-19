# tests/test_skills_http.py
"""Integration tests for skill files using the shared FunctionsClient.

Verifies that each migrated skill calls the correct endpoint with the
correct body/params, and that responses are properly unwrapped.
Uses httpx.MockTransport to exercise the real HTTP pipeline.
"""

import asyncio
import json

import httpx
import pytest

from app.context import RequestContext
from app.http_client import FunctionsClient, FunctionsError


def _run(coro):
    """Helper to run async tests without pytest-asyncio."""
    return asyncio.run(coro)


def _make_client(handler) -> FunctionsClient:
    """Build a FunctionsClient with mock transport for testing."""
    client = FunctionsClient(base_url="http://test", api_key="test-key")
    client._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return client


def _ctx(**overrides) -> RequestContext:
    """Create a RequestContext with sensible defaults."""
    defaults = {
        "user_id": "test-user",
        "conversation_id": "test-conv",
        "correlation_id": "test-corr",
        "workout_id": "w-123",
    }
    defaults.update(overrides)
    return RequestContext(**defaults)


# ---------------------------------------------------------------------------
# copilot_skills.log_set
# ---------------------------------------------------------------------------


def test_log_set_posts_to_logSet(monkeypatch):
    """log_set POSTs to /logSet with correct body fields."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"status": "ok"}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.copilot_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.copilot_skills import log_set

    async def _test():
        return await log_set(
            ctx=_ctx(),
            exercise_instance_id="ex-1",
            set_id="s-1",
            reps=8,
            weight_kg=100.0,
            rir=1,
        )

    result = _run(_test())

    assert captured["url"] == "http://test/logSet"
    assert captured["body"]["workout_id"] == "w-123"
    assert captured["body"]["exercise_instance_id"] == "ex-1"
    assert captured["body"]["set_id"] == "s-1"
    assert captured["body"]["values"] == {"weight": 100.0, "reps": 8, "rir": 1}
    assert "idempotency_key" in captured["body"]
    assert captured["headers"]["x-user-id"] == "test-user"
    assert result == {"status": "ok"}


# ---------------------------------------------------------------------------
# copilot_skills.get_next_set
# ---------------------------------------------------------------------------


def test_get_next_set_gets_active_workout(monkeypatch):
    """get_next_set GETs /getActiveWorkout with workout_id param."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["method"] = request.method
        return httpx.Response(200, json={"data": {"exercises": []}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.copilot_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.copilot_skills import get_next_set

    result = _run(get_next_set(ctx=_ctx()))

    assert captured["method"] == "GET"
    assert "workout_id=w-123" in captured["url"]
    assert result == {"exercises": []}


# ---------------------------------------------------------------------------
# workout_skills.swap_exercise
# ---------------------------------------------------------------------------


def test_swap_exercise_posts_correct_body(monkeypatch):
    """swap_exercise POSTs to /swapExercise with the right fields."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"swapped": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.workout_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.workout_skills import swap_exercise

    result = _run(
        swap_exercise(
            ctx=_ctx(),
            exercise_instance_id="ex-old",
            new_exercise_id="bench-press",
            new_exercise_name="Bench Press",
        )
    )

    assert captured["url"] == "http://test/swapExercise"
    assert captured["body"]["workout_id"] == "w-123"
    assert captured["body"]["exercise_instance_id"] == "ex-old"
    assert captured["body"]["new_exercise_id"] == "bench-press"
    assert captured["body"]["new_exercise_name"] == "Bench Press"
    assert result == {"swapped": True}


# ---------------------------------------------------------------------------
# workout_skills.complete_workout
# ---------------------------------------------------------------------------


def test_complete_workout_posts_to_completeActiveWorkout(monkeypatch):
    """complete_workout POSTs to /completeActiveWorkout."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"completed": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.workout_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.workout_skills import complete_workout

    result = _run(complete_workout(ctx=_ctx()))

    assert captured["url"] == "http://test/completeActiveWorkout"
    assert captured["body"]["workout_id"] == "w-123"
    assert result == {"completed": True}


# ---------------------------------------------------------------------------
# planner_skills.update_routine
# ---------------------------------------------------------------------------


def test_update_routine_posts_with_userId_in_body(monkeypatch):
    """update_routine POSTs to /updateRoutine with userId in body."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"updated": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.planner_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.planner_skills import update_routine

    workouts = [{"title": "Day 1", "exercises": []}]
    result = _run(
        update_routine(
            ctx=_ctx(),
            routine_id="r-1",
            routine_name="PPL",
            workouts=workouts,
        )
    )

    assert captured["url"] == "http://test/updateRoutine"
    assert captured["body"]["userId"] == "test-user"
    assert captured["body"]["routineId"] == "r-1"
    assert captured["body"]["routineName"] == "PPL"
    assert captured["body"]["workouts"] == workouts
    # Shared client also adds x-user-id header
    assert captured["headers"]["x-user-id"] == "test-user"
    assert result == {"updated": True}


# ---------------------------------------------------------------------------
# planner_skills.update_template
# ---------------------------------------------------------------------------


def test_update_template_posts_to_patchTemplate(monkeypatch):
    """update_template POSTs to /patchTemplate with userId and blocks."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"patched": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.planner_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.planner_skills import update_template

    exercises = [{"name": "Squat", "sets": 3, "reps": 5, "weight_kg": 100}]
    result = _run(
        update_template(
            ctx=_ctx(),
            template_id="t-1",
            exercises=exercises,
        )
    )

    assert captured["url"] == "http://test/patchTemplate"
    assert captured["body"]["userId"] == "test-user"
    assert captured["body"]["templateId"] == "t-1"
    # exercises are transformed through _build_exercise_blocks
    assert len(captured["body"]["exercises"]) == 1
    assert captured["body"]["exercises"][0]["name"] == "Squat"
    assert result == {"patched": True}


# ---------------------------------------------------------------------------
# progression_skills.apply_progression
# ---------------------------------------------------------------------------


def test_apply_progression_posts_correct_body(monkeypatch):
    """apply_progression POSTs to /applyProgression with all fields."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, json={"data": {"applied": True}})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.progression_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.progression_skills import apply_progression

    changes = [{"path": "exercises[0].sets[0].weight", "from": 80, "to": 85}]
    result = _run(
        apply_progression(
            ctx=_ctx(),
            target_type="template",
            target_id="t-1",
            changes=changes,
            summary="Increase weight",
            rationale="Hit all reps with RIR 3",
            trigger="post_workout",
            auto_apply=True,
        )
    )

    assert captured["url"] == "http://test/applyProgression"
    assert captured["body"]["userId"] == "test-user"
    assert captured["body"]["targetType"] == "template"
    assert captured["body"]["targetId"] == "t-1"
    assert captured["body"]["changes"] == changes
    assert captured["body"]["summary"] == "Increase weight"
    assert captured["body"]["rationale"] == "Hit all reps with RIR 3"
    assert captured["body"]["trigger"] == "post_workout"
    assert captured["body"]["autoApply"] is True
    assert result == {"applied": True}


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


def test_non_2xx_raises_functions_error(monkeypatch):
    """Non-2xx response from any skill raises FunctionsError."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"error": "Workout not found"})

    mock_client = _make_client(handler)
    monkeypatch.setattr(
        "app.skills.copilot_skills.get_functions_client", lambda: mock_client
    )

    from app.skills.copilot_skills import get_next_set

    with pytest.raises(FunctionsError) as exc_info:
        _run(get_next_set(ctx=_ctx()))

    assert exc_info.value.status_code == 404
    assert "Workout not found" in exc_info.value.message
    assert exc_info.value.endpoint == "/getActiveWorkout"
