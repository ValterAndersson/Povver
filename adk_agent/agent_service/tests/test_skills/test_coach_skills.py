# tests/test_skills/test_coach_skills.py
"""Tests for coach_skills — mocks FirestoreClient for all read-only tools."""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock

from app.context import RequestContext
from app.skills import coach_skills


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


@pytest.fixture
def mock_fs():
    """Create a mock FirestoreClient with all methods used by coach_skills."""
    fs = MagicMock()
    fs.get_user = AsyncMock(return_value={"id": "u1", "name": "Test User"})
    fs.search_exercises = AsyncMock(return_value=[
        {"id": "barbell-bench-press", "name": "Barbell Bench Press"},
        {"id": "dumbbell-curl", "name": "Dumbbell Curl"},
    ])
    fs.get_planning_context = AsyncMock(return_value={
        "user": {"name": "Test User"},
        "active_routine": {"id": "r1", "name": "PPL"},
        "templates": [],
        "recent_workouts": [],
    })
    fs.get_analysis_summary = AsyncMock(return_value={
        "id": "insight-1", "type": "post_workout", "summary": "Good session",
    })
    fs.get_weekly_review = AsyncMock(return_value={
        "id": "2026-W11", "summary": "Solid week",
    })
    fs.get_muscle_group_summary = AsyncMock(return_value={
        "muscle_group": "chest", "weeks": [{"week": "2026-W10", "sets": 12}],
    })
    fs.get_exercise_summary = AsyncMock(return_value={
        "exercise_id": "barbell-bench-press", "points_by_day": {"2026-03-10": {"e1rm": 100}},
    })
    fs.query_sets = AsyncMock(return_value=[
        {"id": "s1", "weight_kg": 80, "reps": 8},
        {"id": "s2", "weight_kg": 82.5, "reps": 7},
    ])
    return fs


@pytest.fixture(autouse=True)
def patch_fs(mock_fs):
    with patch("app.skills.coach_skills.get_firestore_client", return_value=mock_fs):
        yield mock_fs


# --- Tests ---


@pytest.mark.asyncio
async def test_get_user_profile(ctx, mock_fs):
    result = await coach_skills.get_user_profile(ctx=ctx)
    assert result["id"] == "u1"
    assert result["name"] == "Test User"
    mock_fs.get_user.assert_awaited_once_with("u1")


@pytest.mark.asyncio
async def test_search_exercises(ctx, mock_fs):
    result = await coach_skills.search_exercises(ctx=ctx, query="bench")
    assert result["count"] == 2
    assert len(result["exercises"]) == 2
    mock_fs.search_exercises.assert_awaited_once_with("bench", 10)


@pytest.mark.asyncio
async def test_search_exercises_custom_limit(ctx, mock_fs):
    await coach_skills.search_exercises(ctx=ctx, query="curl", limit=5)
    mock_fs.search_exercises.assert_awaited_once_with("curl", 5)


@pytest.mark.asyncio
async def test_get_planning_context(ctx, mock_fs):
    result = await coach_skills.get_planning_context(ctx=ctx)
    assert result["active_routine"]["id"] == "r1"
    mock_fs.get_planning_context.assert_awaited_once_with("u1")


@pytest.mark.asyncio
async def test_get_training_analysis(ctx, mock_fs):
    result = await coach_skills.get_training_analysis(ctx=ctx)
    assert result["analysis"]["id"] == "insight-1"
    assert result["weekly_review"]["id"] == "2026-W11"
    mock_fs.get_analysis_summary.assert_awaited_once_with("u1")
    mock_fs.get_weekly_review.assert_awaited_once_with("u1")


@pytest.mark.asyncio
async def test_get_training_analysis_with_sections(ctx, mock_fs):
    """Sections param is accepted (future filtering), both calls still made."""
    result = await coach_skills.get_training_analysis(ctx=ctx, sections=["insights"])
    assert "analysis" in result
    assert "weekly_review" in result


@pytest.mark.asyncio
async def test_get_muscle_group_progress(ctx, mock_fs):
    result = await coach_skills.get_muscle_group_progress(ctx=ctx, muscle_group="chest")
    assert result["muscle_group"] == "chest"
    mock_fs.get_muscle_group_summary.assert_awaited_once_with("u1", "chest", 8)


@pytest.mark.asyncio
async def test_get_muscle_group_progress_custom_weeks(ctx, mock_fs):
    await coach_skills.get_muscle_group_progress(ctx=ctx, muscle_group="back", weeks=12)
    mock_fs.get_muscle_group_summary.assert_awaited_once_with("u1", "back", 12)


@pytest.mark.asyncio
async def test_get_exercise_progress(ctx, mock_fs):
    result = await coach_skills.get_exercise_progress(ctx=ctx, exercise_id="barbell-bench-press")
    assert result["exercise_id"] == "barbell-bench-press"
    mock_fs.get_exercise_summary.assert_awaited_once_with("u1", "barbell-bench-press")


@pytest.mark.asyncio
async def test_query_training_sets(ctx, mock_fs):
    result = await coach_skills.query_training_sets(ctx=ctx, exercise_id="barbell-bench-press")
    assert result["count"] == 2
    assert len(result["sets"]) == 2
    mock_fs.query_sets.assert_awaited_once_with("u1", "barbell-bench-press", {"limit": 50})


@pytest.mark.asyncio
async def test_query_training_sets_with_date_filters(ctx, mock_fs):
    result = await coach_skills.query_training_sets(
        ctx=ctx, exercise_id="barbell-bench-press",
        start="2026-01-01", end="2026-03-01", limit=20,
    )
    assert result["count"] == 2
    mock_fs.query_sets.assert_awaited_once_with(
        "u1", "barbell-bench-press",
        {"limit": 20, "date_from": "2026-01-01", "date_to": "2026-03-01"},
    )
