# tests/test_firestore_client_http.py
"""Tests for FirestoreClient methods migrated from direct Firestore to HTTP.

Uses httpx.MockTransport (same pattern as test_http_client.py) to simulate
real Firebase Function responses and verify the full pipeline:
  FirestoreClient method -> FunctionsClient -> HTTP -> response parsing.
"""

import asyncio
import json
from unittest.mock import patch

import httpx
import pytest

from app.firestore_client import FirestoreClient
from app.http_client import FunctionsClient


def _run(coro):
    """Helper to run async tests without pytest-asyncio."""
    return asyncio.run(coro)


def _mock_transport(handler):
    return httpx.MockTransport(handler)


def _make_functions_client(handler):
    """Build a FunctionsClient with mock transport."""
    client = FunctionsClient(
        base_url="https://example.com",
        api_key="test-key",
    )
    client._client = httpx.AsyncClient(transport=_mock_transport(handler))
    return client


def _make_firestore_client(handler):
    """Build a FirestoreClient with its _http replaced by a mock-backed FunctionsClient."""
    from unittest.mock import MagicMock
    fs = FirestoreClient.__new__(FirestoreClient)
    fs.db = MagicMock()  # Keep db for methods that still use Firestore
    fs._http = _make_functions_client(handler)
    return fs


# ---- get_planning_context ---------------------------------------------------


def test_get_planning_context_uses_http_compact_view():
    """Verify get_planning_context calls /getPlanningContext with view=compact and returns result."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["method"] = request.method
        captured["body"] = json.loads(request.content) if request.content else None
        return httpx.Response(200, json={"data": {
            "user": {"name": "Val", "weight_unit": "kg", "fitness_level": "intermediate", "fitness_goal": "Build Muscle"},
            "activeRoutine": {"id": "r1", "name": "PPL", "template_ids": ["t1", "t2"]},
            "templates": [{"id": "t1", "name": "Push"}],
            "recentWorkouts": [{"id": "w1", "name": "Push Day"}],
            "strengthSummary": [],
            "daysSinceLastWorkout": 2,
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        result = await fs.get_planning_context("user1")
        return result

    result = _run(_test())

    assert captured["method"] == "POST"
    assert "/getPlanningContext" in captured["url"]
    assert captured["body"]["view"] == "compact"
    assert captured["body"]["workoutLimit"] == 10
    # Verify the result is passed through
    assert result["user"]["name"] == "Val"
    assert result["activeRoutine"]["id"] == "r1"
    assert result["templates"][0]["name"] == "Push"
    assert result["recentWorkouts"][0]["name"] == "Push Day"


# ---- list_templates ----------------------------------------------------------


def test_list_templates_summary_view():
    """Verify list_templates calls /getUserTemplates with view=summary and returns items."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["method"] = request.method
        return httpx.Response(200, json={"data": {
            "templates": [
                {"id": "t1", "name": "Push", "exercise_count": 5},
                {"id": "t2", "name": "Pull", "exercise_count": 4},
            ],
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.list_templates("user1")

    result = _run(_test())

    assert captured["method"] == "GET"
    assert "/getUserTemplates" in captured["url"]
    assert "view=summary" in captured["url"]
    assert len(result) == 2
    assert result[0]["name"] == "Push"


def test_list_templates_full_view():
    """Verify list_templates(include_exercises=True) omits view param."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {
            "templates": [
                {"id": "t1", "name": "Push", "exercises": [{"name": "Bench Press"}]},
            ],
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.list_templates("user1", include_exercises=True)

    result = _run(_test())

    assert "view=summary" not in captured["url"]
    assert len(result) == 1
    assert result[0]["exercises"][0]["name"] == "Bench Press"


# ---- list_recent_workouts ----------------------------------------------------


def test_list_recent_workouts_summary():
    """Verify list_recent_workouts calls /getUserWorkouts with view=summary."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {
            "workouts": [
                {"id": "w1", "name": "Push Day", "end_time": "2026-03-18"},
            ],
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.list_recent_workouts("user1", limit=3)

    result = _run(_test())

    assert "/getUserWorkouts" in captured["url"]
    assert "view=summary" in captured["url"]
    assert "limit=3" in captured["url"]
    assert len(result) == 1
    assert result[0]["name"] == "Push Day"


# ---- get_analysis_summary ---------------------------------------------------


def test_get_analysis_summary_filters_expired():
    """Verify get_analysis_summary passes include_expired=false."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {
            "sections": [{"type": "strength", "summary": "Bench up 5%"}],
            "created_at": "2026-03-18",
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.get_analysis_summary("user1")

    result = _run(_test())

    assert "/getAnalysisSummary" in captured["url"]
    assert "include_expired=false" in captured["url"]
    assert result["sections"][0]["summary"] == "Bench up 5%"


# ---- get_weekly_review -------------------------------------------------------


def test_get_weekly_review_uses_sections_param():
    """Verify get_weekly_review requests only weekly_review section."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {
            "weekly_review": {"total_workouts": 4, "volume_change": "+12%"},
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.get_weekly_review("user1")

    result = _run(_test())

    assert "/getAnalysisSummary" in captured["url"]
    assert "sections=weekly_review" in captured["url"]
    assert result["weekly_review"]["total_workouts"] == 4


# ---- get_muscle_group_summary ------------------------------------------------


def test_get_muscle_group_summary_passes_weeks():
    """Verify weeks parameter is forwarded (not ignored like before)."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {
            "muscle_group": "chest",
            "weeks": [{"week": "2026-W10", "sets": 12}],
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.get_muscle_group_summary("user1", "chest", weeks=12)

    result = _run(_test())

    assert "/getMuscleGroupSummary" in captured["url"]
    assert "muscle_group=chest" in captured["url"]
    assert "weeks=12" in captured["url"]
    assert result["muscle_group"] == "chest"


# ---- get_exercise_summary ----------------------------------------------------


def test_get_exercise_summary_passes_exercise_name():
    """Verify get_exercise_summary sends exercise_name param."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {
            "exercise_id": "bench_press",
            "points_by_day": {"2026-03-01": 100},
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.get_exercise_summary("user1", "bench_press")

    result = _run(_test())

    assert "/getExerciseSummary" in captured["url"]
    assert "exercise_name=bench_press" in captured["url"]
    assert result["exercise_id"] == "bench_press"


# ---- query_sets --------------------------------------------------------------


def test_query_sets_posts_target():
    """Verify query_sets sends target in POST body."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        captured["method"] = request.method
        return httpx.Response(200, json={"data": {
            "sets": [
                {"id": "s1", "exercise_id": "bench_press", "reps": 8, "weight_kg": 80},
            ],
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.query_sets("user1", "bench_press", {"limit": 20, "date_from": "2026-01-01"})

    result = _run(_test())

    assert captured["method"] == "POST"
    assert captured["body"]["target"]["exercise_id"] == "bench_press"
    assert captured["body"]["limit"] == 20
    assert len(result) == 1
    assert result[0]["reps"] == 8


# ---- search_exercises --------------------------------------------------------


def test_search_exercises_uses_shared_client():
    """Verify search_exercises uses FunctionsClient instead of inline httpx."""
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["method"] = request.method
        return httpx.Response(200, json={"data": {
            "exercises": [
                {"id": "e1", "name": "Bench Press", "muscle_group": "chest"},
            ],
        }})

    async def _test():
        fs = _make_firestore_client(handler)
        return await fs.search_exercises("bench", limit=5)

    result = _run(_test())

    assert "/searchExercises" in captured["url"]
    assert "query=bench" in captured["url"]
    assert "limit=5" in captured["url"]
    assert len(result) == 1
    assert result[0]["name"] == "Bench Press"


# ---- Deleted methods should not exist ----------------------------------------


def test_deleted_methods_removed():
    """Verify unused methods are removed from FirestoreClient."""
    from unittest.mock import MagicMock
    fs = FirestoreClient.__new__(FirestoreClient)
    fs.db = MagicMock()

    assert not hasattr(fs, 'get_routine') or not callable(getattr(fs, 'get_routine', None))
    assert not hasattr(fs, 'get_template') or not callable(getattr(fs, 'get_template', None))
    assert not hasattr(fs, 'list_routines') or not callable(getattr(fs, 'list_routines', None))
    assert not hasattr(fs, 'get_muscle_summary') or not callable(getattr(fs, 'get_muscle_summary', None))
    assert not hasattr(fs, 'get_active_snapshot_lite') or not callable(getattr(fs, 'get_active_snapshot_lite', None))
    assert not hasattr(fs, 'get_active_events') or not callable(getattr(fs, 'get_active_events', None))


# ---- Methods that must remain on direct Firestore ----------------------------


def test_retained_firestore_methods_exist():
    """Verify methods that should stay on Firestore still exist."""
    from unittest.mock import MagicMock
    fs = FirestoreClient.__new__(FirestoreClient)
    fs.db = MagicMock()

    assert callable(getattr(fs, 'get_user', None))
    assert callable(getattr(fs, 'get_user_attributes', None))
    assert callable(getattr(fs, 'get_weekly_stats', None))
    assert callable(getattr(fs, 'get_conversation_messages', None))
    assert callable(getattr(fs, 'save_message', None))
    assert callable(getattr(fs, 'save_artifact', None))
