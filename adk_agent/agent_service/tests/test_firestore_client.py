# tests/test_firestore_client.py
import asyncio
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from app.firestore_client import FirestoreClient


def _run(coro):
    """Helper to run async tests without pytest-asyncio."""
    return asyncio.run(coro)


def _make_doc_snapshot(exists: bool, doc_id: str = "", data: dict | None = None):
    """Create a mock DocumentSnapshot (sync attributes, not AsyncMock)."""
    snap = MagicMock()
    snap.exists = exists
    snap.id = doc_id
    snap.to_dict.return_value = data or {}
    return snap


def test_firestore_client_init():
    """Verify FirestoreClient creates an AsyncClient."""
    with patch("app.firestore_client.AsyncClient") as mock_async:
        client = FirestoreClient()
        mock_async.assert_called_once()


def test_get_routine_returns_dict():
    """get_routine returns dict with id field."""
    async def _test():
        client = FirestoreClient.__new__(FirestoreClient)
        mock_doc = _make_doc_snapshot(True, "r1", {"name": "PPL", "template_ids": ["t1"]})

        client.db = MagicMock()
        client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

        result = await client.get_routine("user1", "r1")
        assert result["id"] == "r1"
        assert result["name"] == "PPL"
        client.db.document.assert_called_with("users/user1/routines/r1")

    _run(_test())


def test_get_routine_not_found_raises():
    """get_routine raises when doc doesn't exist."""
    async def _test():
        client = FirestoreClient.__new__(FirestoreClient)
        mock_doc = _make_doc_snapshot(False)

        client.db = MagicMock()
        client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

        with pytest.raises(ValueError, match="not found"):
            await client.get_routine("user1", "nonexistent")

    _run(_test())


def test_get_user_attributes():
    """get_user_attributes reads from user_attributes subcollection."""
    async def _test():
        client = FirestoreClient.__new__(FirestoreClient)
        mock_doc = _make_doc_snapshot(True, "user1", {"fitness_level": "intermediate", "fitness_goal": "strength"})

        client.db = MagicMock()
        client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

        result = await client.get_user_attributes("user1")
        assert result["fitness_level"] == "intermediate"
        client.db.document.assert_called_with("users/user1/user_attributes/user1")

    _run(_test())


def test_get_user_attributes_not_found_returns_empty():
    """get_user_attributes returns empty dict when doc doesn't exist."""
    async def _test():
        client = FirestoreClient.__new__(FirestoreClient)
        mock_doc = _make_doc_snapshot(False)

        client.db = MagicMock()
        client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

        result = await client.get_user_attributes("user1")
        assert result == {}

    _run(_test())


def test_get_exercise_summary_uses_exercise_id():
    """get_exercise_summary uses exercise_id not exercise_name."""
    async def _test():
        client = FirestoreClient.__new__(FirestoreClient)
        mock_doc = _make_doc_snapshot(True, "bench_press_id", {"points_by_day": {"2026-03-01": 100}})

        client.db = MagicMock()
        client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

        result = await client.get_exercise_summary("user1", "bench_press_id")
        assert result["id"] == "bench_press_id"
        client.db.document.assert_called_with("users/user1/analytics_series_exercise/bench_press_id")

    _run(_test())


def test_conversation_collection_default():
    """Verify CONVERSATION_COLLECTION defaults to 'canvases'."""
    assert FirestoreClient.CONVERSATION_COLLECTION == "canvases"
