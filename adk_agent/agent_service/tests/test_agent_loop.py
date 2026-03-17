# tests/test_agent_loop.py
import pytest
import json
from unittest.mock import AsyncMock, MagicMock, patch
from app.agent_loop import run_agent_loop, SSEEvent
from app.llm.protocol import LLMChunk, ToolCallChunk, ModelConfig, ToolDef
from app.context import RequestContext


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


class FakeLLMClient:
    """LLM client that returns a scripted sequence of responses."""

    def __init__(self, turns: list[list[LLMChunk]]):
        self.turns = iter(turns)

    async def stream(self, model, messages, tools=None, config=None):
        for chunk in next(self.turns):
            yield chunk


@pytest.mark.asyncio
async def test_text_only_response(ctx):
    """LLM returns text, no tool calls — single turn."""
    client = FakeLLMClient([[LLMChunk(text="Hello!")]])

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="You are a coach",
        history=[],
        message="Hi",
        tools=[],
        tool_executor=AsyncMock(),
        ctx=ctx,
    ):
        events.append(event)

    assert any(e.event == "message" and "Hello" in e.data for e in events)
    assert events[-1].event == "done"


@pytest.mark.asyncio
async def test_tool_call_then_response(ctx):
    """LLM calls a tool, gets result, then responds with text."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "get_routine", {"routine_id": "r1"}))],
        [LLMChunk(text="Your routine is PPL")],
    ])

    async def mock_executor(tool_name, args, context):
        return {"name": "PPL", "template_ids": ["t1", "t2"]}

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="You are a coach",
        history=[],
        message="What's my routine?",
        tools=[ToolDef("get_routine", "Get routine", {})],
        tool_executor=mock_executor,
        ctx=ctx,
    ):
        events.append(event)

    event_types = [e.event for e in events]
    assert "tool_start" in event_types
    assert "tool_end" in event_types
    assert "message" in event_types
    assert events[-1].event == "done"


@pytest.mark.asyncio
async def test_tool_error_returned_to_model(ctx):
    """Tool raises exception — error is returned to model for recovery."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "get_routine", {"routine_id": "bad"}))],
        [LLMChunk(text="Sorry, I couldn't find that routine.")],
    ])

    async def failing_executor(tool_name, args, context):
        raise ValueError("Routine not found")

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Get my routine",
        tools=[ToolDef("get_routine", "Get routine", {})],
        tool_executor=failing_executor,
        ctx=ctx,
    ):
        events.append(event)

    assert events[-1].event == "done"
    assert any(e.event == "message" for e in events)


@pytest.mark.asyncio
async def test_max_turns_guard(ctx):
    """Agent loop terminates after max_tool_turns."""
    infinite_tools = [[LLMChunk(tool_call=ToolCallChunk(f"c{i}", "noop", {}))]
                      for i in range(20)]
    client = FakeLLMClient(infinite_tools)

    async def noop_executor(tool_name, args, context):
        return {"ok": True}

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Loop forever",
        tools=[ToolDef("noop", "Do nothing", {})],
        tool_executor=noop_executor,
        ctx=ctx,
        max_tool_turns=3,
    ):
        events.append(event)

    tool_starts = [e for e in events if e.event == "tool_start"]
    assert len(tool_starts) == 3
    assert events[-1].event == "done"


@pytest.mark.asyncio
async def test_status_event_emitted_for_known_tools(ctx):
    """Known tools emit a status event before tool_start."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "get_planning_context", {}))],
        [LLMChunk(text="Done")],
    ])

    async def mock_executor(tool_name, args, context):
        return {"context": "data"}

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Show training",
        tools=[ToolDef("get_planning_context", "Get context", {})],
        tool_executor=mock_executor,
        ctx=ctx,
    ):
        events.append(event)

    event_types = [e.event for e in events]
    assert "status" in event_types
    # Status should appear before tool_start for this tool
    status_idx = event_types.index("status")
    tool_start_idx = event_types.index("tool_start")
    assert status_idx < tool_start_idx


@pytest.mark.asyncio
async def test_artifact_detection(ctx):
    """Tool result with artifact_type emits artifact SSE event."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "propose_workout", {}))],
        [LLMChunk(text="Here's your workout")],
    ])

    async def artifact_executor(tool_name, args, context):
        return {
            "artifact_type": "session_plan",
            "content": {"exercises": []},
            "actions": ["start_workout", "dismiss"],
            "status": "proposed",
        }

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Build workout",
        tools=[ToolDef("propose_workout", "Build workout", {})],
        tool_executor=artifact_executor,
        ctx=ctx,
    ):
        events.append(event)

    artifact_events = [e for e in events if e.event == "artifact"]
    assert len(artifact_events) == 1
    artifact_data = json.loads(artifact_events[0].data)
    assert artifact_data["artifact_type"] == "session_plan"
    assert "artifact_id" in artifact_data


@pytest.mark.asyncio
async def test_clarification_detection(ctx):
    """Tool result with requires_confirmation emits clarification event."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "delete_routine", {}))],
        [LLMChunk(text="Waiting for confirmation")],
    ])

    async def confirm_executor(tool_name, args, context):
        return {
            "requires_confirmation": True,
            "question": "Delete routine PPL?",
            "options": ["Yes", "No"],
        }

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Delete my routine",
        tools=[ToolDef("delete_routine", "Delete routine", {})],
        tool_executor=confirm_executor,
        ctx=ctx,
    ):
        events.append(event)

    clarification_events = [e for e in events if e.event == "clarification"]
    assert len(clarification_events) == 1
    data = json.loads(clarification_events[0].data)
    assert data["question"] == "Delete routine PPL?"


@pytest.mark.asyncio
async def test_error_event_on_exception(ctx):
    """Unhandled exception in agent loop emits error event."""
    class BrokenLLMClient:
        async def stream(self, model, messages, tools=None, config=None):
            raise RuntimeError("Model unavailable")
            yield  # Make it a generator

    events = []
    async for event in run_agent_loop(
        llm_client=BrokenLLMClient(),
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Hi",
        tools=[],
        tool_executor=AsyncMock(),
        ctx=ctx,
    ):
        events.append(event)

    error_events = [e for e in events if e.event == "error"]
    assert len(error_events) == 1
    error_data = json.loads(error_events[0].data)
    assert error_data["code"] == "AGENT_ERROR"


@pytest.mark.asyncio
async def test_sse_event_encode():
    """SSEEvent.encode() produces valid SSE format."""
    event = SSEEvent(event="message", data='{"text": "hello"}')
    encoded = event.encode()
    assert encoded == 'event: message\ndata: {"text": "hello"}\n\n'
