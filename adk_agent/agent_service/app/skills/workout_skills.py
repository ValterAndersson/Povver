"""Workout execution skills — LLM-directed active workout operations.

Unlike copilot_skills (Fast Lane, regex-only), these are invoked by the LLM
via tool calls. All mutations go through Firebase Functions — active workout
writes are too critical to reimplement in Python.

Skills:
- get_workout_state: Fetch full active workout state
- swap_exercise: Replace an exercise in the active workout
- add_exercise: Add an exercise with planned sets
- remove_exercise: Remove an exercise from the workout
- prescribe_set: Modify planned values on a set (weight, reps, rir)
- add_set: Add a set to an existing exercise
- remove_set: Remove a set from an exercise
- complete_workout: Complete and archive the active workout

All functions use MYON_API_KEY for authentication (API key lane).
"""

from __future__ import annotations

import logging
import uuid
from typing import Any

from app.context import RequestContext
from app.http_client import get_functions_client

logger = logging.getLogger(__name__)


async def get_workout_state(*, ctx: RequestContext) -> dict:
    """Fetch the full active workout state.

    Returns the workout document including exercises, sets, and totals.
    The LLM uses this to understand current progress and plan next actions.
    """
    http = get_functions_client()
    return await http.get(
        "/getActiveWorkout",
        user_id=ctx.user_id,
        params={"workout_id": ctx.workout_id},
    )


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
    http = get_functions_client()
    return await http.post(
        "/swapExercise",
        user_id=ctx.user_id,
        body={
            "workout_id": ctx.workout_id,
            "exercise_instance_id": exercise_instance_id,
            "new_exercise_id": new_exercise_id,
            "new_exercise_name": new_exercise_name,
        },
    )


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
    and optional warmup sets. Generates instance_id and structured sets
    array required by the addExercise Firebase Function.
    """
    instance_id = str(uuid.uuid4())

    # Build structured sets array matching the Firebase Function contract
    structured_sets = []
    for i in range(warmup_sets):
        structured_sets.append({
            "id": str(uuid.uuid4()),
            "set_type": "warmup",
            "status": "planned",
            "target_reps": reps,
            "target_weight": round(weight_kg * 0.5, 1) if weight_kg else 0,
            "target_rir": None,
        })
    for i in range(sets):
        structured_sets.append({
            "id": str(uuid.uuid4()),
            "set_type": "working",
            "status": "planned",
            "target_reps": reps,
            "target_weight": weight_kg,
            "target_rir": rir,
        })

    http = get_functions_client()
    return await http.post(
        "/addExercise",
        user_id=ctx.user_id,
        body={
            "workout_id": ctx.workout_id,
            "instance_id": instance_id,
            "exercise_id": exercise_id,
            "name": name,
            "sets": structured_sets,
        },
    )


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
    ops: list[dict[str, Any]] = []
    if weight_kg is not None:
        ops.append({
            "op": "set_field",
            "target": {"exercise_instance_id": exercise_instance_id, "set_id": set_id},
            "field": "weight",
            "value": weight_kg,
        })
    if reps is not None:
        ops.append({
            "op": "set_field",
            "target": {"exercise_instance_id": exercise_instance_id, "set_id": set_id},
            "field": "reps",
            "value": reps,
        })

    if not ops:
        return {"status": "no_changes"}

    payload: dict[str, Any] = {
        "workout_id": ctx.workout_id,
        "ops": ops,
        "cause": "user_ai_action",
        "ui_source": "agent",
        "idempotency_key": str(uuid.uuid4()),
        "ai_scope": {"exercise_instance_id": exercise_instance_id},
    }

    http = get_functions_client()
    return await http.post("/patchActiveWorkout", user_id=ctx.user_id, body=payload)


async def remove_exercise(
    *,
    ctx: RequestContext,
    exercise_instance_id: str,
) -> dict:
    """Remove an exercise entirely from the active workout.

    Deletes the exercise and all its sets. Remaining exercises
    have their positions updated automatically.
    """
    payload: dict[str, Any] = {
        "workout_id": ctx.workout_id,
        "ops": [{
            "op": "remove_exercise",
            "target": {"exercise_instance_id": exercise_instance_id},
        }],
        "cause": "user_ai_action",
        "ui_source": "agent",
        "idempotency_key": str(uuid.uuid4()),
        "ai_scope": {"exercise_instance_id": exercise_instance_id},
    }

    http = get_functions_client()
    return await http.post("/patchActiveWorkout", user_id=ctx.user_id, body=payload)


async def add_set(
    *,
    ctx: RequestContext,
    exercise_instance_id: str,
    set_type: str = "working",
    reps: int = 10,
    rir: int = 2,
    weight_kg: float | None = None,
) -> dict:
    """Add a new set to an existing exercise in the active workout.

    Creates a planned set with the given parameters. set_type can be
    'warmup', 'working', or 'dropset'.
    """
    set_id = str(uuid.uuid4())

    payload: dict[str, Any] = {
        "workout_id": ctx.workout_id,
        "ops": [{
            "op": "add_set",
            "target": {"exercise_instance_id": exercise_instance_id},
            "value": {
                "id": set_id,
                "set_type": set_type,
                "reps": reps,
                "rir": rir,
                "weight": weight_kg,
                "status": "planned",
            },
        }],
        "cause": "user_ai_action",
        "ui_source": "agent",
        "idempotency_key": str(uuid.uuid4()),
        "ai_scope": {"exercise_instance_id": exercise_instance_id},
    }

    http = get_functions_client()
    return await http.post("/patchActiveWorkout", user_id=ctx.user_id, body=payload)


async def remove_set(
    *,
    ctx: RequestContext,
    exercise_instance_id: str,
    set_id: str,
) -> dict:
    """Remove a specific set from an exercise in the active workout.

    Only planned sets can be removed by the agent. Done/skipped sets
    are protected.
    """
    payload: dict[str, Any] = {
        "workout_id": ctx.workout_id,
        "ops": [{
            "op": "remove_set",
            "target": {"exercise_instance_id": exercise_instance_id, "set_id": set_id},
        }],
        "cause": "user_ai_action",
        "ui_source": "agent",
        "idempotency_key": str(uuid.uuid4()),
        "ai_scope": {"exercise_instance_id": exercise_instance_id},
    }

    http = get_functions_client()
    return await http.post("/patchActiveWorkout", user_id=ctx.user_id, body=payload)


async def complete_workout(*, ctx: RequestContext) -> dict:
    """Complete the active workout and archive it.

    Finalizes totals, archives the workout document, and clears active state.
    """
    http = get_functions_client()
    return await http.post(
        "/completeActiveWorkout",
        user_id=ctx.user_id,
        body={"workout_id": ctx.workout_id},
    )


__all__ = [
    "get_workout_state",
    "swap_exercise",
    "add_exercise",
    "remove_exercise",
    "prescribe_set",
    "add_set",
    "remove_set",
    "complete_workout",
]
