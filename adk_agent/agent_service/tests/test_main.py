# tests/test_main.py
import pytest
from httpx import AsyncClient, ASGITransport
from app.main import app


@pytest.mark.asyncio
async def test_health_endpoint():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_stream_missing_fields():
    """POST /stream with missing required fields returns 400."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post("/stream", json={"user_id": "u1"})
        assert resp.status_code == 400
        assert "required" in resp.json()["error"]


@pytest.mark.asyncio
async def test_stream_invalid_json():
    """POST /stream with invalid JSON returns 400."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post(
            "/stream",
            content="not json",
            headers={"content-type": "application/json"},
        )
        assert resp.status_code == 400


@pytest.mark.asyncio
async def test_format_history():
    """_format_history converts Firestore message types to LLM roles."""
    from app.main import _format_history
    messages = [
        {"type": "user_prompt", "content": "Hi"},
        {"type": "agent_response", "content": "Hello!"},
        {"type": "artifact", "content": "{}"},  # Filtered out
    ]
    result = _format_history(messages)
    assert len(result) == 2
    assert result[0] == {"role": "user", "content": "Hi"}
    assert result[1] == {"role": "assistant", "content": "Hello!"}
