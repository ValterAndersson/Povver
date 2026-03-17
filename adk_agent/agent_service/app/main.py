# app/main.py
"""Agent Service — Starlette ASGI application."""

from __future__ import annotations

import json
import logging

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import StreamingResponse, JSONResponse
from starlette.routing import Route

from app.observability import setup_logging, new_trace_id

setup_logging()
logger = logging.getLogger(__name__)

# Register all tools at import time
from app.tools.definitions import register_all_skills
register_all_skills()


async def stream_handler(request: Request) -> StreamingResponse:
    """POST /stream — main agent streaming endpoint.

    Request body: {
        "user_id": str,
        "conversation_id": str,
        "message": str,
        "correlation_id": str,
        "workout_id": str | null
    }
    Response: SSE stream
    """
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    user_id = body.get("user_id")
    conversation_id = body.get("conversation_id")
    message = body.get("message")
    correlation_id = body.get("correlation_id", "")
    workout_id = body.get("workout_id")

    if not all([user_id, conversation_id, message]):
        return JSONResponse(
            {"error": "user_id, conversation_id, and message are required"},
            status_code=400,
        )

    trace_id = correlation_id or new_trace_id()

    async def event_stream():
        from app.agent_loop import run_agent_loop, sse_event
        from app.context import RequestContext
        from app.context_builder import build_system_context
        from app.firestore_client import get_firestore_client
        from app.functional_handler import execute_functional_lane
        from app.llm.gemini import GeminiClient
        from app.observability import log_request
        from app.planner import plan_tools
        from app.router import route_request, Lane
        from app.tools.registry import execute_tool, get_tools

        ctx = RequestContext(
            user_id=user_id,
            conversation_id=conversation_id,
            correlation_id=trace_id,
            workout_id=workout_id,
            workout_mode=bool(workout_id),
        )

        fs = get_firestore_client()
        llm_client = GeminiClient()
        model = "gemini-2.5-flash"

        # Route the request
        lane = route_request(message if isinstance(message, str) else body)
        log_request(user_id, conversation_id, lane.value, model)

        # --- Fast Lane ---
        if lane == Lane.FAST and ctx.workout_mode:
            from app.skills.copilot_skills import parse_shorthand
            parsed = parse_shorthand(message) if isinstance(message, str) else None
            if parsed:
                try:
                    from app.skills.copilot_skills import log_set_shorthand
                    result = await log_set_shorthand(
                        ctx=ctx,
                        reps=parsed["reps"],
                        weight_kg=parsed["weight"],
                    )
                    yield sse_event("message", {"text": f"Logged: {parsed['reps']} × {parsed['weight']}kg"}).encode()
                    yield sse_event("done", {}).encode()
                    return
                except Exception as e:
                    logger.warning("Fast lane failed, falling back to slow: %s", e)
                    # Fall through to slow lane

        # --- Functional Lane ---
        if lane == Lane.FUNCTIONAL:
            intent = body.get("intent") if isinstance(body, dict) else None
            payload = body if isinstance(body, dict) else {}
            if intent:
                try:
                    result = await execute_functional_lane(
                        intent=intent,
                        payload=payload,
                        ctx=ctx,
                        llm_client=llm_client,
                        model=model,
                        tool_executor=lambda name, args, c: execute_tool(name, args, c),
                    )
                    yield sse_event("message", {"text": json.dumps(result.to_dict())}).encode()
                    yield sse_event("done", {}).encode()
                    return
                except Exception as e:
                    logger.error("Functional lane error: %s", e)
                    yield sse_event("error", {"message": str(e)}).encode()
                    return

        # --- Slow Lane (default) ---
        # Build full 360° context (instruction + history) in one call
        instruction, history = await build_system_context(
            ctx, llm_client=llm_client, model=model
        )

        # Get available tools for this context (respects workout mode banning)
        tools = get_tools(ctx)

        # Run planner to prioritize tools
        tool_names = [t.name for t in tools]
        prioritized = plan_tools(message, ctx, tool_names)
        if prioritized:
            logger.info("Planner prioritized: %s", prioritized)

        accumulated_text = []
        async for event in run_agent_loop(
            llm_client=llm_client,
            model=model,
            instruction=instruction,
            history=history,
            message=message,
            tools=tools,
            tool_executor=lambda name, args, c: execute_tool(name, args, c),
            ctx=ctx,
            fs=fs,
        ):
            # Collect agent text for persistence
            if event.event == "message" and event.data.get("text"):
                accumulated_text.append(event.data["text"])
            yield event.encode()

        # Persist user message + agent response
        from datetime import datetime, timezone
        await fs.save_message(user_id, conversation_id, {
            "type": "user_prompt",
            "content": message,
            "created_at": datetime.now(timezone.utc),
        })
        if accumulated_text:
            await fs.save_message(user_id, conversation_id, {
                "type": "agent_response",
                "content": "".join(accumulated_text),
                "created_at": datetime.now(timezone.utc),
            })

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Trace-Id": trace_id,
        },
    )


async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


app = Starlette(
    routes=[
        Route("/stream", stream_handler, methods=["POST"]),
        Route("/health", health, methods=["GET"]),
    ],
)
