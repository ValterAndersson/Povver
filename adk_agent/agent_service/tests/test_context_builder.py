"""Tests for the 360 View Context Builder."""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from app.context import RequestContext
from app.context_builder import (
    build_system_context,
    _format_snapshot,
    _format_history,
    MEMORY_GUIDANCE,
)


def _make_ctx(**overrides) -> RequestContext:
    defaults = {
        "user_id": "u1",
        "conversation_id": "conv1",
        "correlation_id": "corr1",
        "today": "2026-03-17",
    }
    defaults.update(overrides)
    return RequestContext(**defaults)


def _mock_firestore_client(
    planning=None, history=None, session_vars=None, summaries=None
):
    fs = MagicMock()
    fs.CONVERSATION_COLLECTION = "canvases"
    if planning is None:
        planning = {
            "user": {"name": "Val", "attributes": {"fitness_level": "intermediate", "fitness_goal": "hypertrophy"}, "weight_unit": "kg"},
            "active_routine": {"name": "Push Pull Legs"},
            "analysis": {"summary": "Bench trending up"},
        }
    if history is None:
        history = [
            {"type": "user_prompt", "content": "How am I doing?"},
            {"type": "agent_response", "content": "Looking good."},
        ]
    fs.get_planning_context = AsyncMock(return_value=planning)
    fs.get_conversation_messages = AsyncMock(return_value=history)

    # _load_recent_summaries uses fs.db.collection(...).order_by(...).limit(...).stream()
    if summaries is None:
        summaries = [{"summary": "Discussed chest volume"}]
    summary_docs = summaries

    async def _summary_stream():
        for s in summary_docs:
            doc = MagicMock()
            doc.to_dict.return_value = s
            yield doc

    # Build the chained mock for collection queries (summaries)
    collection_mock = MagicMock()
    collection_mock.order_by.return_value.limit.return_value.stream = _summary_stream

    # Build a separate mock for document lookups (session vars)
    session_doc = MagicMock()
    session_doc.exists = session_vars is not None
    session_doc.to_dict.return_value = {"session_vars": session_vars} if session_vars else {}
    document_mock = MagicMock()
    document_mock.get = AsyncMock(return_value=session_doc)

    # Wire up fs.db to return the right mock for collection() vs document()
    fs.db = MagicMock()
    fs.db.collection.return_value = collection_mock
    fs.db.document.return_value = document_mock

    return fs


def _mock_memory_manager(memories=None):
    mm = MagicMock()
    if memories is None:
        memories = [
            {"category": "preference", "content": "Prefers 4-day splits"},
            {"category": "injury", "content": "Left shoulder impingement"},
        ]
    mm.list_active_memories = AsyncMock(return_value=memories)
    return mm


@pytest.mark.asyncio
@patch("app.context_builder.get_memory_manager")
@patch("app.context_builder.get_firestore_client")
async def test_build_system_context_includes_all_sections(mock_get_fs, mock_get_mm):
    """Instruction contains memories, planning snapshot, summaries, and MEMORY_GUIDANCE."""
    mock_get_fs.return_value = _mock_firestore_client()
    mock_get_mm.return_value = _mock_memory_manager()

    ctx = _make_ctx()
    instruction, history = await build_system_context(ctx)

    # Base instruction present
    assert "today=2026-03-17" in instruction
    assert "user_id=u1" in instruction

    # Memory guidance
    assert "save_memory" in instruction
    assert "retire_memory" in instruction

    # User memories
    assert "[preference] Prefers 4-day splits" in instruction
    assert "[injury] Left shoulder impingement" in instruction

    # Conversation summaries
    assert "Discussed chest volume" in instruction

    # Planning snapshot
    assert "User: Val" in instruction
    assert "Fitness level: intermediate" in instruction
    assert "Goal: hypertrophy" in instruction
    assert "Active routine: Push Pull Legs" in instruction
    assert "Latest insight: Bench trending up" in instruction

    # History formatted correctly
    assert len(history) == 2
    assert history[0] == {"role": "user", "content": "How am I doing?"}
    assert history[1] == {"role": "assistant", "content": "Looking good."}


@pytest.mark.asyncio
@patch("app.context_builder.get_memory_manager")
@patch("app.context_builder.get_firestore_client")
async def test_build_system_context_handles_errors(mock_get_fs, mock_get_mm):
    """When planning/memories raise exceptions, context builder degrades gracefully."""
    fs = _mock_firestore_client()
    fs.get_planning_context = AsyncMock(side_effect=ConnectionError("Firestore down"))

    mm = _mock_memory_manager()
    mm.list_active_memories = AsyncMock(side_effect=TimeoutError("Timed out"))

    mock_get_fs.return_value = fs
    mock_get_mm.return_value = mm

    ctx = _make_ctx()
    instruction, history = await build_system_context(ctx)

    # Should still produce a valid instruction (base instruction present)
    assert "today=2026-03-17" in instruction
    assert MEMORY_GUIDANCE.strip() in instruction

    # No memories section (errored out)
    assert "What You Know About This User" not in instruction

    # No snapshot section (planning errored -> empty dict, but _format_snapshot
    # still returns header). Actually: planning becomes {} on error, and
    # isinstance({}, dict) is True, so _format_snapshot({}) is called.
    # It produces "## Current Training Snapshot\nWeight unit: kg" (defaults).
    assert "Current Training Snapshot" in instruction

    # History should still work (only planning and memories failed)
    assert len(history) == 2


@pytest.mark.asyncio
@patch("app.context_builder.get_memory_manager")
@patch("app.context_builder.get_firestore_client")
async def test_build_system_context_with_session_vars(mock_get_fs, mock_get_mm):
    """Session variables from conversation doc are included."""
    fs = _mock_firestore_client(session_vars={"current_exercise": "bench press"})
    mock_get_fs.return_value = fs
    mock_get_mm.return_value = _mock_memory_manager()

    ctx = _make_ctx()
    instruction, _ = await build_system_context(ctx)

    assert "Session State" in instruction
    assert "current_exercise: bench press" in instruction


@pytest.mark.asyncio
@patch("app.context_builder.get_memory_manager")
@patch("app.context_builder.get_firestore_client")
async def test_build_system_context_empty_data(mock_get_fs, mock_get_mm):
    """First-time user with no data — still produces valid output."""
    fs = _mock_firestore_client(
        planning={"user": {}, "active_routine": None, "analysis": None},
        history=[],
        summaries=[],
    )

    mock_get_fs.return_value = fs
    mock_get_mm.return_value = _mock_memory_manager(memories=[])

    ctx = _make_ctx()
    instruction, history = await build_system_context(ctx)

    # Base instruction is present
    assert "today=2026-03-17" in instruction
    # No memories section
    assert "What You Know About This User" not in instruction
    # No summaries section
    assert "Recent Conversations" not in instruction
    # Empty history
    assert history == []


class TestFormatSnapshot:
    def test_full_planning_context(self):
        planning = {
            "user": {
                "name": "Val",
                "attributes": {"fitness_level": "intermediate", "fitness_goal": "hypertrophy"},
                "weight_unit": "lbs",
            },
            "active_routine": {"name": "Upper Lower"},
            "analysis": {"summary": "Volume is up 12%"},
        }
        result = _format_snapshot(planning)
        assert "User: Val" in result
        assert "Fitness level: intermediate" in result
        assert "Goal: hypertrophy" in result
        assert "Weight unit: lbs" in result
        assert "Active routine: Upper Lower" in result
        assert "Latest insight: Volume is up 12%" in result

    def test_minimal_planning_context(self):
        result = _format_snapshot({})
        assert "Current Training Snapshot" in result
        assert "Weight unit: kg" in result  # default

    def test_no_routine_or_analysis(self):
        planning = {
            "user": {"name": "Test", "attributes": {}, "weight_unit": "kg"},
            "active_routine": None,
            "analysis": None,
        }
        result = _format_snapshot(planning)
        assert "User: Test" in result
        assert "Active routine" not in result
        assert "Latest insight" not in result


class TestFormatHistory:
    def test_maps_types_to_roles(self):
        messages = [
            {"type": "user_prompt", "content": "Hello"},
            {"type": "agent_response", "content": "Hi there"},
        ]
        result = _format_history(messages)
        assert result == [
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi there"},
        ]

    def test_skips_artifacts(self):
        messages = [
            {"type": "user_prompt", "content": "Build me a routine"},
            {"type": "artifact", "content": '{"type": "routine"}'},
            {"type": "agent_response", "content": "Your routine is ready."},
        ]
        result = _format_history(messages)
        assert len(result) == 2
        assert all(m["role"] in ("user", "assistant") for m in result)

    def test_empty_messages(self):
        assert _format_history([]) == []

    def test_missing_type_defaults_to_user(self):
        """Messages without a type field default to user_prompt -> user role."""
        messages = [{"content": "Hello"}]
        result = _format_history(messages)
        assert result == [{"role": "user", "content": "Hello"}]

    def test_missing_content_defaults_to_empty(self):
        messages = [{"type": "agent_response"}]
        result = _format_history(messages)
        assert result == [{"role": "assistant", "content": ""}]
