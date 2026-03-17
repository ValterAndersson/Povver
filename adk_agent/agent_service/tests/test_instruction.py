# tests/test_instruction.py
import pytest
from unittest.mock import AsyncMock
from app.instruction import build_instruction, CORE_INSTRUCTION, MEMORY_GUIDANCE, _format_training_snapshot
from app.context import RequestContext


def test_core_instruction_not_empty():
    assert len(CORE_INSTRUCTION) > 100


def test_no_session_references():
    """Instruction must not reference sessions or ADK."""
    lower = CORE_INSTRUCTION.lower()
    assert "session_id" not in lower
    assert "agent_version" not in lower
    assert "contextvar" not in lower
    # "adk" as standalone word (not part of another word)
    words = lower.split()
    assert "adk" not in words


def test_no_vertex_references():
    """Instruction must not reference Vertex."""
    lower = CORE_INSTRUCTION.lower()
    assert "vertex" not in lower


def test_memory_guidance_included():
    assert "save_memory" in MEMORY_GUIDANCE
    assert "retire_memory" in MEMORY_GUIDANCE


@pytest.mark.asyncio
async def test_build_instruction_includes_core():
    fs = AsyncMock()
    fs.get_planning_context.return_value = {
        "user": {"name": "Val", "attributes": {"fitness_level": "intermediate"}, "weight_unit": "kg"},
        "active_routine": {"name": "PPL"},
        "templates": [],
        "recent_workouts": [{"id": "w1"}],
        "analysis": None,
        "weekly_stats": None,
    }
    ctx = RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")
    result = await build_instruction(fs, ctx)
    assert CORE_INSTRUCTION in result
    assert MEMORY_GUIDANCE in result
    assert "Val" in result
    assert "PPL" in result


@pytest.mark.asyncio
async def test_build_instruction_handles_missing_planning():
    """First-time user with no planning data should still get core instruction."""
    fs = AsyncMock()
    fs.get_planning_context.side_effect = Exception("not found")
    ctx = RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")
    result = await build_instruction(fs, ctx)
    assert CORE_INSTRUCTION in result
    assert MEMORY_GUIDANCE in result


def test_format_training_snapshot():
    planning = {
        "user": {"name": "Val", "attributes": {"fitness_level": "advanced", "fitness_goal": "hypertrophy"}, "weight_unit": "kg"},
        "active_routine": {"name": "Upper Lower"},
        "recent_workouts": [{"id": "w1"}, {"id": "w2"}],
    }
    result = _format_training_snapshot(planning)
    assert "Val" in result
    assert "advanced" in result
    assert "hypertrophy" in result
    assert "Upper Lower" in result
    assert "Recent workouts: 2" in result
    assert "Weight unit: kg" in result


def test_format_training_snapshot_empty_user():
    """Snapshot with minimal data should not crash."""
    planning = {"user": {}, "active_routine": None, "recent_workouts": []}
    result = _format_training_snapshot(planning)
    assert "## Current Training Snapshot" in result
    # Should not contain user-specific lines
    assert "User:" not in result
    assert "Active routine:" not in result
