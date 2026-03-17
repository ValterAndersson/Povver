"""Workout execution skills — LLM-directed active workout operations.

Unlike copilot_skills (Fast Lane, regex-only), these are invoked by the LLM
via tool calls. All mutations go through Firebase Functions — active workout
writes are too critical to reimplement in Python.

Skills:
- get_workout_state: Fetch full active workout state
- swap_exercise: Replace an exercise in the active workout
- add_exercise: Add an exercise with planned sets
- prescribe_set: Modify planned values on a set (weight, reps, rir)
- complete_workout: Complete and archive the active workout

All functions use FIREBASE_API_KEY for authentication (bearer lane).
"""

from __future__ import annotations

import logging
import os
from typing import Any

import httpx

from app.context import RequestContext

logger = logging.getLogger(__name__)

FUNCTIONS_URL = os.getenv(
    "MYON_FUNCTIONS_BASE_URL",
    "https://us-central1-myon-53d85.cloudfunctions.net",
)
API_KEY = os.getenv("FIREBASE_API_KEY", "")


def _headers(ctx: RequestContext) -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "x-api-key": API_KEY,
        "x-user-id": ctx.user_id,
    }


async def get_workout_state(*, ctx: RequestContext) -> dict:
    """Fetch the full active workout state.

    Returns the workout document including exercises, sets, and totals.
    The LLM uses this to understand current progress and plan next actions.
    """
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            f"{FUNCTIONS_URL}/getActiveWorkout",
            params={"workout_id": ctx.workout_id},
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


async def swap_exercise(
    *,
    ctx: RequestContext,
    exercise_instance_id: str,
    new_exercise_id: str,
    new_exercise_name: str,
) -> dict:
    """Swap an exercise in the active workout.

    Replaces the exercise at exercise_instance_id with a new one.
    Preserves set structure (planned sets carry over).
    """
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/swapExercise",
            json={
                "workout_id": ctx.workout_id,
                "exercise_instance_id": exercise_instance_id,
                "new_exercise_id": new_exercise_id,
                "new_exercise_name": new_exercise_name,
            },
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


async def add_exercise(
    *,
    ctx: RequestContext,
    exercise_id: str,
    name: str,
    sets: int = 3,
    reps: int = 10,
    weight_kg: float = 0,
    rir: int = 2,
    warmup_sets: int = 0,
) -> dict:
    """Add an exercise to the active workout with planned sets.

    Creates a new exercise entry with the specified number of working sets
    and optional warmup sets.
    """
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/addExercise",
            json={
                "workout_id": ctx.workout_id,
                "exercise_id": exercise_id,
                "name": name,
                "sets": sets,
                "reps": reps,
                "weight_kg": weight_kg,
                "rir": rir,
                "warmup_sets": warmup_sets,
            },
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


async def prescribe_set(
    *,
    ctx: RequestContext,
    exercise_instance_id: str,
    set_id: str,
    weight_kg: float | None = None,
    reps: int | None = None,
) -> dict:
    """Modify planned values on a specific set.

    Updates weight and/or reps on a planned (not yet logged) set.
    Uses patchActiveWorkout which accepts granular field updates.
    """
    payload: dict[str, Any] = {
        "workout_id": ctx.workout_id,
        "exercise_instance_id": exercise_instance_id,
        "set_id": set_id,
    }
    if weight_kg is not None:
        payload["weight_kg"] = weight_kg
    if reps is not None:
        payload["reps"] = reps

    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/patchActiveWorkout",
            json=payload,
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


async def complete_workout(*, ctx: RequestContext) -> dict:
    """Complete the active workout and archive it.

    Finalizes totals, archives the workout document, and clears active state.
    """
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/completeActiveWorkout",
            json={"workout_id": ctx.workout_id},
            headers=_headers(ctx),
        )
        resp.raise_for_status()
        return resp.json()


__all__ = [
    "get_workout_state",
    "swap_exercise",
    "add_exercise",
    "prescribe_set",
    "complete_workout",
]
