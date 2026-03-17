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
import os
import re
import uuid
from typing import Any

import httpx

from app.context import RequestContext

logger = logging.getLogger(__name__)

FUNCTIONS_URL = os.getenv(
    "MYON_FUNCTIONS_BASE_URL",
    "https://us-central1-myon-53d85.cloudfunctions.net",
)
API_KEY = os.getenv("MYON_API_KEY", "")

# Aggressive timeout for fast lane — these calls must be quick
FAST_LANE_TIMEOUT = 5.0


def _headers(ctx: RequestContext) -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "x-api-key": API_KEY,
        "x-user-id": ctx.user_id,
    }


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
    async with httpx.AsyncClient(timeout=FAST_LANE_TIMEOUT) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/logSet",
            json={
                "workout_id": ctx.workout_id,
                "exercise_instance_id": exercise_instance_id,
                "set_id": set_id,
                "values": {"weight": weight_kg, "reps": reps, "rir": rir},
                "idempotency_key": str(uuid.uuid4()),
            },
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


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
    async with httpx.AsyncClient(timeout=FAST_LANE_TIMEOUT) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/completeCurrentSet",
            json={
                "workout_id": ctx.workout_id,
                "values": {"weight": weight_kg, "reps": reps},
            },
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


async def get_next_set(*, ctx: RequestContext) -> dict:
    """Get the next planned set from the active workout.

    Fetches workout state and finds the first exercise/set with status 'planned'.
    Returns the full workout data — the caller (router or LLM) interprets it.
    """
    async with httpx.AsyncClient(timeout=FAST_LANE_TIMEOUT) as client:
        resp = await client.get(
            f"{FUNCTIONS_URL}/getActiveWorkout",
            params={"workout_id": ctx.workout_id},
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


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
