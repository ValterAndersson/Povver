import json
import pytest
from unittest.mock import AsyncMock, MagicMock

from app.context import RequestContext
from app.functional_handler import (
    FunctionalResult,
    execute_functional_lane,
    FUNCTIONAL_MODEL,
)
from app.llm.protocol import LLMChunk


@pytest.fixture
def ctx():
    return RequestContext(
        user_id="u1",
        conversation_id="c1",
        correlation_id="r1",
    )


@pytest.fixture
def workout_ctx():
    """Context with workout mode enabled."""
    return RequestContext(
        user_id="u1",
        conversation_id="c1",
        correlation_id="r1",
        workout_id="w1",
        workout_mode=True,
    )


def _make_llm_client(response_json: dict) -> AsyncMock:
    """Create a mock LLM client that streams a JSON response."""
    text = json.dumps(response_json)

    async def fake_stream(model, messages, tools=None, config=None):
        yield LLMChunk(text=text)
        yield LLMChunk(usage={"input_tokens": 10, "output_tokens": 5})

    client = AsyncMock()
    client.stream = MagicMock(side_effect=fake_stream)
    return client


def _make_tool_executor(**tool_returns) -> AsyncMock:
    """Create a mock tool_executor that returns preset values per tool name."""
    async def executor(name: str, args: dict, ctx: RequestContext):
        if name in tool_returns:
            return tool_returns[name]
        return {"error": f"Unknown tool: {name}"}
    return AsyncMock(side_effect=executor)


# ---------------------------------------------------------------------------
# Unknown intent
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_unknown_intent_returns_error(ctx):
    llm = _make_llm_client({})
    result = await execute_functional_lane("UNKNOWN", {}, ctx, llm)
    assert result.success is False
    assert result.action == "ERROR"
    assert "Unknown intent" in result.data["message"]


# ---------------------------------------------------------------------------
# SWAP_EXERCISE
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_swap_exercise_missing_target(ctx):
    llm = _make_llm_client({})
    tool_exec = _make_tool_executor()
    result = await execute_functional_lane(
        "SWAP_EXERCISE", {"constraint": "machine"}, ctx, llm,
        tool_executor=tool_exec,
    )
    assert result.success is False
    assert "Missing target" in result.data["message"]


@pytest.mark.asyncio
async def test_swap_exercise_no_alternatives(ctx):
    llm = _make_llm_client({})
    tool_exec = _make_tool_executor(search_exercises={"items": []})
    result = await execute_functional_lane(
        "SWAP_EXERCISE",
        {"target": "Bench Press", "muscle_group": "chest"},
        ctx, llm,
        tool_executor=tool_exec,
    )
    assert result.success is False
    assert "No alternatives" in result.data["message"]


@pytest.mark.asyncio
async def test_swap_exercise_success(ctx):
    llm = _make_llm_client({
        "action": "REPLACE_EXERCISE",
        "data": {"old_exercise": "Bench Press", "new_exercise": {"name": "Machine Press"}},
    })
    tool_exec = _make_tool_executor(
        search_exercises={"items": [{"name": "Machine Press", "id": "ex1"}]},
    )
    result = await execute_functional_lane(
        "SWAP_EXERCISE",
        {"target": "Bench Press", "constraint": "machine", "muscle_group": "chest"},
        ctx, llm,
        tool_executor=tool_exec,
    )
    assert result.success is True
    assert result.action == "REPLACE_EXERCISE"
    assert result.intent == "SWAP_EXERCISE"


@pytest.mark.asyncio
async def test_swap_exercise_llm_failure_falls_back(ctx):
    """When LLM returns invalid JSON, handler falls back to first alternative."""
    async def bad_stream(model, messages, tools=None, config=None):
        yield LLMChunk(text="not json")

    client = AsyncMock()
    client.stream = MagicMock(side_effect=bad_stream)

    tool_exec = _make_tool_executor(
        search_exercises={"items": [{"name": "Cable Fly", "id": "ex2"}]},
    )
    result = await execute_functional_lane(
        "SWAP_EXERCISE",
        {"target": "Bench Press", "muscle_group": "chest"},
        ctx, client,
        tool_executor=tool_exec,
    )
    assert result.success is True
    assert result.data.get("fallback") is True
    assert result.data["new_exercise"]["name"] == "Cable Fly"


# ---------------------------------------------------------------------------
# AUTOFILL_SET
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_autofill_set_with_last_weight(ctx):
    llm = _make_llm_client({})
    result = await execute_functional_lane(
        "AUTOFILL_SET",
        {"exercise_id": "ex1", "set_index": 1, "target_reps": 10, "last_weight": 80},
        ctx, llm,
    )
    assert result.success is True
    assert result.action == "AUTOFILL"
    assert result.data["predicted_weight"] == 80
    assert result.data["predicted_reps"] == 10


@pytest.mark.asyncio
async def test_autofill_set_no_last_weight(ctx):
    llm = _make_llm_client({})
    result = await execute_functional_lane(
        "AUTOFILL_SET",
        {"exercise_id": "ex1", "set_index": 0, "target_reps": 8},
        ctx, llm,
    )
    assert result.success is True
    assert result.data["predicted_weight"] is None


# ---------------------------------------------------------------------------
# SUGGEST_WEIGHT
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_suggest_weight_missing_exercise_id(ctx):
    llm = _make_llm_client({})
    result = await execute_functional_lane(
        "SUGGEST_WEIGHT", {"target_reps": 8}, ctx, llm,
    )
    assert result.success is False
    assert "Missing exercise_id" in result.data["message"]


@pytest.mark.asyncio
async def test_suggest_weight_no_history(ctx):
    llm = _make_llm_client({})
    tool_exec = _make_tool_executor(get_exercise_progress={})
    result = await execute_functional_lane(
        "SUGGEST_WEIGHT",
        {"exercise_id": "ex1", "target_reps": 8},
        ctx, llm,
        tool_executor=tool_exec,
    )
    assert result.success is False
    assert "Could not fetch" in result.data["message"]


@pytest.mark.asyncio
async def test_suggest_weight_success(ctx):
    llm = _make_llm_client({
        "action": "SUGGEST",
        "data": {"weight_kg": 85, "confidence": "high", "rationale": "Based on trend"},
    })
    tool_exec = _make_tool_executor(
        get_exercise_progress={"points_by_day": [{"date": "2026-03-10", "e1rm": 100}]},
    )
    result = await execute_functional_lane(
        "SUGGEST_WEIGHT",
        {"exercise_id": "ex1", "target_reps": 8, "target_rir": 2},
        ctx, llm,
        tool_executor=tool_exec,
    )
    assert result.success is True
    assert result.data["weight_kg"] == 85


# ---------------------------------------------------------------------------
# MONITOR_STATE
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_monitor_state_no_intervention(ctx):
    llm = _make_llm_client({"action": "NULL", "data": None})
    result = await execute_functional_lane(
        "MONITOR_STATE",
        {"event_type": "SET_COMPLETED", "state_diff": {"reps": 8}},
        ctx, llm,
    )
    assert result.success is True
    assert result.action == "NULL"
    assert result.data is None


@pytest.mark.asyncio
async def test_monitor_state_nudge(ctx):
    llm = _make_llm_client({
        "action": "NUDGE",
        "data": {"message": "Weight dropped significantly", "severity": "warning"},
    })
    result = await execute_functional_lane(
        "MONITOR_STATE",
        {"event_type": "SET_COMPLETED", "state_diff": {"weight_drop": 20}},
        ctx, llm,
    )
    assert result.success is True
    assert result.action == "NUDGE"
    assert result.data["severity"] == "warning"


@pytest.mark.asyncio
async def test_monitor_state_llm_error_fails_silently(ctx):
    """Monitor should never interrupt workout — errors return NULL."""
    async def error_stream(model, messages, tools=None, config=None):
        yield LLMChunk(text="not json at all {{{")

    client = AsyncMock()
    client.stream = MagicMock(side_effect=error_stream)

    result = await execute_functional_lane(
        "MONITOR_STATE",
        {"event_type": "SET_COMPLETED", "state_diff": {}},
        ctx, client,
    )
    assert result.success is True
    assert result.action == "NULL"


# ---------------------------------------------------------------------------
# FunctionalResult.to_dict
# ---------------------------------------------------------------------------

def test_functional_result_to_dict():
    r = FunctionalResult(success=True, action="TEST", data={"k": "v"}, intent="X")
    d = r.to_dict()
    assert d == {"success": True, "action": "TEST", "data": {"k": "v"}, "intent": "X"}


# ---------------------------------------------------------------------------
# Handler exception is caught
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_handler_exception_returns_error(ctx):
    """If tool_executor raises, the top-level catch returns an error result."""
    async def exploding_executor(name, args, c):
        raise RuntimeError("boom")

    llm = _make_llm_client({})
    result = await execute_functional_lane(
        "SWAP_EXERCISE",
        {"target": "Bench Press"},
        ctx, llm,
        tool_executor=exploding_executor,
    )
    assert result.success is False
    assert "boom" in result.data["message"]


# ---------------------------------------------------------------------------
# No tool_executor provided — intents that need tools should error
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_no_tool_executor_swap_errors(ctx):
    """SWAP_EXERCISE without tool_executor raises via noop executor."""
    llm = _make_llm_client({})
    result = await execute_functional_lane(
        "SWAP_EXERCISE",
        {"target": "Bench Press"},
        ctx, llm,
        # tool_executor omitted — uses noop default
    )
    assert result.success is False
    assert "No tool_executor" in result.data["message"]
