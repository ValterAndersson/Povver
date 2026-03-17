# app/skills/planner_skills.py
"""Planner skills — write tools that create workout/routine artifacts.

Migrated from canvas_orchestrator/app/skills/planner_skills.py with:
- ContextVar replaced by explicit RequestContext parameter
- SkillResult replaced by plain dicts
- CanvasFunctionsClient replaced by FirestoreClient for artifact persistence
- HTTP retained for update_routine / update_template (too critical to reimplement)

Artifacts are returned as dicts with an `artifact_type` key.
The agent_loop detects this and emits SSE artifact events to the client.
"""

from __future__ import annotations

import json
import logging
import os
import re
import uuid
from typing import Any

from app.context import RequestContext
from app.firestore_client import get_firestore_client

logger = logging.getLogger(__name__)


# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def _coerce_int(value: Any, default: int) -> int:
    """Safely coerce a value to int, returning default on failure."""
    try:
        return int(value)
    except Exception:
        return default


def _slugify(value: str) -> str:
    """Convert a string to a URL-safe slug (max 48 chars)."""
    slug = re.sub(r"[^a-z0-9]+", "-", value.strip().lower()).strip("-")
    return slug[:48] or "exercise"


def _extract_reps(value: Any, default: int = 8) -> int:
    """Extract a rep count from various input formats (int, float, '8-12')."""
    if isinstance(value, (int, float)):
        return max(int(value), 1)
    if isinstance(value, str):
        matches = re.findall(r"\d+", value)
        if matches:
            return int(matches[-1])
    return default


def _build_exercise_blocks(exercises: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Build structured exercise blocks from a raw exercise list.

    Handles warmup set generation for compound lifts and RIR progression
    across working sets. Tolerates multiple input key conventions
    (name/exercise_name, weight_kg/weight, etc.).
    """
    blocks: list[dict[str, Any]] = []

    for idx, ex in enumerate(exercises):
        if not isinstance(ex, dict):
            continue

        name = ex.get("name") or ex.get("exercise_name") or "Exercise"
        exercise_id = ex.get("exercise_id") or ex.get("id") or _slugify(name)

        reps = _extract_reps(ex.get("reps"), 8)
        final_rir = _coerce_int(ex.get("rir"), 2)
        weight = ex.get("weight_kg") or ex.get("weight")
        if weight is not None:
            try:
                weight = float(weight)
            except (TypeError, ValueError):
                weight = None

        if weight is None:
            logger.warning(json.dumps({
                "event": "missing_weight",
                "exercise": name,
                "exercise_id": exercise_id,
            }))

        category = ex.get("category", "").lower()
        is_compound = category == "compound" or idx < 2

        # Build sets array
        sets: list[dict[str, Any]] = []
        num_working = _coerce_int(ex.get("sets", 3), 3)
        num_warmup = ex.get("warmup_sets")

        if num_warmup is None:
            num_warmup = 2 if is_compound and weight and weight >= 40 else 0
        else:
            num_warmup = _coerce_int(num_warmup, 0)

        # Warmup sets with ramping weight
        if num_warmup > 0 and weight:
            warmup_weights = {
                1: [0.5],
                2: [0.4, 0.7],
                3: [0.3, 0.5, 0.7],
            }.get(num_warmup, [0.4, 0.7])

            for i, pct in enumerate(warmup_weights[:num_warmup]):
                sets.append({
                    "id": str(uuid.uuid4())[:8],
                    "type": "warmup",
                    "target": {
                        "reps": 10 if i == 0 else 6,
                        "rir": 5,
                        "weight": round(weight * pct / 2.5) * 2.5,
                    },
                })

        # Working sets with RIR progression (higher RIR early, final RIR last)
        for i in range(num_working):
            sets_remaining = num_working - i - 1
            set_rir = min(final_rir + sets_remaining, 5)

            target: dict[str, Any] = {"reps": reps, "rir": set_rir}
            if weight is not None:
                target["weight"] = weight

            sets.append({
                "id": str(uuid.uuid4())[:8],
                "type": "working",
                "target": target,
            })

        blocks.append({
            "id": str(uuid.uuid4())[:8],
            "exercise_id": exercise_id,
            "name": name,
            "sets": sets,
            "primary_muscles": ex.get("primary_muscles") or [],
            "equipment": (
                (ex.get("equipment") or [None])[0]
                if isinstance(ex.get("equipment"), list)
                else ex.get("equipment")
            ),
            "coach_note": ex.get("notes") or ex.get("rationale"),
        })

    return blocks


# ============================================================================
# PROPOSE WORKOUT
# ============================================================================

async def propose_workout(
    *,
    ctx: RequestContext,
    title: str,
    exercises: list[dict[str, Any]],
    focus: str | None = None,
    duration_minutes: int = 45,
    coach_notes: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Create a workout template artifact.

    Returns dict with artifact_type="session_plan" for SSE detection.
    If dry_run=True, returns preview without persisting.
    """
    blocks = _build_exercise_blocks(exercises)

    if not blocks:
        return {"error": "No valid exercises provided"}

    # Safety gate: preview without persisting
    if dry_run:
        logger.info("PROPOSE_WORKOUT DRY_RUN: title='%s' exercises=%d", title, len(blocks))
        return {
            "dry_run": True,
            "status": "preview",
            "message": f"Ready to publish '{title}' ({len(blocks)} exercises, ~{duration_minutes} min)",
            "preview": {
                "title": title,
                "exercise_count": len(blocks),
                "exercises": [{"name": b["name"], "sets": len(b["sets"])} for b in blocks],
                "total_sets": sum(len(b.get("sets", [])) for b in blocks),
                "duration_minutes": duration_minutes,
            },
            "action_required": "Call propose_workout with dry_run=False to publish",
        }

    logger.info("PROPOSE_WORKOUT: title='%s' exercises=%d", title, len(blocks))

    artifact = {
        "artifact_type": "session_plan",
        "content": {
            "title": title,
            "blocks": blocks,
            "estimated_duration_minutes": duration_minutes,
            "coach_notes": coach_notes,
        },
        "actions": ["start_workout", "dismiss"],
        "status": "proposed",
        "message": f"'{title}' proposed ({len(blocks)} exercises, ~{duration_minutes} min)",
        "exercises": len(blocks),
        "total_sets": sum(len(b.get("sets", [])) for b in blocks),
    }

    # Persist artifact to Firestore
    fs = get_firestore_client()
    await fs.save_artifact(
        ctx.user_id, ctx.conversation_id, str(uuid.uuid4()), artifact
    )

    return artifact


# ============================================================================
# PROPOSE ROUTINE
# ============================================================================

async def propose_routine(
    *,
    ctx: RequestContext,
    name: str,
    frequency: int,
    workouts: list[dict[str, Any]],
    description: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Create a multi-day routine artifact.

    Each workout in workouts has: title, exercises list.
    Returns dict with artifact_type="routine_summary" for SSE detection.
    """
    if not workouts:
        return {"error": "At least one workout is required"}

    workout_summaries: list[dict[str, Any]] = []
    empty_days: list[str] = []

    for idx, workout in enumerate(workouts):
        w_title = workout.get("title") or f"Day {idx + 1}"
        exercises = workout.get("exercises") or []

        blocks = _build_exercise_blocks(exercises)

        if not blocks:
            empty_days.append(w_title)
            continue

        estimated_duration = len(blocks) * 5 + 10

        summary: dict[str, Any] = {
            "day": idx + 1,
            "title": w_title,
            "blocks": blocks,
            "estimated_duration": estimated_duration,
            "exercise_count": len(blocks),
        }
        source_id = workout.get("source_template_id")
        if source_id:
            summary["source_template_id"] = source_id

        workout_summaries.append(summary)

    if not workout_summaries:
        detail = f" (empty: {', '.join(empty_days)})" if empty_days else ""
        return {
            "error": f"All workouts have empty exercises{detail}. "
                     "Provide exercises for each workout day."
        }

    if empty_days:
        logger.warning(
            "PROPOSE_ROUTINE: skipped %d empty workout(s): %s",
            len(empty_days), ", ".join(empty_days),
        )

    total_exercises = sum(w.get("exercise_count", 0) for w in workout_summaries)

    # Safety gate
    if dry_run:
        logger.info("PROPOSE_ROUTINE DRY_RUN: name='%s' workouts=%d", name, len(workouts))
        return {
            "dry_run": True,
            "status": "preview",
            "message": f"Ready to publish '{name}' ({len(workouts)} workouts, {frequency}x/week)",
            "preview": {
                "name": name,
                "frequency": frequency,
                "workout_count": len(workouts),
                "total_exercises": total_exercises,
                "workouts": workout_summaries,
            },
            "action_required": "Call propose_routine with dry_run=False to publish",
        }

    logger.info("PROPOSE_ROUTINE: name='%s' workouts=%d", name, len(workouts))

    artifact = {
        "artifact_type": "routine_summary",
        "content": {
            "name": name,
            "description": description,
            "frequency": frequency,
            "workouts": workout_summaries,
        },
        "actions": ["save_routine", "dismiss"],
        "status": "proposed",
        "message": f"'{name}' routine proposed ({len(workouts)} workouts)",
        "workout_count": len(workouts),
        "total_exercises": total_exercises,
    }

    fs = get_firestore_client()
    await fs.save_artifact(
        ctx.user_id, ctx.conversation_id, str(uuid.uuid4()), artifact
    )

    return artifact


# ============================================================================
# UPDATE ROUTINE (HTTP to Firebase Function — too critical to reimplement)
# ============================================================================

async def update_routine(
    *,
    ctx: RequestContext,
    routine_id: str,
    routine_name: str,
    workouts: list[dict[str, Any]],
) -> dict:
    """Update an existing routine via Firebase Function.

    Uses HTTP because the update-routine Function handles template
    creation/linking, Firestore transactions, and validation that would
    be error-prone to reimplement here.
    """
    import httpx

    url = os.getenv(
        "MYON_FUNCTIONS_BASE_URL",
        "https://us-central1-myon-53d85.cloudfunctions.net",
    )
    api_key = os.getenv("MYON_API_KEY", "")

    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            f"{url}/updateRoutine",
            json={
                "userId": ctx.user_id,
                "routineId": routine_id,
                "routineName": routine_name,
                "workouts": workouts,
            },
            headers={"x-api-key": api_key},
        )
        resp.raise_for_status()
        return resp.json()


# ============================================================================
# UPDATE TEMPLATE (HTTP to Firebase Function)
# ============================================================================

async def update_template(
    *,
    ctx: RequestContext,
    template_id: str,
    exercises: list[dict[str, Any]],
) -> dict:
    """Update exercises in an existing template via Firebase Function.

    Uses HTTP because patch-template handles validation and merge semantics.
    """
    import httpx

    url = os.getenv(
        "MYON_FUNCTIONS_BASE_URL",
        "https://us-central1-myon-53d85.cloudfunctions.net",
    )
    api_key = os.getenv("MYON_API_KEY", "")
    blocks = _build_exercise_blocks(exercises)

    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            f"{url}/patchTemplate",
            json={
                "userId": ctx.user_id,
                "templateId": template_id,
                "exercises": blocks,
            },
            headers={"x-api-key": api_key},
        )
        resp.raise_for_status()
        return resp.json()


__all__ = [
    "propose_workout",
    "propose_routine",
    "update_routine",
    "update_template",
    # Helpers exposed for testing
    "_coerce_int",
    "_slugify",
    "_extract_reps",
    "_build_exercise_blocks",
]
