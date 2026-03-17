# tests/test_llm_protocol.py
import pytest
from app.llm.protocol import LLMChunk, ToolCallChunk


def test_text_chunk():
    chunk = LLMChunk(text="hello")
    assert chunk.is_text is True
    assert chunk.is_tool_call is False
    assert chunk.text == "hello"


def test_tool_call_chunk():
    tc = ToolCallChunk(call_id="c1", tool_name="get_routine", args={"routine_id": "r1"})
    chunk = LLMChunk(tool_call=tc)
    assert chunk.is_text is False
    assert chunk.is_tool_call is True
    assert chunk.tool_call.tool_name == "get_routine"


def test_llm_client_protocol_exists():
    from app.llm.protocol import LLMClient
    import inspect
    assert hasattr(LLMClient, 'stream')


def test_model_config_defaults():
    from app.llm.protocol import ModelConfig
    config = ModelConfig()
    assert config.temperature == 0.3
    assert config.max_output_tokens == 8192
