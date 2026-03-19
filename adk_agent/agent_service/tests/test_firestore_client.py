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
    """Verify FirestoreClient creates an AsyncClient and FunctionsClient."""
    with patch("app.firestore_client.AsyncClient") as mock_async, \
         patch("app.firestore_client.get_functions_client") as mock_http:
        client = FirestoreClient()
        mock_async.assert_called_once()
        mock_http.assert_called_once()
        assert client._http is mock_http.return_value


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


def test_conversation_collection_default():
    """Verify CONVERSATION_COLLECTION defaults to 'conversations'."""
    assert FirestoreClient.CONVERSATION_COLLECTION == "conversations"
