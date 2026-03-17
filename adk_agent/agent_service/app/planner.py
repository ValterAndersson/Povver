# app/planner.py
"""Tool Planner — internal planning step for Slow Lane requests.

Migrated from canvas_orchestrator/app/shell/planner.py.
Changes:
- ContextVar / RoutingResult replaced with explicit parameters.
- Function signature: plan_tools(message, ctx, available_tools) -> list[str].
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

from app.context import RequestContext

logger = logging.getLogger(__name__)


@dataclass
class ToolPlan:
    """Generated plan for tool execution."""
    intent: str
    data_needed: list[str]
    rationale: str
    suggested_tools: list[str]
    skip_planning: bool = False

    def to_system_prompt(self) -> str:
        """Convert plan to system prompt injection."""
        if self.skip_planning:
            return ""

        tools_str = ", ".join(self.suggested_tools) if self.suggested_tools else "determine based on context"
        data_str = "\n".join(f"  - {d}" for d in self.data_needed) if self.data_needed else "  - None required"

        return f"""
## INTERNAL PLAN (Auto-generated)
Intent detected: {self.intent}
Data needed:
{data_str}
Rationale: {self.rationale}
Suggested tools: {tools_str}

Execute the plan above, then synthesize a response.
"""


# ============================================================================
# INTENT DETECTION PATTERNS
# ============================================================================

# Maps keyword groups to (intent, relevant_tool_substrings) pairs.
# The tool substrings are matched against the available_tools list.
INTENT_PATTERNS: list[tuple[list[str], str, list[str]]] = [
    # Routine / workout creation
    (
        ["routine", "program", "split", "push pull", "ppl", "upper lower",
         "create routine", "build routine", "make routine"],
        "PLAN_ROUTINE",
        ["get_planning_context", "search_exercises", "propose_routine"],
    ),
    # Workout / template creation
    (
        ["workout", "session", "template", "create workout", "build workout"],
        "PLAN_ARTIFACT",
        ["get_planning_context", "search_exercises", "propose_workout"],
    ),
    # Progress / analytics
    (
        ["progress", "improving", "trending", "e1rm", "1rm", "bench",
         "squat", "deadlift", "volume", "how am i doing", "how's my"],
        "ANALYZE_PROGRESS",
        ["get_planning_context", "get_exercise_progress", "get_muscle_group_progress",
         "get_training_analysis", "query_training_sets"],
    ),
    # Edit existing plan
    (
        ["swap", "replace", "change", "edit", "modify", "update"],
        "EDIT_PLAN",
        ["get_planning_context", "get_template", "search_exercises", "propose_workout"],
    ),
    # Start workout
    (
        ["start workout", "next workout", "begin workout", "let's train"],
        "START_WORKOUT",
        ["get_next_workout", "propose_workout"],
    ),
]


# ============================================================================
# PLANNING TEMPLATES (kept from original)
# ============================================================================

PLANNING_TEMPLATES: dict[str, dict[str, Any]] = {
    "ANALYZE_PROGRESS": {
        "data_needed": [
            "Pre-computed analysis (insights, daily brief, weekly review) for overview and readiness",
            "Muscle group / muscle / exercise progress for targeted drilldown",
        ],
        "rationale": "Start with pre-computed analysis (Tier 1) for broad questions. Only drill down to Tier 2/3 if the user asks for a specific target or raw data.",
    },
    "PLAN_ARTIFACT": {
        "data_needed": [
            "User profile for goals and experience level",
            "Planning context for existing routine",
            "Exercise catalog search for suitable exercises",
        ],
        "rationale": "Artifact creation requires understanding user context before building. Search exercises broadly, then filter locally.",
    },
    "PLAN_ROUTINE": {
        "data_needed": [
            "User profile for frequency preference",
            "Planning context for existing templates",
            "Exercise catalog search for each muscle group/day type",
        ],
        "rationale": "Routine creation is a multi-step process. Build all days first, then propose once.",
    },
    "EDIT_PLAN": {
        "data_needed": [
            "Current routine/template to understand existing structure",
            "User's specific edit request",
        ],
        "rationale": "Edits should preserve working parts and apply minimal changes.",
    },
    "START_WORKOUT": {
        "data_needed": [
            "Next workout from rotation",
            "User's active routine",
        ],
        "rationale": "Start workout requires determining which template is next in rotation.",
    },
}


def _detect_intent(message: str) -> tuple[str | None, list[str]]:
    """Detect intent from message keywords.

    Returns (intent, relevant_tool_substrings) or (None, []).
    """
    lower = message.lower()
    for keywords, intent, tool_subs in INTENT_PATTERNS:
        if any(kw in lower for kw in keywords):
            return intent, tool_subs
    return None, []


def plan_tools(
    message: str,
    ctx: RequestContext,
    available_tools: list[str],
) -> list[str]:
    """Generate a prioritized list of tools the agent should use.

    Pure function — no I/O. Matches message intent against known patterns
    and intersects with the actually-available tool list.

    Args:
        message: The user's message text.
        ctx: Request context (available for future per-user overrides).
        available_tools: Tool names currently registered in the agent.

    Returns:
        Ordered list of tool names the agent should prioritize.
        Empty list means "no strong opinion — let the LLM decide".
    """
    intent, tool_substrings = _detect_intent(message)

    if intent is None:
        logger.info("PLANNER: No specific intent detected [user=%s]", ctx.user_id)
        return []

    # Match tool_substrings against available_tools (substring match)
    prioritized: list[str] = []
    for sub in tool_substrings:
        for tool in available_tools:
            if sub in tool and tool not in prioritized:
                prioritized.append(tool)

    logger.info(
        "PLANNER: Intent=%s, prioritized=%s [user=%s]",
        intent, prioritized, ctx.user_id,
    )
    return prioritized


def generate_plan(intent: str | None, message: str) -> ToolPlan:
    """Generate a full ToolPlan for prompt injection.

    Args:
        intent: Detected intent string (or None).
        message: User's message.

    Returns:
        ToolPlan with data requirements and suggested tools.
    """
    if intent is None:
        return ToolPlan(
            intent="general",
            data_needed=[],
            rationale="General query - let LLM determine approach",
            suggested_tools=[],
            skip_planning=True,
        )

    template = PLANNING_TEMPLATES.get(intent)
    if template is None:
        return ToolPlan(
            intent=intent,
            data_needed=[],
            rationale=f"Handle {intent} request",
            suggested_tools=[],
            skip_planning=True,
        )

    # Get suggested tools from the intent pattern
    _, tool_subs = _detect_intent(message)

    logger.info("PLANNER: Generated plan for %s", intent)
    return ToolPlan(
        intent=intent,
        data_needed=template["data_needed"],
        rationale=template["rationale"],
        suggested_tools=tool_subs,
    )


__all__ = [
    "ToolPlan",
    "plan_tools",
    "generate_plan",
]
