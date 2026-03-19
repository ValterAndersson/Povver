"""Fast Lane skills — active workout operations via HTTP.

These skills are called directly by the Fast Lane router, bypassing the LLM.
Target latency: <500ms end-to-end.

Skills:
- log_set: Log a completed set with explicit values
- log_set_shorthand: Complete current set via completeCurrentSet endpoint
- get_next_set: Get the next planned set from active workout state

All skills call Firebase Functions directly via HTTP using the MYON_API_KEY
(server-to-server / API key lane).
"""

from __future__ import annotations

import logging
import re
import uuid
from typing import Any

from app.context import RequestContext
from app.http_client import get_functions_client

logger = logging.getLogger(__name__)


async def log_set(
    *,
    ctx: RequestContext,
    exercise_instance_id: str,
    set_id: str,
    reps: int,
    weight_kg: float,
    rir: int = 0,
) -> dict:
    """Log a completed set to the active workout.

    Calls the logSet Firebase Function with explicit values.
    The idempotency_key prevents duplicate logging on retries.
    """
    http = get_functions_client()
    return await http.post(
        "/logSet",
        user_id=ctx.user_id,
        body={
            "workout_id": ctx.workout_id,
            "exercise_instance_id": exercise_instance_id,
            "set_id": set_id,
            "values": {"weight": weight_kg, "reps": reps, "rir": rir},
            "idempotency_key": str(uuid.uuid4()),
        },
    )


async def log_set_shorthand(
    *,
    ctx: RequestContext,
    reps: int,
    weight_kg: float,
) -> dict:
    """Complete the current set using shorthand values.

    Uses the completeCurrentSet endpoint which auto-advances to the next set.
    Intended for quick "8@100" style logging.
    """
    http = get_functions_client()
    return await http.post(
        "/completeCurrentSet",
        user_id=ctx.user_id,
        body={
            "workout_id": ctx.workout_id,
            "values": {"weight": weight_kg, "reps": reps},
        },
    )


async def get_next_set(*, ctx: RequestContext) -> dict:
    """Get the next planned set from the active workout.

    Fetches workout state and finds the first exercise/set with status 'planned'.
    Returns the full workout data — the caller (router or LLM) interprets it.
    """
    http = get_functions_client()
    return await http.get(
        "/getActiveWorkout",
        user_id=ctx.user_id,
        params={"workout_id": ctx.workout_id},
    )


def parse_shorthand(message: str) -> dict[str, Any] | None:
    """Parse shorthand set notation like '8@100' or '8 @ 100kg'.

    Returns:
        Dict with reps, weight, unit — or None if no match.
    """
    match = re.match(
        r"^(\d+)\s*@\s*(\d+(?:\.\d+)?)\s*(kg|lbs?)?$",
        message.strip(),
        re.IGNORECASE,
    )
    if match:
        return {
            "reps": int(match.group(1)),
            "weight": float(match.group(2)),
            "unit": match.group(3) or "kg",
        }
    return None


__all__ = [
    "log_set",
    "log_set_shorthand",
    "get_next_set",
    "parse_shorthand",
]
