# app/agent_loop.py
"""Core agent loop — replaces ADK's Runner.

Emits all 9 SSE event types:
- message, tool_start, tool_end, done — directly from the loop
- artifact, clarification — detected from tool return values
- status — emitted at tool call start based on TOOL_STATUS_MAP
- heartbeat — background task during LLM streaming
- error — try/catch around the entire loop
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable, Awaitable

from app.context import RequestContext
from app.llm.protocol import LLMClient, ModelConfig, ToolDef
from app.observability import log_tokens, log_tool_call, set_trace_id

logger = logging.getLogger(__name__)

MAX_TOOL_TURNS = 12
HEARTBEAT_INTERVAL_S = 15

# Tool name -> user-facing status message for iOS status events
TOOL_STATUS_MAP = {
    "get_planning_context": "Reviewing your training profile...",
    "get_muscle_group_progress": "Analyzing muscle group data...",
    "get_exercise_progress": "Looking at exercise history...",
    "query_training_sets": "Querying your training sets...",
    "get_training_analysis": "Loading training analysis...",
    "propose_workout": "Building your workout...",
    "propose_routine": "Designing your routine...",
    "search_exercises": "Searching exercise catalog...",
    "get_workout_state": "Checking current workout...",
}


@dataclass
class SSEEvent:
    event: str
    data: str

    def encode(self) -> str:
        return f"event: {self.event}\ndata: {self.data}\n\n"


def sse_event(event: str, data: Any) -> SSEEvent:
    if isinstance(data, str):
        return SSEEvent(event=event, data=json.dumps({"type": event, "text": data}))
    if isinstance(data, dict):
        return SSEEvent(event=event, data=json.dumps({"type": event, **data}))
    return SSEEvent(event=event, data=json.dumps({"type": event, "data": data}))


ToolExecutor = Callable[[str, dict, RequestContext], Awaitable[Any]]


def _inspect_tool_result(result: Any) -> tuple[list[SSEEvent], bool]:
    """Inspect a tool result for artifact or clarification side-effects.

    Returns (sse_side_effects, should_pause).
    - Artifacts: detected by 'artifact_type' key in result dict.
      Emits SSE artifact event matching the exact shape iOS expects.
    - Clarifications: detected by 'requires_confirmation' key.
      Emits SSE clarification event with id, question, options.
    """
    side_effects = []
    should_pause = False

    if not isinstance(result, dict):
        return side_effects, should_pause

    # Artifact detection (mirrors stream-agent-normalized.js artifact handling)
    # Artifact IS the response — pause the loop after emitting it so the LLM
    # can write one short confirmation sentence without further tool calls.
    if result.get("artifact_type"):
        artifact_id = result.get("artifact_id") or str(uuid.uuid4())
        side_effects.append(sse_event("artifact", {
            "artifact_type": result["artifact_type"],
            "artifact_id": artifact_id,
            "artifact_content": result.get("content", {}),
            "actions": result.get("actions", []),
            "status": result.get("status", "proposed"),
        }))
        should_pause = True

    # Safety gate / clarification detection
    if result.get("requires_confirmation"):
        side_effects.append(sse_event("clarification", {
            "id": result.get("confirmation_id", str(uuid.uuid4())),
            "question": result.get("question", ""),
            "options": result.get("options", []),
        }))
        should_pause = True

    return side_effects, should_pause


async def run_agent_loop(
    *,
    llm_client: LLMClient,
    model: str,
    instruction: str,
    history: list[dict],
    message: str,
    tools: list[ToolDef],
    tool_executor: ToolExecutor,
    ctx: RequestContext,
    fs: Any = None,  # FirestoreClient, optional for artifact persistence
    config: ModelConfig | None = None,
    max_tool_turns: int = MAX_TOOL_TURNS,
) -> AsyncIterator[SSEEvent]:
    """Run the agent loop: LLM -> tool calls -> LLM -> ... -> text response.

    Emits all 9 SSE event types. Artifact and clarification events are
    detected from tool return values via _inspect_tool_result().
    """

    # Ensure trace_id propagates into this async generator
    if ctx.correlation_id:
        set_trace_id(ctx.correlation_id)

    messages = _build_messages(instruction, history, message)
    turn = 0
    total_input_tokens = 0
    total_output_tokens = 0
    total_thinking_tokens = 0

    try:
        while turn < max_tool_turns:
            tool_calls = []
            last_usage = None

            # Start heartbeat during LLM streaming
            heartbeat_stop = asyncio.Event()
            heartbeat_task = asyncio.create_task(
                _heartbeat_loop(heartbeat_stop)
            )

            async for chunk in llm_client.stream(model, messages, tools, config):
                if chunk.usage:
                    last_usage = chunk.usage
                if chunk.is_text:
                    yield sse_event("message", chunk.text)
                elif chunk.is_tool_call:
                    tool_calls.append(chunk.tool_call)

            # Stop heartbeat
            heartbeat_stop.set()
            heartbeat_events = await heartbeat_task
            for hb in heartbeat_events:
                yield hb

            # Track token usage per LLM turn
            if last_usage:
                total_input_tokens += last_usage["input_tokens"]
                total_output_tokens += last_usage["output_tokens"]
                total_thinking_tokens += last_usage.get("thinking_tokens", 0)
                log_tokens(model, last_usage["input_tokens"], last_usage["output_tokens"])
                try:
                    from shared.usage_tracker import track_usage
                    track_usage(
                        user_id=ctx.user_id,
                        category="user_initiated",
                        system="agent_service",
                        feature="agent_loop",
                        model=model,
                        prompt_tokens=last_usage["input_tokens"],
                        completion_tokens=last_usage["output_tokens"],
                        total_tokens=last_usage["input_tokens"] + last_usage["output_tokens"],
                    )
                except ImportError:
                    pass  # shared module not available in test env

            # No tool calls — model is done
            if not tool_calls:
                yield sse_event("done", {"usage": {"input_tokens": total_input_tokens, "output_tokens": total_output_tokens, "thinking_tokens": total_thinking_tokens}})
                return

            # Execute all tool calls from this turn
            for tc in tool_calls:
                # Emit status event for user-facing progress
                status_msg = TOOL_STATUS_MAP.get(tc.tool_name)
                if status_msg:
                    yield sse_event("status", {"text": status_msg})

                yield sse_event("tool_start", {"tool": tc.tool_name, "call_id": tc.call_id})
                start = time.monotonic()
                tool_success = True
                tool_error = ""
                try:
                    result = await tool_executor(tc.tool_name, tc.args, ctx)
                except Exception as e:
                    tool_success = False
                    tool_error = str(e)
                    logger.warning("Tool %s failed: %s", tc.tool_name, e)
                    result = {"error": str(e)}
                elapsed_ms = int((time.monotonic() - start) * 1000)
                log_tool_call(tc.tool_name, elapsed_ms, tool_success, tool_error)
                yield sse_event("tool_end", {"tool": tc.tool_name, "call_id": tc.call_id, "elapsed_ms": elapsed_ms})

                # Inspect tool result for artifact/clarification side-effects
                side_effects, should_pause = _inspect_tool_result(result)
                for evt in side_effects:
                    yield evt

                # After artifact or clarification, allow one final text-only
                # LLM turn (no tools) for a brief confirmation message, then stop.
                if should_pause:
                    logger.info("Pausing after %s (artifact/clarification emitted)", tc.tool_name)
                    # Give the LLM the tool result so it can write a confirmation
                    messages.append({
                        "role": "tool",
                        "tool_name": tc.tool_name,
                        "tool_call_id": tc.call_id,
                        "tool_result": {"status": "ok", "delivered": True},
                    })
                    # One final text-only turn (no tools = can't loop further)
                    async for chunk in llm_client.stream(model, messages, None, config):
                        if chunk.usage:
                            total_input_tokens += chunk.usage["input_tokens"]
                            total_output_tokens += chunk.usage["output_tokens"]
                            total_thinking_tokens += chunk.usage.get("thinking_tokens", 0)
                            log_tokens(model, chunk.usage["input_tokens"], chunk.usage["output_tokens"])
                        if chunk.is_text:
                            yield sse_event("message", chunk.text)
                    yield sse_event("done", {"usage": {"input_tokens": total_input_tokens, "output_tokens": total_output_tokens, "thinking_tokens": total_thinking_tokens}})
                    return

                # Append tool result to messages for next LLM turn
                messages.append({
                    "role": "tool",
                    "tool_name": tc.tool_name,
                    "tool_call_id": tc.call_id,
                    "tool_result": result,
                })

            turn += 1

        # Exceeded max turns
        yield sse_event("message", "I've reached my reasoning limit for this request. "
                                   "Please try rephrasing or breaking your question into parts.")
        yield sse_event("done", {"usage": {"input_tokens": total_input_tokens, "output_tokens": total_output_tokens, "thinking_tokens": total_thinking_tokens}})

    except Exception as e:
        logger.exception("Agent loop error")
        yield sse_event("error", {"code": "AGENT_ERROR", "message": "An internal error occurred"})


async def _heartbeat_loop(stop: asyncio.Event) -> list[SSEEvent]:
    """Emit heartbeat events every HEARTBEAT_INTERVAL_S until stopped.

    Returns collected heartbeat events (yielded by caller after LLM stream ends).
    In production, these should be yielded during streaming via an async queue;
    this simplified version collects them for the caller to yield.
    """
    events = []
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), timeout=HEARTBEAT_INTERVAL_S)
            break  # stop was set
        except asyncio.TimeoutError:
            events.append(sse_event("heartbeat", {}))
    return events


def _build_messages(instruction: str, history: list[dict], message: str) -> list[dict]:
    """Build the message list for the LLM."""
    messages = []
    if instruction:
        messages.append({"role": "system", "content": instruction})
    messages.extend(history)
    messages.append({"role": "user", "content": message})
    return messages
