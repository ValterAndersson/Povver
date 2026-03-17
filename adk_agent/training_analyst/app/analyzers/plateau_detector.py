"""Plateau detector — identifies exercises with stalled e1RM progression.

Reads users/{uid}/analytics_series_exercise for the last 4 weeks.
An exercise is "plateaued" if its best e1RM has not increased for
3+ consecutive weeks with at least 2 data points per week.

Output: users/{uid}/analysis_insights/{autoId} with section: "plateau_report"
"""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List

from app.analyzers.base import BaseAnalyzer
from app.config import TTL_INSIGHTS
from app.firestore_client import get_db

logger = logging.getLogger(__name__)

# Minimum weeks of flat/declining e1RM to flag as plateaued
PLATEAU_THRESHOLD_WEEKS = 3

# Minimum data points (sets with e1RM) per week to count as "trained"
MIN_DATA_POINTS_PER_WEEK = 2

# How many weeks of series data to read
LOOKBACK_WEEKS = 4


def _suggest_action(weeks_stalled: int, avg_rir: float | None) -> str:
    """Choose intervention based on stall duration and effort level.

    - Short stall with room to push (high RIR) -> increase volume
    - Medium stall -> change rep range to vary stimulus
    - Long stall or grinding (low RIR) -> add variation / swap exercise
    """
    if weeks_stalled <= 3 and avg_rir is not None and avg_rir >= 2.0:
        return "increase_volume"
    elif weeks_stalled <= 4:
        return "change_rep_range"
    else:
        return "add_variation"


async def detect_plateaus(db, user_id: str) -> list[dict]:
    """Detect exercises with stalled e1RM progression.

    Reads analytics_series_exercise for the last 4 weeks. Groups by
    exercise_name, checks if best_e1rm is flat or declining over 3+
    consecutive weeks with sufficient data density.

    Returns:
        List of plateaued exercises:
        [{ exercise_name, weeks_stalled, last_e1rm, suggested_action }]
    """
    ref = (
        db.collection("users").document(user_id)
        .collection("analytics_series_exercise")
    )

    # Read all exercise series docs (typically 15-30 per user)
    docs = ref.limit(30).stream()

    cutoff = datetime.now(timezone.utc) - timedelta(weeks=LOOKBACK_WEEKS)
    cutoff_str = cutoff.strftime("%Y-%m-%d")

    plateaued = []

    for doc in docs:
        data = doc.to_dict()
        exercise_name = data.get("exercise_name") or data.get("name") or doc.id
        weeks_map = BaseAnalyzer.extract_weeks_map(data)

        if not weeks_map:
            continue

        # Filter to recent weeks only, sorted chronologically
        recent_weeks = sorted(
            wk for wk in weeks_map.keys() if wk >= cutoff_str
        )

        if len(recent_weeks) < PLATEAU_THRESHOLD_WEEKS:
            continue

        # Check data density: each week needs MIN_DATA_POINTS_PER_WEEK
        dense_weeks = []
        for wk in recent_weeks:
            wk_data = weeks_map[wk]
            set_count = wk_data.get("sets") or wk_data.get("set_count", 0)
            if set_count >= MIN_DATA_POINTS_PER_WEEK:
                dense_weeks.append(wk)

        if len(dense_weeks) < PLATEAU_THRESHOLD_WEEKS:
            continue

        # Extract e1RM values for dense weeks (chronological order)
        e1rm_values = []
        rir_values = []
        for wk in dense_weeks:
            wk_data = weeks_map[wk]
            e1rm = wk_data.get("e1rm_max")
            if e1rm is not None and e1rm > 0:
                e1rm_values.append((wk, e1rm))
            # Collect RIR for intervention selection
            if wk_data.get("rir_count") and wk_data.get("rir_sum") is not None:
                rir_values.append(wk_data["rir_sum"] / wk_data["rir_count"])

        if len(e1rm_values) < PLATEAU_THRESHOLD_WEEKS:
            continue

        # Check for plateau: best e1RM has not increased for 3+ consecutive weeks
        # "Not increased" = each subsequent week's e1RM <= first week's e1RM (within 2% tolerance)
        baseline_e1rm = e1rm_values[0][1]
        tolerance = baseline_e1rm * 0.02  # 2% tolerance for measurement noise

        consecutive_flat = 1  # Start at 1 (the baseline week counts)
        max_consecutive_flat = 1

        for i in range(1, len(e1rm_values)):
            current_e1rm = e1rm_values[i][1]
            if current_e1rm <= baseline_e1rm + tolerance:
                consecutive_flat += 1
                max_consecutive_flat = max(max_consecutive_flat, consecutive_flat)
            else:
                # e1RM increased — reset baseline and counter
                baseline_e1rm = current_e1rm
                consecutive_flat = 1

        if max_consecutive_flat < PLATEAU_THRESHOLD_WEEKS:
            continue

        last_e1rm = e1rm_values[-1][1]
        avg_rir = round(sum(rir_values) / len(rir_values), 1) if rir_values else None

        plateaued.append({
            "exercise_name": exercise_name,
            "exercise_id": doc.id,
            "weeks_stalled": max_consecutive_flat,
            "last_e1rm": round(last_e1rm, 1),
            "suggested_action": _suggest_action(max_consecutive_flat, avg_rir),
        })

    return plateaued


class PlateauDetectorAnalyzer(BaseAnalyzer):
    """Runs plateau detection and writes results to analysis_insights."""

    def __init__(self):
        # No LLM call needed — purely algorithmic
        super().__init__(model_name="none")

    def analyze(self, user_id: str) -> Dict[str, Any]:
        """Detect plateaus and write insight document.

        Returns:
            Result dict with success status and insight_id
        """
        self.log_event("plateau_detection_started", user_id=user_id)

        db = get_db()

        # detect_plateaus is defined as async for interface consistency
        # but uses synchronous Firestore client — call it synchronously
        import asyncio
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # Already in an async context — run directly via sync wrapper
                plateaued = _detect_plateaus_sync(db, user_id)
            else:
                plateaued = loop.run_until_complete(
                    detect_plateaus(db, user_id)
                )
        except RuntimeError:
            plateaued = _detect_plateaus_sync(db, user_id)

        insight_id = self._write_insight(db, user_id, plateaued)

        self.log_event(
            "plateau_detection_completed",
            user_id=user_id,
            insight_id=insight_id,
            plateaus_found=len(plateaued),
        )

        return {
            "success": True,
            "insight_id": insight_id,
            "plateaus": plateaued,
        }

    def _write_insight(
        self, db, user_id: str, plateaued: List[Dict[str, Any]]
    ) -> str:
        """Write plateau report to analysis_insights."""
        now = datetime.now(timezone.utc)
        expires_at = now + timedelta(days=TTL_INSIGHTS)

        doc_data = {
            "type": "plateau_report",
            "section": "plateau_report",
            "created_at": now,
            "expires_at": expires_at,
            "plateaued_exercises": plateaued,
            "total_plateaus": len(plateaued),
        }

        ref = (
            db.collection("users").document(user_id)
            .collection("analysis_insights")
        )
        _, doc_ref = ref.add(doc_data)

        return doc_ref.id


def _detect_plateaus_sync(db, user_id: str) -> list[dict]:
    """Synchronous version of detect_plateaus for use with sync Firestore client."""
    ref = (
        db.collection("users").document(user_id)
        .collection("analytics_series_exercise")
    )

    docs = ref.limit(30).stream()

    cutoff = datetime.now(timezone.utc) - timedelta(weeks=LOOKBACK_WEEKS)
    cutoff_str = cutoff.strftime("%Y-%m-%d")

    plateaued = []

    for doc in docs:
        data = doc.to_dict()
        exercise_name = data.get("exercise_name") or data.get("name") or doc.id
        weeks_map = BaseAnalyzer.extract_weeks_map(data)

        if not weeks_map:
            continue

        recent_weeks = sorted(
            wk for wk in weeks_map.keys() if wk >= cutoff_str
        )

        if len(recent_weeks) < PLATEAU_THRESHOLD_WEEKS:
            continue

        dense_weeks = []
        for wk in recent_weeks:
            wk_data = weeks_map[wk]
            set_count = wk_data.get("sets") or wk_data.get("set_count", 0)
            if set_count >= MIN_DATA_POINTS_PER_WEEK:
                dense_weeks.append(wk)

        if len(dense_weeks) < PLATEAU_THRESHOLD_WEEKS:
            continue

        e1rm_values = []
        rir_values = []
        for wk in dense_weeks:
            wk_data = weeks_map[wk]
            e1rm = wk_data.get("e1rm_max")
            if e1rm is not None and e1rm > 0:
                e1rm_values.append((wk, e1rm))
            if wk_data.get("rir_count") and wk_data.get("rir_sum") is not None:
                rir_values.append(wk_data["rir_sum"] / wk_data["rir_count"])

        if len(e1rm_values) < PLATEAU_THRESHOLD_WEEKS:
            continue

        baseline_e1rm = e1rm_values[0][1]
        tolerance = baseline_e1rm * 0.02

        consecutive_flat = 1
        max_consecutive_flat = 1

        for i in range(1, len(e1rm_values)):
            current_e1rm = e1rm_values[i][1]
            if current_e1rm <= baseline_e1rm + tolerance:
                consecutive_flat += 1
                max_consecutive_flat = max(max_consecutive_flat, consecutive_flat)
            else:
                baseline_e1rm = current_e1rm
                consecutive_flat = 1

        if max_consecutive_flat < PLATEAU_THRESHOLD_WEEKS:
            continue

        last_e1rm = e1rm_values[-1][1]
        avg_rir = round(sum(rir_values) / len(rir_values), 1) if rir_values else None

        plateaued.append({
            "exercise_name": exercise_name,
            "exercise_id": doc.id,
            "weeks_stalled": max_consecutive_flat,
            "last_e1rm": round(last_e1rm, 1),
            "suggested_action": _suggest_action(max_consecutive_flat, avg_rir),
        })

    return plateaued
