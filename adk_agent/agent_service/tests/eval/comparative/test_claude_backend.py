# test_claude_backend.py
import json
import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from comparative.backends.claude_backend import execute_mcp_tool

@pytest.mark.asyncio
async def test_execute_mcp_tool_formats_jsonrpc():
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = MagicMock()
    mock_response.json = lambda: {
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": '{"e1rm": 120}'}]},
        "id": 1,
    }

    with patch("comparative.backends.claude_backend.httpx.AsyncClient") as MockClient:
        mock_client_instance = AsyncMock()
        mock_client_instance.post = AsyncMock(return_value=mock_response)
        mock_client_instance.__aenter__ = AsyncMock(return_value=mock_client_instance)
        mock_client_instance.__aexit__ = AsyncMock(return_value=None)
        MockClient.return_value = mock_client_instance

        result = await execute_mcp_tool(
            mcp_url="https://mcp.example.com",
            api_key="test-key",
            tool_name="get_exercise_progress",
            arguments={"exercise": "bench press", "weeks": 8},
        )
        call_args = mock_client_instance.post.call_args
        call_body = call_args[1]["json"] if "json" in call_args[1] else call_args[0][1] if len(call_args[0]) > 1 else None
        # Check the JSON-RPC format
        assert call_body["jsonrpc"] == "2.0"
        assert call_body["method"] == "tools/call"
        assert call_body["params"]["name"] == "get_exercise_progress"
        assert result == '{"e1rm": 120}'
