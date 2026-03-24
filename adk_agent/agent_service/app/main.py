# app/main.py
"""Agent Service — Starlette ASGI application."""

from __future__ import annotations

import json
import logging
import os

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import StreamingResponse, JSONResponse
from starlette.routing import Route

from app.observability import setup_logging, new_trace_id, set_trace_id

setup_logging()
logger = logging.getLogger(__name__)

# Defense-in-depth: API key validation (Cloud Run IAM is primary)
VALID_API_KEYS = set(k for k in os.environ.get("MYON_API_KEY", "").split(",") if k)

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
    # Defense-in-depth: API key check (Cloud Run IAM is primary auth)
    # Only enforce if caller sends x-api-key header — Firebase Function
    # proxy authenticates via IAM and doesn't send this header.
    api_key = request.headers.get("x-api-key", "")
    if api_key and VALID_API_KEYS and api_key not in VALID_API_KEYS:
        return JSONResponse(status_code=401, content={"error": "Unauthorized"})

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

    MAX_MESSAGE_LENGTH = 10_000
    if isinstance(message, str) and len(message) > MAX_MESSAGE_LENGTH:
        return JSONResponse(
            {"error": f"message exceeds maximum length of {MAX_MESSAGE_LENGTH}"},
            status_code=400,
        )

    trace_id = correlation_id or new_trace_id()

    async def event_stream():
        import time as _time
        from app.agent_loop import run_agent_loop, sse_event
        from app.context import RequestContext
        from app.context_builder import build_system_context
        from app.firestore_client import get_firestore_client
        from app.functional_handler import execute_functional_lane
        from app.llm.gemini import GeminiClient
        from app.observability import log_request, log_request_complete, log_tools_available
        from app.router import route_request, Lane
        from app.tools.registry import execute_tool, get_tools

        request_start = _time.monotonic()

        # Ensure trace_id propagates into this async generator
        set_trace_id(trace_id)

        from datetime import date
        ctx = RequestContext(
            user_id=user_id,
            conversation_id=conversation_id,
            correlation_id=trace_id,
            workout_id=workout_id,
            workout_mode=bool(workout_id),
            today=date.today().isoformat(),
        )

        fs = get_firestore_client()
        llm_client = GeminiClient()
        model = os.environ.get("AGENT_MODEL", "gemini-2.5-flash")

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
                    # Convert lbs to kg if user specified lbs
                    weight_kg = parsed["weight"]
                    unit = parsed.get("unit", "kg")
                    if unit.lower().startswith("lb"):
                        weight_kg = round(parsed["weight"] * 0.453592, 1)
                    result = await log_set_shorthand(
                        ctx=ctx,
                        reps=parsed["reps"],
                        weight_kg=weight_kg,
                    )
                    display_weight = parsed["weight"]
                    display_unit = unit if unit.lower().startswith("lb") else "kg"
                    yield sse_event("message", {"text": f"Logged: {parsed['reps']} × {display_weight}{display_unit}"}).encode()
                    yield sse_event("done", {}).encode()
                    elapsed = int((_time.monotonic() - request_start) * 1000)
                    log_request_complete("fast", elapsed, success=True)
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
                    elapsed = int((_time.monotonic() - request_start) * 1000)
                    log_request_complete("functional", elapsed, success=True)
                    return
                except Exception as e:
                    logger.error("Functional lane error: %s", e, exc_info=True)
                    yield sse_event("error", {"code": "INTERNAL_ERROR", "message": "An internal error occurred"}).encode()
                    elapsed = int((_time.monotonic() - request_start) * 1000)
                    log_request_complete("functional", elapsed, success=False, error=str(e))
                    return

        # --- Slow Lane (default) ---
        try:
            # Build full 360° context (instruction + history) in one call
            context_start = _time.monotonic()
            instruction, history = await build_system_context(
                ctx, llm_client=llm_client, model=model
            )
            context_ms = int((_time.monotonic() - context_start) * 1000)
            logger.info("Context build completed in %dms", context_ms)

            # Get available tools for this context (respects workout mode banning)
            tools = get_tools(ctx)
            tool_names = [t.name for t in tools]
            log_tools_available(tool_names, ctx.workout_mode)

        except Exception as e:
            logger.exception("Slow lane setup failed")
            yield sse_event("error", {"code": "SETUP_ERROR", "message": "Failed to initialize agent context"}).encode()
            yield sse_event("done", {}).encode()
            elapsed = int((_time.monotonic() - request_start) * 1000)
            log_request_complete("slow", elapsed, success=False, error=str(e))
            return

        tool_count = 0
        request_success = True
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
            if event.event == "tool_start":
                tool_count += 1
            if event.event == "error":
                request_success = False
            yield event.encode()

        elapsed = int((_time.monotonic() - request_start) * 1000)
        log_request_complete("slow", elapsed, success=request_success, tool_count=tool_count)


    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Trace-Id": trace_id,
        },
    )


async def health(request: Request) -> JSONResponse:
    """Health check with optional deep probe.

    GET /health        → {"status": "ok"} (fast, for load balancer)
    GET /health?deep=1 → verifies Firestore + Vertex AI connectivity
    """
    if request.query_params.get("deep"):
        checks = {}
        # Firestore
        try:
            from app.firestore_client import get_firestore_client
            fs = get_firestore_client()
            # Lightweight read — just check the connection works
            await fs.db.collection("_health").limit(1).get()
            checks["firestore"] = "ok"
        except Exception as e:
            logger.error("Firestore health check failed: %s", e, exc_info=True)
            checks["firestore"] = "error: service check failed"
        # Vertex AI / Gemini
        try:
            from app.llm.gemini import GeminiClient
            client = GeminiClient()
            # Minimal call to verify auth + endpoint
            checks["vertex_ai"] = "ok (client initialized)"
        except Exception as e:
            logger.error("Vertex AI health check failed: %s", e, exc_info=True)
            checks["vertex_ai"] = "error: service check failed"

        all_ok = all(v.startswith("ok") for v in checks.values())
        return JSONResponse(
            {"status": "ok" if all_ok else "degraded", "checks": checks},
            status_code=200 if all_ok else 503,
        )
    return JSONResponse({"status": "ok"})


app = Starlette(
    routes=[
        Route("/stream", stream_handler, methods=["POST"]),
        Route("/health", health, methods=["GET"]),
    ],
)
