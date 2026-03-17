import pytest
from unittest.mock import AsyncMock, MagicMock
from app.memory import MemoryManager


@pytest.mark.asyncio
async def test_save_memory():
    mm = MemoryManager.__new__(MemoryManager)
    mock_ref = AsyncMock()
    mock_ref.__getitem__ = MagicMock(return_value=MagicMock(id="mem1"))
    mm.db = MagicMock()
    mm.db.collection.return_value.add = AsyncMock(return_value=mock_ref)

    result = await mm.save_memory("u1", "Prefers 4-day splits", "preference", "conv1")
    assert result["content"] == "Prefers 4-day splits"
    assert result["category"] == "preference"


@pytest.mark.asyncio
async def test_retire_memory():
    mm = MemoryManager.__new__(MemoryManager)
    mock_doc = AsyncMock()
    mock_doc.exists = True
    mm.db = MagicMock()
    mm.db.document.return_value.get = AsyncMock(return_value=mock_doc)
    mm.db.document.return_value.update = AsyncMock()

    result = await mm.retire_memory("u1", "mem1", "Contradicted by user")
    assert result["retired"] is True


@pytest.mark.asyncio
async def test_retire_memory_not_found():
    mm = MemoryManager.__new__(MemoryManager)
    mock_doc = AsyncMock()
    mock_doc.exists = False
    mm.db = MagicMock()
    mm.db.document.return_value.get = AsyncMock(return_value=mock_doc)

    result = await mm.retire_memory("u1", "missing", "reason")
    assert "error" in result


@pytest.mark.asyncio
async def test_list_active_memories():
    mm = MemoryManager.__new__(MemoryManager)
    mm.db = MagicMock()

    mock_docs = []
    for i in range(3):
        doc = MagicMock()
        doc.id = f"mem{i}"
        doc.to_dict.return_value = {"content": f"Memory {i}", "category": "preference", "active": True}
        mock_docs.append(doc)

    async def mock_stream():
        for doc in mock_docs:
            yield doc

    mm.db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream = mock_stream

    result = await mm.list_active_memories("u1", limit=50)
    assert len(result) == 3
    assert result[0]["content"] == "Memory 0"
