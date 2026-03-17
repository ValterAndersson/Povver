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
        from app.firestore_client import get_firestore_client
        from app.llm.gemini import GeminiClient
        from app.observability import log_request

        ctx = RequestContext(
            user_id=user_id,
            conversation_id=conversation_id,
            correlation_id=trace_id,
            workout_id=workout_id,
            workout_mode=bool(workout_id),
        )

        fs = get_firestore_client()

        log_request(user_id, conversation_id, "slow", "gemini-2.5-flash")

        # Load conversation history
        history = await fs.get_conversation_messages(
            user_id, conversation_id, limit=20
        )

        llm_client = GeminiClient()

        # TODO: Tool registry + instruction builder (Phase 3a skill migration)
        tools = []
        instruction = "You are a helpful fitness coaching assistant."

        async for event in run_agent_loop(
            llm_client=llm_client,
            model="gemini-2.5-flash",
            instruction=instruction,
            history=_format_history(history),
            message=message,
            tools=tools,
            tool_executor=_noop_executor,
            ctx=ctx,
            fs=fs,
        ):
            yield event.encode()

        # Persist user message
        from datetime import datetime, timezone
        await fs.save_message(user_id, conversation_id, {
            "type": "user_prompt",
            "content": message,
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


async def _noop_executor(tool_name: str, args: dict, ctx) -> dict:
    """Placeholder tool executor — replaced by real registry in Phase 3a skill migration."""
    return {"error": f"Tool '{tool_name}' not yet implemented"}


def _format_history(messages: list[dict]) -> list[dict]:
    """Convert Firestore message docs to LLM message format.

    Firestore uses `type` field (user_prompt, agent_response, artifact).
    LLM expects `role` field (user, assistant).
    """
    TYPE_TO_ROLE = {"user_prompt": "user", "agent_response": "assistant"}
    formatted = []
    for msg in messages:
        role = TYPE_TO_ROLE.get(msg.get("type", "user_prompt"))
        if role:
            formatted.append({"role": role, "content": msg.get("content", "")})
    return formatted


async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


app = Starlette(
    routes=[
        Route("/stream", stream_handler, methods=["POST"]),
        Route("/health", health, methods=["GET"]),
    ],
)
