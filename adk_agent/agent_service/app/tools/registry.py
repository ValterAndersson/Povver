# app/tools/registry.py
"""Tool registry — maps tool names to implementations."""

from __future__ import annotations

from typing import Any

from app.context import RequestContext
from app.llm.protocol import ToolDef

# Tool implementations are registered here after skill migration
_TOOL_REGISTRY: dict[str, Any] = {}


def register_tool(name: str, fn, description: str, parameters: dict):
    """Register a tool function."""
    _TOOL_REGISTRY[name] = {
        "fn": fn,
        "def": ToolDef(name=name, description=description, parameters=parameters),
    }


async def execute_tool(tool_name: str, args: dict, ctx: RequestContext) -> Any:
    """Execute a registered tool."""
    if tool_name not in _TOOL_REGISTRY:
        return {"error": f"Unknown tool: {tool_name}"}
    fn = _TOOL_REGISTRY[tool_name]["fn"]
    return await fn(ctx=ctx, **args)


# Tools that are banned during active workout mode (heavy-compute, disruptive)
WORKOUT_BANNED_TOOLS = {
    "get_planning_context", "search_exercises", "query_training_sets",
    "get_training_analysis", "propose_routine", "update_routine",
    "propose_workout", "update_template", "apply_progression",
}


def get_tools(ctx: RequestContext) -> list[ToolDef]:
    """Get tool definitions available for this context."""
    if ctx.workout_mode:
        return [
            entry["def"] for entry in _TOOL_REGISTRY.values()
            if entry["def"].name not in WORKOUT_BANNED_TOOLS
        ]
    return [entry["def"] for entry in _TOOL_REGISTRY.values()]
