"""
Shell Agent - Single unified agent with Coach persona.

Model: gemini-2.5-flash

This is the main agent that handles all "Slow Lane" requests. It combines
the capabilities of the former CoachAgent and PlannerAgent into a single
unified agent with consistent voice and behavior.

CRITICAL: This file imports ONLY from app/shell/ and app/skills/.
NO imports from app/agents/ (legacy files with global state).

For "Fast Lane" requests (copilot commands), see router.py which bypasses
this agent entirely.
"""

from __future__ import annotations

import logging
import os
from contextvars import ContextVar
from typing import Any, Dict

from google.adk import Agent
from google.genai.types import GenerateContentConfig

from app.shell.context import SessionContext
from app.shell.instruction import SHELL_INSTRUCTION
from app.shell.router import Lane, RoutingResult, execute_fast_lane, route_message
from app.shell.tools import all_tools, set_tool_context

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Per-request usage accumulator. ContextVar is required because Vertex AI
# Agent Engine runs concurrent requests in the same process — a module-level
# dict would leak usage data across requests.
_usage_accumulator: ContextVar[Dict[str, int]] = ContextVar(
    "_usage_accumulator", default=None
)


# ============================================================================
# AGENT CALLBACKS
# These inject context before tool/model calls using the new tools.py system.
# NO legacy agent context syncing required.
# ============================================================================

def _before_tool_callback(tool, args, tool_context):
    """Inject context before tool execution."""
    try:
        ctx = tool_context.invocation_context
        if ctx and hasattr(ctx, "user_content"):
            msg = ""
            if ctx.user_content and ctx.user_content.parts:
                msg = str(ctx.user_content.parts[0].text)
            session_ctx = SessionContext.from_message(msg)
            
            # Set context for tools (new pure skills system)
            set_tool_context(session_ctx, msg)
            
    except Exception as e:
        logger.debug("before_tool_callback error: %s", e)
    return None


def _before_model_callback(callback_context, llm_request):
    """Parse context before LLM inference."""
    try:
        for content in llm_request.contents or []:
            if hasattr(content, "role") and content.role == "user":
                for part in content.parts or []:
                    if hasattr(part, "text") and part.text:
                        session_ctx = SessionContext.from_message(part.text)

                        # Set context for tools (new pure skills system)
                        set_tool_context(session_ctx, part.text)
                        break
    except Exception as e:
        logger.debug("before_model_callback error: %s", e)
    return None


def _after_model_callback(callback_context, llm_response):
    """Capture usage_metadata from each LLM response.

    ADK's Event objects do not carry usage_metadata from LlmResponse, so the
    streaming chunks in agent_engine_app.py never contain token counts.  This
    callback fires after every model call (including multi-turn tool-use turns)
    and accumulates totals in a ContextVar that agent_engine_app reads after
    the stream completes.
    """
    try:
        meta = getattr(llm_response, "usage_metadata", None)
        if not meta:
            return llm_response

        prompt = getattr(meta, "prompt_token_count", 0) or 0
        completion = getattr(meta, "candidates_token_count", 0) or 0
        total = getattr(meta, "total_token_count", 0) or 0
        thinking = getattr(meta, "thoughts_token_count", None)

        acc = _usage_accumulator.get()
        if acc is None:
            acc = {}
            _usage_accumulator.set(acc)

        acc["prompt_tokens"] = acc.get("prompt_tokens", 0) + prompt
        acc["completion_tokens"] = acc.get("completion_tokens", 0) + completion
        acc["total_tokens"] = acc.get("total_tokens", 0) + total
        if thinking:
            acc["thinking_tokens"] = acc.get("thinking_tokens", 0) + thinking

    except Exception as e:
        logger.debug("after_model_callback error: %s", e)
    return llm_response


# ============================================================================
# SHELL AGENT DEFINITION
# Uses tools from shell/tools.py (pure skills only, no legacy agents)
# ============================================================================

# NOTE: Do NOT set max_output_tokens here. Gemini 2.5 Flash counts thinking
# tokens toward that budget, so even 1024 causes mid-sentence truncation.
# Response length is controlled via instruction-level caps (hard cap 12 lines).
_SHELL_CONFIG = GenerateContentConfig(
    temperature=0.3,
)

ShellAgent = Agent(
    name="ShellAgent",
    model=os.getenv("CANVAS_SHELL_MODEL", "gemini-2.5-flash"),
    instruction=SHELL_INSTRUCTION,
    tools=all_tools,  # From shell/tools.py - pure skills with Safety Gate
    generate_content_config=_SHELL_CONFIG,
    before_tool_callback=_before_tool_callback,
    before_model_callback=_before_model_callback,
    after_model_callback=_after_model_callback,
)


# ============================================================================
# ENTRY POINT
# ============================================================================

def handle_message(message: str) -> Dict[str, Any]:
    """
    Main entry point for message handling.
    
    Checks fast lane first, then routes to Shell Agent for slow lane.
    
    Note: This is called by agent_engine_app.py's stream_query override.
    For slow lane, the actual invocation happens through ADK's standard flow.
    
    Args:
        message: Raw message with context prefix
        
    Returns:
        For fast lane: Dict with skill result
        For slow lane: Dict indicating routing to ShellAgent
    """
    ctx = SessionContext.from_message(message)
    routing = route_message(message)
    
    if routing.lane == Lane.FAST:
        # Execute directly, no LLM
        logger.info("handle_message: FAST LANE → %s", routing.intent)
        return execute_fast_lane(routing, message, ctx)
    
    # Slow lane: Let Shell Agent handle via ADK
    logger.info("handle_message: SLOW LANE → ShellAgent")
    return {
        "lane": "slow",
        "agent": "ShellAgent",
        "intent": routing.intent,
        "signals": routing.signals,
    }


def create_shell_agent() -> Agent:
    """
    Factory function to create a ShellAgent instance.
    
    Useful for testing or creating multiple instances.
    """
    return Agent(
        name="ShellAgent",
        model=os.getenv("CANVAS_SHELL_MODEL", "gemini-2.5-flash"),
        instruction=SHELL_INSTRUCTION,
        tools=all_tools,
        generate_content_config=GenerateContentConfig(temperature=0.3),
        before_tool_callback=_before_tool_callback,
        before_model_callback=_before_model_callback,
        after_model_callback=_after_model_callback,
    )


# Export for ADK and imports
root_agent = ShellAgent

__all__ = [
    "root_agent",
    "ShellAgent",
    "create_shell_agent",
    "handle_message",
    "_usage_accumulator",
]
