# app/functional_handler.py
"""Functional Handler — smart-button logic using LLMClient abstraction.

Migrated from canvas_orchestrator/app/shell/functional_handler.py.
Changes:
- Vertex AI / google-genai replaced with LLMClient protocol.
- SessionContext replaced with RequestContext.
- No singleton — caller passes dependencies explicitly.
- FirestoreClient replaced with tool_executor callback (same pattern as agent_loop.py).
- Usage tracking via shared.usage_tracker (optional import).

Lane 3: Functional Lane
- Input: JSON payload with intent and data
- Model: configurable via FUNCTIONAL_MODEL env var or parameter
- Output: Structured JSON (no chat text)
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from app.context import RequestContext
from app.llm.protocol import LLMClient, LLMChunk, ModelConfig

logger = logging.getLogger(__name__)

# Model configuration
FUNCTIONAL_MODEL = os.getenv("FUNCTIONAL_MODEL", "gemini-3-flash-preview")
FUNCTIONAL_TEMPERATURE = 0.0

# System instruction for JSON-only output
FUNCTIONAL_INSTRUCTION = """You are a logic engine for a fitness app.
You process structured requests and output ONLY valid JSON.
No chat text. No explanations. No markdown.

Output format: {"action": "...", "data": {...}}

If you cannot complete the request, output: {"action": "ERROR", "data": {"message": "..."}}
"""

# Type alias matching agent_loop.py
ToolExecutor = Callable[[str, dict, RequestContext], Awaitable[Any]]


@dataclass
class FunctionalResult:
    """Result from functional handler."""
    success: bool
    action: str
    data: dict[str, Any]
    intent: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "success": self.success,
            "action": self.action,
            "data": self.data,
            "intent": self.intent,
        }


async def _collect_stream(
    llm_client: LLMClient,
    model: str,
    prompt: str,
) -> tuple[str, dict | None]:
    """Send a single-message prompt and collect the full text response.

    Uses json_mode for deterministic structured output.

    Returns:
        Tuple of (response_text, usage_dict_or_None).
    """
    messages = [
        {"role": "system", "content": FUNCTIONAL_INSTRUCTION},
        {"role": "user", "content": prompt},
    ]
    config = ModelConfig(
        temperature=FUNCTIONAL_TEMPERATURE,
        json_mode=True,
    )

    parts: list[str] = []
    usage: dict | None = None
    async for chunk in llm_client.stream(
        model=model,
        messages=messages,
        config=config,
    ):
        if chunk.text:
            parts.append(chunk.text)
        if chunk.usage:
            usage = chunk.usage

    return "".join(parts), usage


def _track_usage(
    ctx: RequestContext,
    model: str,
    usage: dict | None,
    feature: str = "functional",
) -> None:
    """Track LLM token usage (fire-and-forget, non-fatal)."""
    if not usage:
        return
    try:
        from shared.usage_tracker import track_usage
        track_usage(
            user_id=ctx.user_id,
            category="user_initiated",
            system="agent_service",
            feature=feature,
            model=model,
            prompt_tokens=usage.get("input_tokens", 0),
            completion_tokens=usage.get("output_tokens", 0),
            total_tokens=usage.get("input_tokens", 0) + usage.get("output_tokens", 0),
        )
    except ImportError:
        pass  # shared module not available in test env
    except Exception as e:
        logger.debug("Usage tracking error (non-fatal): %s", e)


async def _handle_swap_exercise(
    payload: dict[str, Any],
    ctx: RequestContext,
    llm_client: LLMClient,
    model: str,
    tool_executor: ToolExecutor,
) -> FunctionalResult:
    """Handle SWAP_EXERCISE intent.

    Finds alternative exercise matching the constraint (e.g., "machine").
    Uses tool_executor to call search_exercises + LLM to pick best match.
    """
    target = payload.get("target", "")
    constraint = payload.get("constraint", "")
    muscle_group = payload.get("muscle_group", "")

    if not target:
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": "Missing target exercise"},
            intent="SWAP_EXERCISE",
        )

    # Search for alternatives via tool_executor
    search_query = f"{muscle_group} {constraint}".strip() or target
    search_result = await tool_executor(
        "search_exercises",
        {"query": search_query, "limit": 10},
        ctx,
    )

    # Extract items from tool result (handles both dict and list returns)
    if isinstance(search_result, dict):
        alternatives = search_result.get("exercises", search_result.get("items", []))
    elif isinstance(search_result, list):
        alternatives = search_result
    else:
        alternatives = []

    if not alternatives:
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": "No alternatives found"},
            intent="SWAP_EXERCISE",
        )

    # Use LLM to select best match
    prompt = f"""Select the best alternative to replace "{target}".
Constraint: {constraint or 'any equipment'}
Target muscle: {muscle_group or 'same as original'}

Available alternatives:
{json.dumps(alternatives, indent=2)}

Select ONE exercise. Output:
{{"action": "REPLACE_EXERCISE", "data": {{"old_exercise": "{target}", "new_exercise": {{...}}}}}}
"""

    try:
        text, usage = await _collect_stream(llm_client, model, prompt)
        _track_usage(ctx, model, usage, "functional_swap")
        result = json.loads(text)
        return FunctionalResult(
            success=True,
            action=result.get("action", "REPLACE_EXERCISE"),
            data=result.get("data", {}),
            intent="SWAP_EXERCISE",
        )
    except Exception as e:
        logger.error("LLM call failed for SWAP_EXERCISE: %s", e)
        # Fallback: return first alternative
        return FunctionalResult(
            success=True,
            action="REPLACE_EXERCISE",
            data={
                "old_exercise": target,
                "new_exercise": alternatives[0],
                "fallback": True,
            },
            intent="SWAP_EXERCISE",
        )


async def _handle_autofill_set(
    payload: dict[str, Any],
    ctx: RequestContext,
    llm_client: LLMClient,
    model: str,
    tool_executor: ToolExecutor,
) -> FunctionalResult:
    """Handle AUTOFILL_SET intent.

    Predicts values for the next set based on history and targets.
    """
    exercise_id = payload.get("exercise_id", "")
    set_index = payload.get("set_index", 0)
    target_reps = payload.get("target_reps", 8)
    last_weight = payload.get("last_weight")

    if last_weight:
        predicted_weight = last_weight
    else:
        predicted_weight = None

    return FunctionalResult(
        success=True,
        action="AUTOFILL",
        data={
            "exercise_id": exercise_id,
            "set_index": set_index,
            "predicted_weight": predicted_weight,
            "predicted_reps": target_reps,
        },
        intent="AUTOFILL_SET",
    )


async def _handle_suggest_weight(
    payload: dict[str, Any],
    ctx: RequestContext,
    llm_client: LLMClient,
    model: str,
    tool_executor: ToolExecutor,
) -> FunctionalResult:
    """Handle SUGGEST_WEIGHT intent.

    Suggests weight based on recent performance and target RIR.
    Uses tool_executor to call get_exercise_progress.
    """
    exercise_id = payload.get("exercise_id", "")
    target_reps = payload.get("target_reps", 8)
    target_rir = payload.get("target_rir", 2)

    if not exercise_id:
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": "Missing exercise_id"},
            intent="SUGGEST_WEIGHT",
        )

    # Get exercise progress via tool_executor
    progress = await tool_executor(
        "get_exercise_progress",
        {"exercise_id": exercise_id, "window_weeks": 4},
        ctx,
    )

    if not progress or (isinstance(progress, dict) and not progress.get("points_by_day")):
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": "Could not fetch exercise history"},
            intent="SUGGEST_WEIGHT",
        )

    # Use LLM to calculate suggestion
    prompt = f"""Suggest weight for exercise based on recent data.
Target: {target_reps} reps @ RIR {target_rir}
Recent performance: {json.dumps(progress, indent=2, default=str)}

Calculate appropriate weight. Output:
{{"action": "SUGGEST", "data": {{"weight_kg": <number>, "confidence": "high/medium/low", "rationale": "..."}}}}
"""

    try:
        text, usage = await _collect_stream(llm_client, model, prompt)
        _track_usage(ctx, model, usage, "functional_suggest")
        result = json.loads(text)
        return FunctionalResult(
            success=True,
            action=result.get("action", "SUGGEST"),
            data=result.get("data", {}),
            intent="SUGGEST_WEIGHT",
        )
    except Exception as e:
        logger.error("LLM suggestion failed: %s", e)
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": "Could not calculate suggestion"},
            intent="SUGGEST_WEIGHT",
        )


async def _handle_monitor_state(
    payload: dict[str, Any],
    ctx: RequestContext,
    llm_client: LLMClient,
    model: str,
    tool_executor: ToolExecutor,
) -> FunctionalResult:
    """Handle MONITOR_STATE intent (Silent Observer).

    Analyzes workout state diff and decides if intervention is needed.
    Returns null data if no intervention required.
    """
    event_type = payload.get("event_type", "")
    state_diff = payload.get("state_diff", {})

    prompt = f"""Analyze this workout state change. Decide if user intervention is STRICTLY necessary.

Event: {event_type}
State diff: {json.dumps(state_diff, indent=2)}

Intervention is needed ONLY for:
- Form concerns (excessive weight drop between sets)
- Fatigue signals (RIR consistently higher than planned)
- Safety concerns (too many failure sets)

If intervention needed, output:
{{"action": "NUDGE", "data": {{"message": "...", "severity": "info/warning/alert"}}}}

If NO intervention needed, output:
{{"action": "NULL", "data": null}}
"""

    try:
        text, usage = await _collect_stream(llm_client, model, prompt)
        _track_usage(ctx, model, usage, "functional_monitor")
        result = json.loads(text)
        action = result.get("action", "NULL")

        if action in ("NULL", "NONE"):
            return FunctionalResult(
                success=True,
                action="NULL",
                data=None,
                intent="MONITOR_STATE",
            )

        return FunctionalResult(
            success=True,
            action=action,
            data=result.get("data", {}),
            intent="MONITOR_STATE",
        )
    except Exception as e:
        logger.error("Monitor analysis failed: %s", e)
        # Fail silently — don't interrupt workout
        return FunctionalResult(
            success=True,
            action="NULL",
            data=None,
            intent="MONITOR_STATE",
        )


# Intent -> handler mapping
_HANDLERS = {
    "SWAP_EXERCISE": _handle_swap_exercise,
    "AUTOFILL_SET": _handle_autofill_set,
    "SUGGEST_WEIGHT": _handle_suggest_weight,
    "MONITOR_STATE": _handle_monitor_state,
}


async def execute_functional_lane(
    intent: str,
    payload: dict[str, Any],
    ctx: RequestContext,
    llm_client: LLMClient,
    model: str = FUNCTIONAL_MODEL,
    tool_executor: ToolExecutor | None = None,
) -> FunctionalResult:
    """Execute a Functional Lane request.

    Main entry point. Routes intent to the appropriate handler.

    Args:
        intent: The functional intent (SWAP_EXERCISE, AUTOFILL_SET, etc.).
        payload: JSON payload with intent-specific data.
        ctx: Request context.
        llm_client: LLM client (protocol-based, model-agnostic).
        model: Model name to use (defaults to FUNCTIONAL_MODEL env var).
        tool_executor: Callback for tool invocations (same pattern as agent_loop.py).

    Returns:
        FunctionalResult with success, action, data, and intent.
    """
    handler = _HANDLERS.get(intent)
    if not handler:
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": f"Unknown intent: {intent}"},
            intent=intent,
        )

    # Default tool_executor that raises if called (for intents that don't need tools)
    if tool_executor is None:
        async def _noop_executor(name: str, args: dict, c: RequestContext) -> Any:
            raise RuntimeError(f"No tool_executor provided for tool call: {name}")
        tool_executor = _noop_executor

    try:
        return await handler(payload, ctx, llm_client, model, tool_executor)
    except Exception as e:
        logger.error("Functional handler error for %s: %s", intent, e)
        return FunctionalResult(
            success=False,
            action="ERROR",
            data={"message": str(e)},
            intent=intent,
        )


__all__ = [
    "FunctionalResult",
    "execute_functional_lane",
    "FUNCTIONAL_MODEL",
    "FUNCTIONAL_TEMPERATURE",
    "FUNCTIONAL_INSTRUCTION",
]
