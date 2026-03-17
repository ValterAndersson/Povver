"""Volume optimizer — compares actual weekly sets against MEV/MRV targets.

Reads users/{uid}/analytics_series_muscle_group for the last 2 weeks
and compares weekly sets against evidence-based volume landmarks.

References:
- Schoenfeld et al. 2017 (dose-response for hypertrophy)
- Baz-Valle et al. 2022 (volume landmarks per muscle group)
- Israetel et al. 2018 (MEV/MRV framework)

Output: users/{uid}/analysis_insights/{autoId} with section: "volume_optimization"
"""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List

from app.analyzers.base import BaseAnalyzer
from app.config import TTL_INSIGHTS
from app.firestore_client import get_db

logger = logging.getLogger(__name__)

# Evidence-based MEV/MRV ranges (hard sets per week per muscle group)
# MEV = Minimum Effective Volume, MRV = Maximum Recoverable Volume
# Sources: Israetel et al. 2018; Schoenfeld et al. 2017; Baz-Valle et al. 2022
VOLUME_TARGETS = {
    "chest": {"mev": 10, "mrv": 20},
    "back": {"mev": 10, "mrv": 22},
    "quads": {"mev": 8, "mrv": 18},
    "hamstrings": {"mev": 6, "mrv": 16},
    "glutes": {"mev": 4, "mrv": 16},
    "shoulders": {"mev": 8, "mrv": 20},
    "biceps": {"mev": 6, "mrv": 18},
    "triceps": {"mev": 6, "mrv": 18},
    "calves": {"mev": 6, "mrv": 16},
    "abs": {"mev": 4, "mrv": 16},
    "traps": {"mev": 4, "mrv": 16},
    "forearms": {"mev": 4, "mrv": 14},
}

# How many weeks to average over
LOOKBACK_WEEKS = 2


def _classify_volume(actual_sets: float, mev: int, mrv: int) -> str:
    """Classify volume status relative to MEV/MRV landmarks.

    - deficit: below MEV (suboptimal stimulus)
    - optimal: between MEV and MRV (productive range)
    - surplus: above MRV (diminishing returns, fatigue accumulation)
    """
    if actual_sets < mev:
        return "deficit"
    elif actual_sets > mrv:
        return "surplus"
    else:
        return "optimal"


async def analyze_volume(db, user_id: str) -> dict:
    """Compare actual weekly volume against MEV/MRV targets per muscle group.

    Reads analytics_series_muscle_group for last 2 weeks, averages weekly
    hard_sets, and compares against VOLUME_TARGETS.

    Returns:
        Dict keyed by muscle_group:
        { muscle_group: { actual_sets, mev, mrv, status } }
    """
    ref = (
        db.collection("users").document(user_id)
        .collection("analytics_series_muscle_group")
    )

    # Read all muscle group docs (typically 8-12)
    docs = ref.stream()

    cutoff = datetime.now(timezone.utc) - timedelta(weeks=LOOKBACK_WEEKS)
    cutoff_str = cutoff.strftime("%Y-%m-%d")

    result = {}

    for doc in docs:
        data = doc.to_dict()
        muscle_group = doc.id
        weeks_map = BaseAnalyzer.extract_weeks_map(data)

        if not weeks_map:
            continue

        # Filter to recent weeks
        recent_weeks = [wk for wk in weeks_map.keys() if wk >= cutoff_str]

        if not recent_weeks:
            continue

        # Average hard_sets across recent weeks
        # Fall back to total sets if hard_sets not tracked
        weekly_sets = []
        for wk in recent_weeks:
            wk_data = weeks_map[wk]
            sets = wk_data.get("hard_sets") or wk_data.get("sets") or wk_data.get("set_count", 0)
            weekly_sets.append(sets)

        avg_sets = round(sum(weekly_sets) / len(weekly_sets), 1) if weekly_sets else 0

        # Look up targets (default to conservative ranges for unknown groups)
        targets = VOLUME_TARGETS.get(
            muscle_group.lower(),
            {"mev": 6, "mrv": 16},
        )
        mev = targets["mev"]
        mrv = targets["mrv"]

        result[muscle_group] = {
            "actual_sets": avg_sets,
            "mev": mev,
            "mrv": mrv,
            "status": _classify_volume(avg_sets, mev, mrv),
        }

    return result


class VolumeOptimizerAnalyzer(BaseAnalyzer):
    """Runs volume optimization analysis and writes results to analysis_insights."""

    def __init__(self):
        # No LLM call needed — purely algorithmic
        super().__init__(model_name="none")

    def analyze(self, user_id: str) -> Dict[str, Any]:
        """Analyze volume and write insight document.

        Returns:
            Result dict with success status and insight_id
        """
        self.log_event("volume_optimization_started", user_id=user_id)

        db = get_db()

        volume_data = _analyze_volume_sync(db, user_id)

        insight_id = self._write_insight(db, user_id, volume_data)

        # Compute summary stats
        statuses = [v["status"] for v in volume_data.values()]

        self.log_event(
            "volume_optimization_completed",
            user_id=user_id,
            insight_id=insight_id,
            muscle_groups_analyzed=len(volume_data),
            deficits=statuses.count("deficit"),
            surpluses=statuses.count("surplus"),
        )

        return {
            "success": True,
            "insight_id": insight_id,
            "volume_analysis": volume_data,
        }

    def _write_insight(
        self, db, user_id: str, volume_data: Dict[str, Dict[str, Any]]
    ) -> str:
        """Write volume optimization report to analysis_insights."""
        now = datetime.now(timezone.utc)
        expires_at = now + timedelta(days=TTL_INSIGHTS)

        # Separate into categories for quick scanning
        deficits = {k: v for k, v in volume_data.items() if v["status"] == "deficit"}
        surpluses = {k: v for k, v in volume_data.items() if v["status"] == "surplus"}
        optimal = {k: v for k, v in volume_data.items() if v["status"] == "optimal"}

        doc_data = {
            "type": "volume_optimization",
            "section": "volume_optimization",
            "created_at": now,
            "expires_at": expires_at,
            "volume_by_muscle": volume_data,
            "deficits": deficits,
            "surpluses": surpluses,
            "optimal": optimal,
        }

        ref = (
            db.collection("users").document(user_id)
            .collection("analysis_insights")
        )
        _, doc_ref = ref.add(doc_data)

        return doc_ref.id


def _analyze_volume_sync(db, user_id: str) -> dict:
    """Synchronous version of analyze_volume for use with sync Firestore client."""
    ref = (
        db.collection("users").document(user_id)
        .collection("analytics_series_muscle_group")
    )

    docs = ref.stream()

    cutoff = datetime.now(timezone.utc) - timedelta(weeks=LOOKBACK_WEEKS)
    cutoff_str = cutoff.strftime("%Y-%m-%d")

    result = {}

    for doc in docs:
        data = doc.to_dict()
        muscle_group = doc.id
        weeks_map = BaseAnalyzer.extract_weeks_map(data)

        if not weeks_map:
            continue

        recent_weeks = [wk for wk in weeks_map.keys() if wk >= cutoff_str]

        if not recent_weeks:
            continue

        weekly_sets = []
        for wk in recent_weeks:
            wk_data = weeks_map[wk]
            sets = wk_data.get("hard_sets") or wk_data.get("sets") or wk_data.get("set_count", 0)
            weekly_sets.append(sets)

        avg_sets = round(sum(weekly_sets) / len(weekly_sets), 1) if weekly_sets else 0

        targets = VOLUME_TARGETS.get(
            muscle_group.lower(),
            {"mev": 6, "mrv": 16},
        )
        mev = targets["mev"]
        mrv = targets["mrv"]

        result[muscle_group] = {
            "actual_sets": avg_sets,
            "mev": mev,
            "mrv": mrv,
            "status": _classify_volume(avg_sets, mev, mrv),
        }

    return result
