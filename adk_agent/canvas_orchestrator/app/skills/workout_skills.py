"""
Workout Execution Skills — active workout read/write operations.

These skills call Firebase Functions for workout mutations.
Unlike copilot_skills (Fast Lane, regex-only), these are LLM-directed.

Architecture:
- get_workout_state_formatted() is called by stream_query() to build the Workout Brief
- log_set(), swap_exercise(), complete_workout() are called by tool wrappers
- All functions take explicit user_id/workout_id (from ContextVar, never from LLM)

Firestore active_workout document shape (exercises array):
  exercises[].instance_id   — stable UUID per exercise in this workout
  exercises[].exercise_id   — catalog exercise ID
  exercises[].name          — display name
  exercises[].sets[].id     — stable set UUID
  exercises[].sets[].status — "planned" | "done" | "skipped"
  exercises[].sets[].weight — kg (flat, not nested)
  exercises[].sets[].reps   — int
  exercises[].sets[].rir    — int
  totals.sets               — count of done working/dropset sets
  totals.reps               — sum of reps
  totals.volume             — sum of weight * reps
"""

from __future__ import annotations

import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime as dt
from typing import Any, Dict, Optional, Tuple

import requests

from app.utils.weight_formatting import format_weight

logger = logging.getLogger(__name__)

# =============================================================================
# WEIGHT UNIT CACHE — module-level dict keyed by (user_id, correlation_id)
#
# Same pattern as _search_counts in context.py. ContextVars don't work for
# this because ADK's _before_tool_callback creates a fresh context for each
# tool invocation. A module-level dict keyed by (user_id, correlation_id)
# provides proper per-request isolation while being visible across all tool
# calls in the same request.
# =============================================================================
_weight_units: dict = {}  # (user_id, corr_id) -> {"unit": str, "ts": float}
_weight_units_lock = threading.Lock()


def set_weight_unit(user_id: str, corr_id: str, unit: str) -> None:
    """
    Cache weight unit for the current request.

    Called by planner_skills.get_planning_context() after fetching user profile.

    Args:
        user_id: User ID
        corr_id: Correlation ID or conversation ID
        unit: Weight unit ("kg" or "lbs")
    """
    with _weight_units_lock:
        _weight_units[(user_id, corr_id)] = {"unit": unit, "ts": time.monotonic()}
        # Evict oldest entries if dict grows too large
        if len(_weight_units) > 200:
            oldest = sorted(_weight_units, key=lambda k: _weight_units[k]["ts"])
            for old_key in oldest[: len(_weight_units) - 200]:
                del _weight_units[old_key]


def get_weight_unit() -> str:
    """
    Get cached weight unit for the current request.

    Returns "kg" if planning context hasn't been fetched yet (cold start).

    Returns:
        Weight unit string ("kg" or "lbs")
    """
    from app.shell.context import get_current_context
    try:
        ctx = get_current_context()
        key = (ctx.user_id, ctx.correlation_id or ctx.conversation_id)
        with _weight_units_lock:
            return _weight_units.get(key, {}).get("unit", "kg")
    except Exception:
        return "kg"


MYON_FUNCTIONS_BASE_URL = os.getenv(
    "MYON_FUNCTIONS_BASE_URL", "https://us-central1-myon-53d85.cloudfunctions.net"
)
FIREBASE_API_KEY = os.getenv("FIREBASE_API_KEY")
if not FIREBASE_API_KEY:
    raise RuntimeError("FIREBASE_API_KEY env var is required")


_client = None


def _get_client():
    """Get or create the singleton CanvasFunctionsClient instance."""
    global _client
    if _client is None:
        from app.libs.tools_canvas.client import CanvasFunctionsClient

        _client = CanvasFunctionsClient(
            base_url=MYON_FUNCTIONS_BASE_URL,
            api_key=FIREBASE_API_KEY,
        )
    return _client


@dataclass
class WorkoutSkillResult:
    """Result from a workout skill execution."""

    success: bool
    message: str
    data: Optional[Dict[str, Any]] = None
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        result = {"success": self.success, "message": self.message}
        if self.data:
            result["data"] = self.data
        if self.error:
            result["error"] = self.error
        return result


def get_workout_state_formatted(user_id: str, workout_id: str) -> str:
    """
    Get formatted workout brief for injection into agent context.

    Fetches active workout and daily brief in parallel, finds current exercise,
    and formats as a compact brief for the LLM.

    Returns:
        Formatted workout brief string, or empty string on failure
    """
    try:
        client = _get_client()

        # Parallel fetch: workout data + daily brief
        with ThreadPoolExecutor(max_workers=3) as executor:
            workout_future = executor.submit(
                client.get_active_workout, user_id, workout_id=workout_id
            )
            analysis_future = executor.submit(
                client.get_analysis_summary, user_id,
                sections=["weekly_review", "recommendation_history"],
            )

            # Get workout data first to extract current exercise
            workout_resp = workout_future.result(timeout=10)

            # Extract workout data — handler returns { success, workout: {...} }
            if not workout_resp.get("success"):
                logger.warning("get_active_workout failed: %s", workout_resp.get("error"))
                return ""

            workout_data = workout_resp.get("workout")
            if not workout_data:
                logger.warning("No active workout")
                return ""

            # Find current exercise and submit exercise history fetch in parallel
            current_ex_id, current_instance_id = _find_current_exercise(workout_data)
            exercise_future = None
            if current_ex_id:
                exercise_future = executor.submit(
                    client.get_exercise_summary,
                    user_id=user_id,
                    exercise_id=current_ex_id,
                    window_weeks=12,
                )

            # Wait for remaining futures
            analysis_resp = analysis_future.result(timeout=10)

            # Extract weekly review for readiness derivation
            weekly_review = None
            if analysis_resp.get("success"):
                weekly_review = analysis_resp.get("data", {}).get("weekly_review")

            # Extract recommendation history for workout-relevant recs
            recommendation_history = None
            if analysis_resp.get("success"):
                recommendation_history = (
                    analysis_resp.get("data", {}).get("recommendation_history")
                )

            # Fetch exercise history result if submitted
            exercise_history = None
            if exercise_future:
                try:
                    ex_resp = exercise_future.result(timeout=10)
                    if ex_resp.get("success"):
                        exercise_history = ex_resp.get("data")
                except Exception as e:
                    logger.debug("Failed to fetch exercise history: %s", e)

        return _format_workout_brief(
            workout_data, exercise_history, weekly_review, recommendation_history,
        )

    except Exception as e:
        logger.error("get_workout_state_formatted error: %s", e)
        return ""


def _find_current_exercise(
    workout_data: Dict[str, Any],
) -> Tuple[Optional[str], Optional[str]]:
    """
    Find the current exercise (first exercise with a planned set).

    Returns:
        Tuple of (exercise_id, exercise_instance_id) or (None, None)
    """
    exercises = workout_data.get("exercises", [])
    for ex in exercises:
        sets = ex.get("sets", [])
        for s in sets:
            if s.get("status") == "planned":
                return ex.get("exercise_id"), ex.get("instance_id")
    return None, None


def _format_workout_brief(
    workout_data: Dict[str, Any],
    exercise_history: Optional[Dict[str, Any]],
    weekly_review: Optional[Dict[str, Any]],
    recommendation_history: Optional[list] = None,
) -> str:
    """
    Format workout brief as compact text for LLM context.

    Active workout Firestore schema:
    - exercises[].instance_id — stable exercise instance UUID
    - exercises[].sets[].id — stable set UUID
    - exercises[].sets[].status — "planned" | "done" | "skipped"
    - exercises[].sets[].weight — kg (flat on set, not nested)
    - exercises[].sets[].reps — int (flat on set after logSet)
    - totals.sets — done working/dropset count
    - totals.volume — total volume kg
    """
    # Get user's preferred weight unit
    weight_unit = get_weight_unit()

    lines = ["[WORKOUT BRIEF]"]

    # Header line
    workout_name = workout_data.get("name", "Workout")
    start_time = workout_data.get("start_time", "")
    if isinstance(start_time, str) and "T" in start_time:
        start_time = start_time.split("T")[1][:5]
    elif hasattr(start_time, "strftime"):
        start_time = start_time.strftime("%H:%M")
    else:
        start_time = "?"

    # totals.sets = completed done sets; count all sets for total
    totals = workout_data.get("totals", {})
    completed_sets = totals.get("sets", 0)
    total_sets = sum(len(ex.get("sets", [])) for ex in workout_data.get("exercises", []))

    # Derive readiness from weekly review muscle_balance data
    readiness = "moderate"
    fatigued_groups = []
    if weekly_review:
        muscle_balance = weekly_review.get("muscle_balance", [])
        overtrained_count = sum(
            1 for mb in muscle_balance if mb.get("status") == "overtrained"
        )
        if overtrained_count == 0:
            readiness = "fresh"
        elif overtrained_count <= 2:
            readiness = "moderate"
            fatigued_groups = [
                mb.get("muscle_group", "?")
                for mb in muscle_balance
                if mb.get("status") == "overtrained"
            ]
        else:
            readiness = "fatigued"
            fatigued_groups = [
                mb.get("muscle_group", "?")
                for mb in muscle_balance
                if mb.get("status") == "overtrained"
            ]

    lines.append(
        f"{workout_name} | Started {start_time}"
        f" | {completed_sets}/{total_sets} sets"
        f" | Readiness: {readiness}"
    )
    lines.append("")

    # Exercise list
    exercises = workout_data.get("exercises", [])
    current_ex_id, _ = _find_current_exercise(workout_data)

    for ex in exercises:
        ex_name = ex.get("name", "Unknown")
        ex_id = ex.get("exercise_id", "")
        # Active workout uses instance_id, not id
        instance_id = ex.get("instance_id", "")

        current_marker = " \u2190 CURRENT" if ex_id == current_ex_id else ""
        lines.append(f"> {ex_name} [{instance_id}]{current_marker}")

        sets = ex.get("sets", [])
        first_planned_shown = False

        for idx, s in enumerate(sets):
            status = s.get("status", "planned")
            set_id = s.get("id", "")
            set_num = idx + 1

            if status == "done":
                # logSet writes weight/reps/rir flat on the set object
                weight_kg = s.get("weight", 0)
                reps = s.get("reps", 0)
                rir = s.get("rir")
                rir_str = f" @ RIR {rir}" if rir is not None else ""
                weight_str = format_weight(weight_kg, weight_unit)
                lines.append(
                    f"  \u2713 Set {set_num} [{set_id}]:" f" {weight_str} \u00d7 {reps}{rir_str}"
                )
            elif status == "planned" and not first_planned_shown:
                # Show first planned set with arrow (next to log)
                weight_kg = s.get("weight")
                if weight_kg is not None:
                    weight_str = format_weight(weight_kg, weight_unit)
                else:
                    weight_str = "?"
                lines.append(
                    f"  \u2192 Set {set_num} [{set_id}]:" f" {weight_str} \u00d7 ? (planned)"
                )
                first_planned_shown = True
            elif status == "planned":
                lines.append(f"  \u00b7 Set {set_num} [{set_id}]: planned")
            # skipped sets: omit from brief to save tokens

        lines.append("")

    # Exercise history (for current exercise)
    if exercise_history:
        last_session = exercise_history.get("last_session", [])
        if last_session:
            history_sets = []
            for s in last_session[-3:]:
                weight_kg = s.get("weight_kg", 0)
                reps = s.get("reps", 0)
                weight_str = format_weight(weight_kg, weight_unit)
                history_sets.append(f"{weight_str}\u00d7{reps}")

            # e1RM trend
            weekly_points = exercise_history.get("weekly_points", [])
            if len(weekly_points) >= 3:
                e1rms = [w.get("e1rm_max") for w in weekly_points[-3:] if w.get("e1rm_max")]
                if len(e1rms) >= 2:
                    e1rm_str = "\u2192".join([str(int(e)) for e in e1rms])
                    if e1rms[-1] > e1rms[0]:
                        trend = "\u2191"
                    elif e1rms[-1] < e1rms[0]:
                        trend = "\u2193"
                    else:
                        trend = "\u2192"
                    lines.append(
                        f"History: {', '.join(history_sets)}" f" | e1RM: {e1rm_str} ({trend})"
                    )
                else:
                    lines.append(f"History: {', '.join(history_sets)}")
            else:
                lines.append(f"History: {', '.join(history_sets)}")
            lines.append("")

    # Readiness summary (derived from weekly review muscle balance)
    if weekly_review:
        if fatigued_groups:
            groups_str = ", ".join(fatigued_groups)
            lines.append(f"Readiness: {readiness} \u2014 {groups_str} building fatigue")
        else:
            lines.append(f"Readiness: {readiness}")

    # Recommendation context — filter to exercises in this workout
    if recommendation_history:
        workout_exercise_names = {
            (ex.get("name") or "").lower()
            for ex in workout_data.get("exercises", [])
        }
        relevant_recs = [
            rec for rec in recommendation_history
            if (rec.get("target", {}).get("exercise_name") or "").lower()
            in workout_exercise_names
        ][:3]  # Cap at 3 lines to stay within token budget

        if relevant_recs:
            lines.append("")
            lines.append("Recommendations:")
            for rec in relevant_recs:
                ex_name = rec.get("target", {}).get("exercise_name", "?")
                rec_type = (
                    rec.get("recommendation", {}).get("type")
                    or rec.get("type", "?")
                )
                state = rec.get("state", "?")
                # Format age
                created = rec.get("created_at", "")
                age_str = ""
                if created:
                    try:
                        created_dt = dt.fromisoformat(
                            created.replace("Z", "+00:00")
                        )
                        days_ago = (
                            dt.now(created_dt.tzinfo) - created_dt
                        ).days
                        age_str = (
                            f", {days_ago}d ago"
                            if days_ago > 0
                            else ", today"
                        )
                    except Exception:
                        pass
                summary = rec.get("recommendation", {}).get("summary", "")
                if not summary:
                    summary = rec.get("summary", "")
                # Truncate summary to keep token budget tight
                if len(summary) > 60:
                    summary = summary[:57] + "..."
                lines.append(
                    f"  {ex_name}: {rec_type} {state}"
                    f"{age_str}"
                    + (f" — {summary}" if summary else "")
                )

    return "\n".join(lines)


def log_set(
    user_id: str,
    workout_id: str,
    exercise_instance_id: str,
    set_id: str,
    reps: int,
    weight_kg: float,
    rir: Optional[int] = None,
) -> WorkoutSkillResult:
    """Log a completed set in the active workout."""
    try:
        client = _get_client()
        resp = client.log_set(
            user_id=user_id,
            workout_id=workout_id,
            exercise_instance_id=exercise_instance_id,
            set_id=set_id,
            reps=reps,
            weight_kg=weight_kg,
            rir=rir,
        )

        if resp.get("success"):
            totals = resp.get("totals", {})
            weight_unit = get_weight_unit()
            weight_str = format_weight(weight_kg, weight_unit)
            return WorkoutSkillResult(
                success=True,
                message=f"Logged: {reps} \u00d7 {weight_str}. Refer to the workout brief for the next planned set.",
                data={"totals": totals, "event_id": resp.get("event_id")},
            )
        else:
            return WorkoutSkillResult(
                success=False,
                message="Failed to log set",
                error=resp.get("error", "Unknown error"),
            )

    except requests.HTTPError as e:
        body = {}
        try:
            body = e.response.json()
        except Exception:
            pass
        error_code = body.get("error", {}).get("code", "UNKNOWN")
        error_msg = body.get("error", {}).get("message", str(e))
        if error_code == "ALREADY_DONE":
            error_msg = (
                "This set is already logged. Call tool_get_workout_state "
                "to refresh, then check which set to log next."
            )
        elif error_code == "TARGET_NOT_FOUND":
            error_msg = (
                "Set or exercise not found — the brief may be stale. "
                "Call tool_get_workout_state to refresh."
            )
        return WorkoutSkillResult(success=False, message=error_msg, error=error_code)
    except Exception as e:
        logger.error("log_set error: %s", e)
        return WorkoutSkillResult(
            success=False,
            message="Failed to log set",
            error=str(e),
        )


def swap_exercise(
    user_id: str,
    workout_id: str,
    exercise_instance_id: str,
    new_exercise_id: str,
) -> WorkoutSkillResult:
    """Swap an exercise in the active workout."""
    try:
        client = _get_client()
        resp = client.swap_exercise(
            user_id=user_id,
            workout_id=workout_id,
            exercise_instance_id=exercise_instance_id,
            new_exercise_id=new_exercise_id,
        )

        # swapExercise returns { event_id } on success
        if resp.get("event_id"):
            return WorkoutSkillResult(
                success=True,
                message="Exercise swapped. Call tool_get_workout_state to see updated exercises.",
                data=resp,
            )
        elif resp.get("duplicate"):
            return WorkoutSkillResult(
                success=True,
                message="Exercise already swapped (duplicate)",
            )
        else:
            return WorkoutSkillResult(
                success=False,
                message="Failed to swap exercise",
                error=resp.get("error", "Unknown error"),
            )

    except requests.HTTPError as e:
        body = {}
        try:
            body = e.response.json()
        except Exception:
            pass
        error_code = body.get("error", {}).get("code", "UNKNOWN")
        error_msg = body.get("error", {}).get("message", str(e))
        return WorkoutSkillResult(success=False, message=error_msg, error=error_code)
    except Exception as e:
        logger.error("swap_exercise error: %s", e)
        return WorkoutSkillResult(
            success=False,
            message="Failed to swap exercise",
            error=str(e),
        )


def add_exercise(
    user_id: str,
    workout_id: str,
    exercise_id: str,
    name: str,
    sets: list,
) -> WorkoutSkillResult:
    """Add an exercise to the active workout with planned sets."""
    try:
        import uuid

        client = _get_client()
        instance_id = f"ex-{uuid.uuid4().hex[:12]}"

        resp = client.add_exercise(
            user_id=user_id,
            workout_id=workout_id,
            instance_id=instance_id,
            exercise_id=exercise_id,
            name=name,
            sets=sets,
        )

        if resp.get("success") or resp.get("event_id"):
            return WorkoutSkillResult(
                success=True,
                message=f"Added {name} with {len(sets)} sets (instance_id: {instance_id}). Use this instance_id for subsequent set operations.",
                data={"instance_id": instance_id},
            )
        elif resp.get("duplicate"):
            return WorkoutSkillResult(
                success=True,
                message="Exercise already added (duplicate)",
            )
        else:
            return WorkoutSkillResult(
                success=False,
                message="Failed to add exercise",
                error=resp.get("error", "Unknown error"),
            )

    except requests.HTTPError as e:
        body = {}
        try:
            body = e.response.json()
        except Exception:
            pass
        error_code = body.get("error", {}).get("code", "UNKNOWN")
        error_msg = body.get("error", {}).get("message", str(e))
        return WorkoutSkillResult(success=False, message=error_msg, error=error_code)
    except Exception as e:
        logger.error("add_exercise error: %s", e)
        return WorkoutSkillResult(
            success=False,
            message="Failed to add exercise",
            error=str(e),
        )


def prescribe_set(
    user_id: str,
    workout_id: str,
    exercise_instance_id: str,
    set_id: str,
    weight_kg: Optional[float] = None,
    reps: Optional[int] = None,
    rir: Optional[int] = None,
) -> WorkoutSkillResult:
    """Modify planned values (weight, reps, rir) on a planned set."""
    try:
        ops = []
        if weight_kg is not None:
            ops.append({
                "op": "set_field",
                "target": {
                    "exercise_instance_id": exercise_instance_id,
                    "set_id": set_id,
                },
                "field": "weight",
                "value": weight_kg,
            })
        if reps is not None:
            ops.append({
                "op": "set_field",
                "target": {
                    "exercise_instance_id": exercise_instance_id,
                    "set_id": set_id,
                },
                "field": "reps",
                "value": reps,
            })
        if rir is not None:
            ops.append({
                "op": "set_field",
                "target": {
                    "exercise_instance_id": exercise_instance_id,
                    "set_id": set_id,
                },
                "field": "rir",
                "value": rir,
            })

        if not ops:
            return WorkoutSkillResult(
                success=False,
                message="No values to update",
                error="Provide at least one of weight_kg, reps, or rir",
            )

        client = _get_client()
        resp = client.patch_active_workout(
            user_id=user_id,
            workout_id=workout_id,
            ops=ops,
            cause="user_ai_action",
            ai_scope={"exercise_instance_id": exercise_instance_id},
        )

        if resp.get("success"):
            parts = []
            if weight_kg is not None:
                parts.append(format_weight(weight_kg, get_weight_unit()))
            if reps is not None:
                parts.append(f"{reps} reps")
            if rir is not None:
                parts.append(f"RIR {rir}")
            return WorkoutSkillResult(
                success=True,
                message=f"Updated: {', '.join(parts)}",
            )
        elif resp.get("duplicate"):
            return WorkoutSkillResult(
                success=True,
                message="Already updated (duplicate)",
            )
        else:
            return WorkoutSkillResult(
                success=False,
                message="Failed to update set",
                error=resp.get("error", "Unknown error"),
            )

    except requests.HTTPError as e:
        body = {}
        try:
            body = e.response.json()
        except Exception:
            pass
        error_code = body.get("error", {}).get("code", "UNKNOWN")
        error_msg = body.get("error", {}).get("message", str(e))
        return WorkoutSkillResult(success=False, message=error_msg, error=error_code)
    except Exception as e:
        logger.error("prescribe_set error: %s", e)
        return WorkoutSkillResult(
            success=False,
            message="Failed to update set",
            error=str(e),
        )


def complete_workout(
    user_id: str,
    workout_id: str,
) -> WorkoutSkillResult:
    """Complete the active workout and archive it."""
    try:
        client = _get_client()
        resp = client.complete_active_workout(
            user_id=user_id,
            workout_id=workout_id,
        )

        # completeActiveWorkout returns { workout_id, archived: true }
        if resp.get("archived"):
            return WorkoutSkillResult(
                success=True,
                message="Workout complete",
                data={
                    "archived_workout_id": resp.get("workout_id"),
                    "archived": True,
                },
            )
        else:
            return WorkoutSkillResult(
                success=False,
                message="Failed to complete workout",
                error=resp.get("error", "Unknown error"),
            )

    except requests.HTTPError as e:
        body = {}
        try:
            body = e.response.json()
        except Exception:
            pass
        error_code = body.get("error", {}).get("code", "UNKNOWN")
        error_msg = body.get("error", {}).get("message", str(e))
        return WorkoutSkillResult(success=False, message=error_msg, error=error_code)
    except Exception as e:
        logger.error("complete_workout error: %s", e)
        return WorkoutSkillResult(
            success=False,
            message="Failed to complete workout",
            error=str(e),
        )


__all__ = [
    "get_workout_state_formatted",
    "log_set",
    "add_exercise",
    "prescribe_set",
    "swap_exercise",
    "complete_workout",
    "WorkoutSkillResult",
    "set_weight_unit",
    "get_weight_unit",
]
