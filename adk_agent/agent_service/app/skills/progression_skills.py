"""Progression skills — apply weight/volume changes via Firebase Function.

Used by background agents (post-workout analysis, scheduled progression)
to make training adjustments. All changes are logged to agent_recommendations
for audit.

Modes:
- auto_apply=True (default): Changes applied immediately
- auto_apply=False: Changes queued for user review

Uses MYON_API_KEY (server-to-server key), not FIREBASE_API_KEY.
"""

from __future__ import annotations

import logging
from typing import Any

from app.context import RequestContext
from app.http_client import get_functions_client

logger = logging.getLogger(__name__)


async def apply_progression(
    *,
    ctx: RequestContext,
    target_type: str,
    target_id: str,
    changes: list[dict[str, Any]],
    summary: str,
    rationale: str,
    trigger: str = "user_request",
    auto_apply: bool = True,
) -> dict:
    """Apply progression changes to a template or routine.

    This is the primary tool for background agents to make training adjustments.
    All changes are logged to agent_recommendations for audit.

    Args:
        ctx: Request context with user_id
        target_type: 'template' or 'routine'
        target_id: ID of the template or routine to update
        changes: List of changes, each with path/from/to/rationale
        summary: Human-readable summary
        rationale: Full explanation for the change
        trigger: What triggered this (post_workout, user_request, plateau_detected)
        auto_apply: Apply immediately or queue for review
    """
    http = get_functions_client()
    return await http.post(
        "/applyProgression",
        user_id=ctx.user_id,
        body={
            "userId": ctx.user_id,
            "targetType": target_type,
            "targetId": target_id,
            "changes": changes,
            "summary": summary,
            "rationale": rationale,
            "trigger": trigger,
            "autoApply": auto_apply,
        },
    )


async def suggest_weight_increase(
    *,
    ctx: RequestContext,
    template_id: str,
    exercise_index: int,
    new_weight: float,
    rationale: str,
) -> dict:
    """Convenience wrapper — suggest a weight increase on a template exercise.

    Builds the changes array for all working sets (up to 4) and calls
    apply_progression.
    """
    changes = [
        {
            "path": f"exercises[{exercise_index}].sets[{set_idx}].weight",
            "from": None,
            "to": new_weight,
            "rationale": rationale,
        }
        for set_idx in range(4)
    ]
    return await apply_progression(
        ctx=ctx,
        target_type="template",
        target_id=template_id,
        changes=changes,
        summary=f"Increase weight to {new_weight}kg",
        rationale=rationale,
        trigger="user_request",
    )


async def suggest_deload(
    *,
    ctx: RequestContext,
    template_id: str,
    exercise_index: int,
    current_weight: float,
    rationale: str,
) -> dict:
    """Convenience wrapper — suggest a deload (60% of current weight).

    Calculates deload weight and calls apply_progression.
    """
    deload_weight = round(current_weight * 0.6, 1)
    changes = [
        {
            "path": f"exercises[{exercise_index}].sets[{set_idx}].weight",
            "from": current_weight,
            "to": deload_weight,
            "rationale": rationale,
        }
        for set_idx in range(4)
    ]
    return await apply_progression(
        ctx=ctx,
        target_type="template",
        target_id=template_id,
        changes=changes,
        summary=f"Deload to {deload_weight}kg",
        rationale=rationale,
        trigger="user_request",
    )


__all__ = [
    "apply_progression",
    "suggest_weight_increase",
    "suggest_deload",
]
