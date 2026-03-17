# tests/test_registry.py
import pytest
from unittest.mock import AsyncMock
from app.tools.registry import register_tool, execute_tool, get_tools, _TOOL_REGISTRY
from app.context import RequestContext
from app.llm.protocol import ToolDef


@pytest.fixture(autouse=True)
def clear_registry():
    """Clear the tool registry before each test."""
    _TOOL_REGISTRY.clear()
    yield
    _TOOL_REGISTRY.clear()


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


def test_register_tool():
    async def my_tool(*, ctx, **kwargs):
        return {"ok": True}

    register_tool("my_tool", my_tool, "A test tool", {"type": "object", "properties": {}})
    assert "my_tool" in _TOOL_REGISTRY
    assert _TOOL_REGISTRY["my_tool"]["def"].name == "my_tool"


@pytest.mark.asyncio
async def test_execute_tool(ctx):
    async def greet(*, ctx, name="world"):
        return {"message": f"Hello, {name}!"}

    register_tool("greet", greet, "Greet someone", {"type": "object", "properties": {"name": {"type": "string"}}})
    result = await execute_tool("greet", {"name": "Val"}, ctx)
    assert result["message"] == "Hello, Val!"


@pytest.mark.asyncio
async def test_execute_unknown_tool(ctx):
    result = await execute_tool("nonexistent", {}, ctx)
    assert "error" in result


def test_get_tools_returns_all():
    async def t1(*, ctx): return {}
    async def t2(*, ctx): return {}

    register_tool("tool_a", t1, "Tool A", {})
    register_tool("tool_b", t2, "Tool B", {})

    ctx = RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")
    tools = get_tools(ctx)
    assert len(tools) == 2
    assert all(isinstance(t, ToolDef) for t in tools)


def test_get_tools_workout_mode_bans():
    async def banned(*, ctx): return {}
    async def allowed(*, ctx): return {}

    register_tool("get_planning_context", banned, "Planning", {})
    register_tool("get_workout_state", allowed, "Workout state", {})

    ctx = RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1", workout_mode=True)
    tools = get_tools(ctx)
    names = [t.name for t in tools]
    assert "get_planning_context" not in names
    assert "get_workout_state" in names
