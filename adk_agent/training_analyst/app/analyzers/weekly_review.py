"""Weekly review analyzer - comprehensive training progression analysis.

Data budget: ~35KB to LLM
- 12 weeks of analytics_rollups (~6KB): per-week totals + per-muscle breakdowns
- Top 10 exercise series (~18KB): weekly e1rm_max, volume, sets per exercise
- 8 muscle group series (~10KB): weekly sets/volume/hard_sets per group
- Active routine template names (~1KB): structure context

Model: gemini-2.5-pro (temperature=0.2)
Output: users/{uid}/weekly_reviews/{YYYY-WNN} (TTL 30 days)
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from app.analyzers.base import BaseAnalyzer
from app.config import MODEL_PRO, TTL_REVIEWS
from app.firestore_client import get_db


class WeeklyReviewAnalyzer(BaseAnalyzer):
    """Generates comprehensive weekly training reviews."""

    def __init__(self):
        super().__init__(MODEL_PRO)

    def analyze(
        self, user_id: str, window_weeks: int = 12, week_ending: str = None
    ) -> Dict[str, Any]:
        """
        Generate weekly review for user.

        Args:
            user_id: User ID
            window_weeks: Number of weeks to analyze (default 12)
            week_ending: Week ending date YYYY-MM-DD (default: current week)

        Returns:
            Result dict with success status and review_id
        """
        if not week_ending:
            today = datetime.now(timezone.utc)
            days_until_sunday = (6 - today.weekday()) % 7
            week_ending = (today + timedelta(days=days_until_sunday)).strftime("%Y-%m-%d")

        self.log_event(
            "weekly_review_started",
            user_id=user_id,
            week_ending=week_ending,
            window_weeks=window_weeks,
        )

        db = get_db()

        # 1. Read 12 weeks of rollups (~6KB)
        rollups = self._read_rollups(db, user_id, weeks=window_weeks)

        # 2. Read top 15 exercise series by volume (~27KB)
        exercise_series = self._read_top_exercise_series(
            db, user_id, rollups, limit=15, weeks=window_weeks
        )

        # 3. Read 8 muscle group series (~10KB)
        muscle_group_series = self._read_muscle_group_series(
            db, user_id, weeks=window_weeks
        )

        # 4. Read active routine with full template content (~5KB)
        routine_with_templates = self._read_routine_with_templates(db, user_id)

        # 5. Read recent insights (last 7 days) (~2KB)
        recent_insights = self._read_recent_insights(db, user_id, days=7)

        # 6. Read recent template diffs for self-progression context (~1KB)
        self_progression = self._read_recent_template_diffs(db, user_id, weeks=1)

        # 7. Compute fatigue metrics from rollups
        rollups_map = {r["week_id"]: r for r in rollups}
        fatigue_metrics = self._compute_fatigue_metrics(rollups_map)

        # 7b. Read recommendation history for lifecycle tracking
        recommendation_history = self._read_recommendation_history(
            db, user_id, weeks=8
        )

        # 8. Build LLM input (~50KB total)
        llm_input_data = {
            "week_ending": week_ending,
            "window_weeks": window_weeks,
            "rollups": rollups,
            "exercise_series": exercise_series,
            "muscle_group_series": muscle_group_series,
        }
        if routine_with_templates:
            llm_input_data["routine_with_templates"] = routine_with_templates
        if recent_insights:
            llm_input_data["recent_insights"] = recent_insights
        if self_progression:
            llm_input_data["self_progression"] = self_progression
        if fatigue_metrics:
            llm_input_data["fatigue_metrics"] = fatigue_metrics
        if recommendation_history:
            llm_input_data["recommendation_history"] = recommendation_history
        llm_input = json.dumps(llm_input_data, indent=2, default=str)

        # 9. Call LLM (Pro for comprehensive analysis)
        result = self.call_llm(
            self._get_system_prompt(), llm_input,
            required_keys=["summary", "training_load", "muscle_balance",
                           "exercise_trends"],
            user_id=user_id,
        )

        # 10. Write to weekly_reviews/{YYYY-WNN}
        iso_week = self._date_to_iso_week(week_ending)
        self._write_review(db, user_id, iso_week, week_ending, result)

        self.log_event(
            "weekly_review_completed",
            user_id=user_id,
            iso_week=iso_week,
        )

        return {"success": True, "review_id": iso_week}

    def _read_rollups(
        self, db, user_id: str, weeks: int
    ) -> List[Dict[str, Any]]:
        """Read weekly analytics rollups with per-muscle breakdowns."""
        rollups = []
        ref = (
            db.collection("users").document(user_id)
            .collection("analytics_rollups")
        )

        docs = ref.order_by("updated_at", direction="DESCENDING").limit(weeks).stream()

        for doc in docs:
            data = doc.to_dict()
            rollups.append({
                "week_id": doc.id,
                "workouts": data.get("workouts", 0),
                "total_sets": data.get("total_sets", 0),
                "total_reps": data.get("total_reps", 0),
                "total_weight": data.get("total_weight", 0),
                "hard_sets_total": data.get("hard_sets_total", 0),
                "low_rir_sets_total": data.get("low_rir_sets_total", 0),
                # Per-muscle-group breakdowns for balance analysis
                "hard_sets_per_muscle_group": data.get("hard_sets_per_muscle_group", {}),
                "weight_per_muscle_group": data.get("weight_per_muscle_group", {}),
                # Per-muscle breakdowns for ACWR computation
                "load_per_muscle": data.get("load_per_muscle", {}),
                "hard_sets_per_muscle": data.get("hard_sets_per_muscle", {}),
            })

        return rollups

    def _read_top_exercise_series(
        self, db, user_id: str, rollups: List[Dict[str, Any]],
        limit: int, weeks: int
    ) -> List[Dict[str, Any]]:
        """Read top N exercise series by total volume from rollups.

        Each series doc has a 'weeks' map with weekly aggregate points.
        """
        # We can't easily rank by volume from rollups (they don't have per-exercise breakdown)
        # Instead, read all series docs and rank by recent volume
        ref = (
            db.collection("users").document(user_id)
            .collection("series_exercises")
        )

        # Read up to 30 docs and rank by total volume in last N weeks
        all_docs = ref.limit(30).stream()

        candidates = []
        for doc in all_docs:
            data = doc.to_dict()
            weeks_map = self.extract_weeks_map(data)

            sorted_weeks = sorted(weeks_map.keys(), reverse=True)[:weeks]

            total_volume = sum(
                weeks_map[wk].get("volume", 0) for wk in sorted_weeks
            )

            weekly_points = []
            for wk in sorted_weeks:
                raw = weeks_map[wk]
                weekly_points.append({
                    "week_start": wk,
                    "sets": raw.get("sets") or raw.get("set_count", 0),
                    "volume": raw.get("volume", 0),
                    "effective_volume": raw.get("effective_volume", 0),
                    "e1rm_max": raw.get("e1rm_max"),
                    "hard_sets": raw.get("hard_sets", 0),
                    "load_max": raw.get("load_max"),
                    "avg_rir": (
                        round(raw["rir_sum"] / raw["rir_count"], 1)
                        if raw.get("rir_count")
                        else None
                    ),
                })

            candidates.append({
                "exercise_id": doc.id,
                "exercise_name": data.get("exercise_name") or data.get("name"),
                "total_volume": total_volume,
                "weeks": weekly_points,
            })

        # Sort by total volume and take top N
        candidates.sort(key=lambda x: x["total_volume"], reverse=True)
        top = candidates[:limit]

        # Remove the ranking field from output
        for c in top:
            del c["total_volume"]

        return top

    def _read_muscle_group_series(
        self, db, user_id: str, weeks: int
    ) -> List[Dict[str, Any]]:
        """Read muscle group series for balance analysis.

        Each doc has a 'weeks' map with weekly aggregate points.
        """
        series = []
        ref = (
            db.collection("users").document(user_id)
            .collection("series_muscle_groups")
        )

        # Read all muscle group docs (typically 8-12)
        all_docs = ref.stream()

        for doc in all_docs:
            data = doc.to_dict()
            weeks_map = self.extract_weeks_map(data)

            sorted_weeks = sorted(weeks_map.keys(), reverse=True)[:weeks]

            weekly_points = []
            for wk in sorted_weeks:
                raw = weeks_map[wk]
                weekly_points.append({
                    "week_start": wk,
                    "sets": raw.get("sets") or raw.get("set_count", 0),
                    "volume": raw.get("volume", 0),
                    "effective_volume": raw.get("effective_volume", 0),
                    "hard_sets": raw.get("hard_sets", 0),
                    "avg_rir": (
                        round(raw["rir_sum"] / raw["rir_count"], 1)
                        if raw.get("rir_count")
                        else None
                    ),
                })

            series.append({
                "muscle_group": doc.id,
                "weeks": weekly_points,
            })

        return series[:8]  # Cap at 8 muscle groups

    def _read_routine_with_templates(
        self, db, user_id: str
    ) -> Optional[Dict[str, Any]]:
        """Read active routine with full template content (batch read with db.get_all()).

        Returns routine metadata + template set details for full routine analysis.
        """
        user_doc = db.collection("users").document(user_id).get()
        if not user_doc.exists:
            return None

        user_data = user_doc.to_dict()
        routine_id = user_data.get("activeRoutineId")
        if not routine_id:
            return None

        routine_doc = (
            db.collection("users").document(user_id)
            .collection("routines").document(routine_id).get()
        )
        if not routine_doc.exists:
            return None

        routine = routine_doc.to_dict()
        template_ids = routine.get("template_ids", [])
        if not template_ids:
            return None

        # Batch read templates with full content
        template_refs = [
            db.collection("users").document(user_id)
            .collection("templates").document(tid)
            for tid in template_ids[:10]  # Cap at 10
        ]
        template_docs = db.get_all(template_refs)

        templates = []
        for tdoc in template_docs:
            if tdoc.exists:
                tdata = tdoc.to_dict()
                exercises = []
                for ex in tdata.get("exercises", []):
                    exercises.append({
                        "exercise_id": ex.get("exercise_id"),
                        "name": ex.get("exercise_name") or ex.get("name"),
                        "sets": [
                            {
                                "reps": s.get("reps"),
                                "rir": s.get("rir"),
                                "weight": s.get("weight"),  # Template prescription
                            }
                            for s in ex.get("sets", [])
                        ],
                    })
                templates.append({
                    "template_id": tdoc.id,
                    "name": tdata.get("name", tdoc.id),
                    "exercises": exercises,
                })

        return {
            "routine_name": routine.get("name"),
            "frequency": routine.get("frequency"),
            "templates": templates,
        }

    def _read_recent_insights(
        self, db, user_id: str, days: int = 7
    ) -> Optional[List[Dict[str, Any]]]:
        """Read recent analysis_insights from last N days.

        Handles missing index gracefully by catching exceptions.
        """
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)

        try:
            docs = (
                db.collection("users").document(user_id)
                .collection("analysis_insights")
                .where("created_at", ">=", cutoff)
                .order_by("created_at", direction="DESCENDING")
                .limit(5)
                .stream()
            )

            insights = []
            for doc in docs:
                data = doc.to_dict()
                insights.append({
                    "workout_date": data.get("workout_date"),
                    "summary": data.get("summary", ""),
                    "highlights": data.get("highlights", [])[:3],
                    "flags": data.get("flags", [])[:3],
                    "recommendations": [
                        {
                            "type": r.get("type"),
                            "target": r.get("target"),
                            "action": r.get("action"),
                        }
                        for r in (data.get("recommendations") or [])[:5]
                    ],
                })

            return insights if insights else None
        except Exception as e:
            # Missing index or other error - log warning and return None
            logging.getLogger(__name__).warning(
                "Failed to read recent insights for user %s: %s", user_id, e
            )
            return None

    def _read_recent_template_diffs(
        self, db, user_id: str, weeks: int = 1
    ) -> Optional[Dict[str, Any]]:
        """Read template_diff fields from recent workouts for self-progression context.

        Returns aggregated counts of user-initiated changes over the last N weeks.
        Only includes workouts where changes_detected is true.
        """
        cutoff = datetime.now(timezone.utc) - timedelta(weeks=weeks)

        try:
            docs = (
                db.collection("users").document(user_id)
                .collection("workouts")
                .where("end_time", ">=", cutoff)
                .order_by("end_time", direction="DESCENDING")
                .limit(20)
                .stream()
            )

            weight_increases = 0
            weight_decreases = 0
            exercise_swaps = 0
            exercises_added = 0
            exercises_removed = 0
            sets_added = 0
            sets_removed = 0
            workouts_with_changes = 0

            for doc in docs:
                data = doc.to_dict()
                diff = data.get("template_diff")
                if not diff or not diff.get("changes_detected"):
                    continue

                workouts_with_changes += 1

                for wc in diff.get("weight_changes", []):
                    if wc.get("direction") == "increased":
                        weight_increases += 1
                    elif wc.get("direction") == "decreased":
                        weight_decreases += 1

                exercise_swaps += len(diff.get("exercises_swapped", []))
                exercises_added += len(diff.get("exercises_added", []))
                exercises_removed += len(diff.get("exercises_removed", []))
                sets_added += diff.get("sets_added_count", 0)
                sets_removed += diff.get("sets_removed_count", 0)

            if workouts_with_changes == 0:
                return None

            return {
                "workouts_with_changes": workouts_with_changes,
                "weight_increases": weight_increases,
                "weight_decreases": weight_decreases,
                "exercise_swaps": exercise_swaps,
                "exercises_added": exercises_added,
                "exercises_removed": exercises_removed,
                "sets_added": sets_added,
                "sets_removed": sets_removed,
            }
        except Exception as e:
            logging.getLogger(__name__).warning(
                "Failed to read template diffs for user %s: %s", user_id, e
            )
            return None

    def _read_recommendation_history(
        self, db, user_id: str, weeks: int = 8
    ) -> List[Dict[str, Any]]:
        """Read recommendation history for weekly review context.

        Compact format — broader scope, less per-item detail than post-workout.
        Used to track acceptance rates, progression velocity, and rejection patterns.
        """
        try:
            cutoff = datetime.now(timezone.utc) - timedelta(weeks=weeks)
            docs = (
                db.collection("users").document(user_id)
                .collection("agent_recommendations")
                .where("created_at", ">=", cutoff)
                .order_by("created_at", direction="DESCENDING")
                .limit(25)
                .stream()
            )

            history = []
            for doc in docs:
                data = doc.to_dict()
                rec = data.get("recommendation", {})
                target = data.get("target", {})
                history.append({
                    "created_at": (
                        data["created_at"].isoformat()
                        if hasattr(data.get("created_at"), "isoformat")
                        else str(data.get("created_at", ""))
                    ),
                    "state": data.get("state", "unknown"),
                    "scope": data.get("scope"),
                    "trigger": data.get("trigger"),
                    "target": {
                        "exercise_name": target.get("exercise_name"),
                        "template_name": target.get("template_name"),
                    },
                    "type": rec.get("type"),
                    "summary": rec.get("summary", ""),
                    "confidence": rec.get("confidence"),
                    "changes": [
                        {
                            "path": c.get("path"),
                            "from": c.get("from"),
                            "to": c.get("to"),
                        }
                        for c in rec.get("changes", [])
                    ],
                    "applied_at": (
                        data["applied_at"].isoformat()
                        if hasattr(data.get("applied_at"), "isoformat")
                        else data.get("applied_at")
                    ),
                    "applied_by": data.get("applied_by"),
                })

            return history
        except Exception as e:
            logging.getLogger(__name__).warning(
                "Failed to read recommendation history for user %s: %s",
                user_id, e,
            )
            return []

    def _write_review(
        self, db, user_id: str, iso_week: str,
        week_ending: str, result: Dict[str, Any]
    ) -> None:
        """Write review to weekly_reviews/{YYYY-WNN} with plan-specified schema.

        Includes new optional fields: periodization, routine_recommendations, fatigue_status.
        """
        now = datetime.now(timezone.utc)
        expires_at = now + timedelta(days=TTL_REVIEWS)

        doc_data = {
            "created_at": now,
            "expires_at": expires_at,
            "week_ending": week_ending,
            "summary": result.get("summary", ""),
            "training_load": result.get("training_load", {}),
            "muscle_balance": result.get("muscle_balance", []),
            "exercise_trends": result.get("exercise_trends", []),
            "progression_candidates": result.get("progression_candidates", []),
            "stalled_exercises": result.get("stalled_exercises", []),
            # New optional fields (use .get() with defaults)
            "periodization": result.get("periodization"),
            "routine_recommendations": result.get("routine_recommendations", []),
            "fatigue_status": result.get("fatigue_status"),
        }

        ref = (
            db.collection("users").document(user_id)
            .collection("weekly_reviews")
        )
        ref.document(iso_week).set(doc_data)

    def _date_to_iso_week(self, date_str: str) -> str:
        """Convert YYYY-MM-DD to YYYY-WNN."""
        date = datetime.strptime(date_str, "%Y-%m-%d")
        iso = date.isocalendar()
        return f"{iso[0]}-W{iso[1]:02d}"

    def _get_system_prompt(self) -> str:
        return """You are a training analyst providing a comprehensive weekly progression review.

**EVIDENCE-BASED PRINCIPLES:**

1. **Progressive Overload** (Schoenfeld 2010; Progression of Load Review)
   Primary driver of muscle adaptation. Incremental increases in load, volume, or intensity over time.
   Mechanism: mechanical tension → satellite cell activation → muscle protein synthesis.

2. **Proximity to Failure** (Schoenfeld et al. 2017; Martinez-Hernandez et al. 2024)
   Training within 0-3 RIR produces similar hypertrophy to failure. RIR 4+ reduces stimulus.
   RIR 0-1 increases fatigue cost without proportional gains for most lifters.
   RIR 1-3 = optimal stimulus-to-fatigue ratio.

3. **Volume Landmarks** (Schoenfeld et al. 2017; Baz-Valle et al. 2022)
   Per muscle per week: 10-20 hard sets = optimal zone. <10 = suboptimal stimulus. >20 = diminishing returns + fatigue accumulation.
   Hard set = within 0-3 RIR.

4. **Stimulus-to-Fatigue Ratio** (Israetel et al. 2018; Helms et al. 2018)
   Not all volume is equal. Effective volume = hard sets that produce adaptation without excessive fatigue.
   Junk volume = high-RIR sets, redundant exercises, or volume beyond recovery capacity.

5. **Fatigue Management & ACWR** (Gabbett 2016; Hulin et al. 2014)
   Acute:Chronic Workload Ratio predicts injury risk and performance readiness.
   ACWR 0.8-1.3 = "sweet spot". <0.8 = detraining risk. >1.5 = overreaching/injury risk.
   Use fatigue_metrics (if present) to contextualize volume recommendations.

6. **Periodization** (Rhea et al. 2003; Williams et al. 2017)
   Planned variation in volume/intensity prevents plateaus and manages fatigue.
   Block periodization (4-12 weeks per block) > constant linear progression for intermediate+ lifters.

7. **Exercise Selection Hierarchy** (Schoenfeld & Contreras 2016)
   Compound lifts (squat, deadlift, bench, row) = high stimulus, multi-muscle recruitment.
   Isolation lifts = targeted hypertrophy, lower systemic fatigue.
   Swap exercises when: (a) plateau >6 weeks, (b) pain/form breakdown, (c) poor muscle activation.

**CONTEXT DATA:**

Analyze the training data across a 12-week window. You have:
- **rollups**: Weekly totals (sets, volume, intensity metrics, per-muscle-group breakdowns)
- **exercise_series**: Top 15 exercises with weekly e1RM, volume, sets, RIR progression
- **muscle_group_series**: Weekly volume and intensity per muscle group
- **routine_with_templates** (if present): Full routine structure + template set prescriptions
- **recent_insights** (if present): Last 7 days of post-workout analysis summaries
- **self_progression** (if present): User-initiated template modifications this week
- **fatigue_metrics** (if present): Pre-computed ACWR (systemic + per-muscle)

**FULL ROUTINE ANALYSIS (if routine_with_templates present):**
If routine_with_templates is in the input, you have the complete program structure. Use this to:
- Assess if the routine is balanced (e.g., Push/Pull/Legs hitting all muscle groups)
- Identify if exercise selection aligns with principles (compound-first, isolation for weak points)
- Compare actual performed volume vs. template prescriptions (are they following the plan?)
- Flag missing muscle groups from the routine split
- Suggest routine-level adjustments (e.g., "add a second leg day", "reduce push frequency")

**PREVIOUS RECOMMENDATIONS (if recent_insights present):**
If recent_insights is in the input, you have the last 7 days of post-workout recommendations. Use this to:
- Track if user implemented previous suggestions (e.g., "recommended deload on bench, user dropped weight this week")
- Avoid redundant recommendations (e.g., don't repeat same progression if already suggested)
- Escalate unaddressed flags (e.g., "overreach warning persists for 3 sessions")

**FATIGUE MONITORING (if fatigue_metrics present):**
If fatigue_metrics is in the input, you have pre-computed ACWR. Use this to:
- Assess systemic fatigue status (ACWR <0.8 = detraining, 0.8-1.3 = optimal, >1.5 = overreaching)
- Identify per-muscle fatigue (e.g., "chest ACWR 1.6 = overreached, back ACWR 0.7 = undertrained")
- Recommend volume adjustments based on ACWR (e.g., "reduce push sets by 15%", "increase pull volume")
- Flag injury risk when ACWR >1.5 for 2+ consecutive weeks
- Cite: "Fatigue Management & ACWR — ratio >1.5 predicts injury risk"

SELF-PROGRESSION: If "self_progression" is present in the input, the user made
independent modifications to their templates during workouts this week. Weight
increases indicate the user is self-progressing — acknowledge this positively
in the summary. Don't recommend progressions the user has already made.
Exercise swaps indicate preference changes — note them but don't flag as issues.

**RECOMMENDATION HISTORY (if recommendation_history present):**
If recommendation_history is in the input, you have the lifecycle of past recommendations.
Use this to:
- **Acceptance rate patterns**: Track how many recommendations were accepted vs. rejected.
  If acceptance rate is low (<30%), note this in the summary and consider if recommendation
  types need adjustment.
- **Progression velocity**: Use applied recommendations to gauge how fast the user is
  progressing. Frequent applied progressions = fast progression, consider periodization.
- **Rejection patterns**: If the user consistently rejects a category (e.g., always rejects
  deloads), adjust your recommendations. Still flag the underlying signal but suggest
  alternative actions.
- **Persistence on valid rejections**: If data still supports a rejected recommendation,
  re-recommend with stronger evidence. Reference the previous rejection:
  "Previously suggested [X] — signal persists: [updated data]."

**CRITICAL RULES:**
- ONLY reference exercise names, IDs, and muscle groups that appear in the input data. NEVER invent data.
- Every numeric claim (e1RM, volume, sets, slopes) MUST be computed from the provided data.
- If fewer than 4 weeks of rollup data exist, state "limited history" in summary and do NOT output progression_candidates or stalled_exercises (too little data for reliable trend detection).
- e1rm_slope: compute as (latest_e1rm - earliest_e1rm) / weeks_analyzed. Unit is kg/week.
- current_weight in progression_candidates = the load_max from the most recent week in that exercise's series.
- exercise_id and exercise_name in outputs MUST match values from the input exercise_series.
- When citing principles, reference the mechanism or threshold (e.g., "Volume Landmarks — 10-20 hard sets/week optimal" not just "good volume").

Return JSON matching this schema EXACTLY:
{
  "summary": "2-3 sentence paragraph summarizing the training week in context of the window",
  "training_load": {
    "sessions": 4,
    "total_sets": 80,
    "total_volume": 45000,
    "vs_last_week": { "sets_delta": 5, "volume_delta": 2000 }
  },
  "muscle_balance": [
    {
      "muscle_group": "chest",
      "weekly_sets": 16,
      "trend": "increasing | stable | decreasing",
      "status": "optimal | undertrained | overtrained"
    }
  ],
  "exercise_trends": [
    {
      "exercise_id": "from input",
      "exercise_name": "from input",
      "trend": "improving | plateaued | declining",
      "e1rm_slope": 0.5,
      "weeks_analyzed": 12,
      "note": "Brief observation citing specific numbers"
    }
  ],
  "progression_candidates": [
    {
      "exercise_id": "from input",
      "exercise_name": "from input",
      "current_weight": 100,
      "suggested_weight": 102.5,
      "target_reps": null,
      "rationale": "Evidence from the data",
      "reasoning": "why this candidate qualifies for progression",
      "signals": ["e1rm_slope: +0.8 kg/week over 6 weeks", "consistent RIR 1.5-2.0"],
      "confidence": 0.0-1.0
    }
  ],
  "stalled_exercises": [
    {
      "exercise_id": "from input",
      "exercise_name": "from input",
      "weeks_stalled": 5,
      "suggested_action": "increase_weight | deload | swap | vary_rep_range",
      "suggested_weight": null,
      "target_reps": null,
      "rationale": "Evidence from the data. CITE principle (e.g., 'Periodization — planned variation prevents plateaus')",
      "reasoning": "why this exercise is stalled and why this action is suggested",
      "signals": ["e1RM flat at 65kg for 5 weeks", "avg RIR 1.5 (not an effort issue)"]
    }
  ],
  "periodization": {
    "current_phase": "hypertrophy | strength | deload | maintenance",
    "weeks_in_phase": 6,
    "recommendation": "continue | transition | deload",
    "rationale": "Why this periodization recommendation. CITE principle (e.g., 'Block periodization — 4-12 weeks per block optimal')"
  },
  "routine_recommendations": [
    {
      "type": "frequency | split | exercise_selection | volume_distribution",
      "action": "Specific routine-level change (e.g., 'add second leg day', 'swap PPL to Upper/Lower')",
      "reasoning": "Why this routine change is needed. CITE principle (e.g., 'Volume Landmarks — legs getting <10 sets/week')",
      "signals": ["legs: 8 hard sets/week (below optimal)", "push: 24 hard sets/week (excessive)"]
    }
  ],
  "fatigue_status": {
    "systemic_acwr": 1.2,
    "status": "fresh | building | fatigued | overreached",
    "high_risk_muscles": ["chest", "shoulders"],
    "recommendation": "Cite ACWR principle (e.g., 'ACWR >1.5 = injury risk, reduce push volume by 15%')"
  }
}

DOUBLE PROGRESSION in progression_candidates:
- If exercise is NOT at target reps (user consistently doing fewer reps than template prescribes),
  set target_reps to the target rep count, leave suggested_weight as null.
- If exercise IS at target reps with low RIR (≤2), set suggested_weight, leave target_reps as null.
- If both are null, the candidate relies on suggested_weight (default behavior for weight progression).

STALLED EXERCISES — set numeric fields based on suggested_action:
- vary_rep_range: set target_reps (e.g., if stuck at 5 reps, suggest 8), leave suggested_weight null
- deload: set suggested_weight (90% of current), leave target_reps null
- increase_weight: set suggested_weight (computed via progression rules), leave target_reps null
- swap: neither field needed (null for both)

Validation:
- target_reps must be > 0 and ≤ 30 when set
- suggested_weight must be > 0 when set

For progression_candidates and stalled_exercises:
- "reasoning" explains the logic chain: which metrics triggered this, why the suggestion follows
- "signals" lists 2-4 key data points supporting the assessment, each a short phrase with numbers

Detection rules:
- training_load: Compute from the most recent week's rollup. vs_last_week compares rollups[0] to rollups[1].
- muscle_balance: Assess each group from muscle_group_series — average weekly hard_sets over the window.
  - optimal: 10-20 hard sets/week, undertrained: <10, overtrained: >20
- exercise_trends: Classify based on e1RM trajectory across the exercise's weekly points.
  - improving: e1rm_slope > 0.5 kg/week (compounds) or > 0.25 kg/week (isolation)
  - plateaued: e1rm_slope within ±0.25 kg/week for 4+ data points
  - declining: e1rm_slope < -0.5 kg/week
- progression_candidates: ONLY exercises with improving trend AND confidence > 0.7 AND at least 4 weeks of data.
  - current_weight = load_max from most recent week in exercise series
  - suggested_weight = +2.5% for compounds (>40kg), +5% for isolation
    Round to 2.5kg or 1.25kg. If rounding kills increment, bump one step. Cap +5kg.
- stalled_exercises: ONLY exercises plateaued or declining for 4+ consecutive weeks with data.
  Choose suggested_action by weighing RIR and stall duration together:
  - increase_weight: avg RIR ≥ 2 AND stalled < 6 weeks (user has room to push)
  - deload: avg RIR < 2 OR stalled ≥ 4 weeks at low RIR (fatigue-limited)
  - swap: stalled > 6 weeks despite previous changes
  - vary_rep_range: if stuck in same rep range every week with RIR ≥ 2
For swap recommendations:
  - Estimate replacement weight: BB→DB = 37% per hand, same-muscle different movement = 80%.

**NEW OPTIONAL FIELDS:**

**periodization** (optional — only if you can infer current phase from data):
- Infer current_phase from recent intensity/volume patterns (e.g., high volume + RIR 2-3 = hypertrophy, low volume + high intensity = strength)
- weeks_in_phase = estimate based on how long current pattern has persisted
- recommendation = "continue" if <4 weeks, "transition" if >8 weeks, "deload" if ACWR >1.3 for 2+ weeks
- Cite: "Block periodization — 4-12 weeks per block optimal"

**routine_recommendations** (optional — only if routine_with_templates present):
- frequency: e.g., "increase leg frequency from 1x to 2x/week" (cite Volume Landmarks)
- split: e.g., "swap PPL to Upper/Lower for better recovery" (cite Periodization)
- exercise_selection: e.g., "add Romanian deadlifts for hamstring development" (cite Exercise Selection Hierarchy)
- volume_distribution: e.g., "reduce push sets by 20%, increase pull by 30%" (cite Volume Landmarks)

**fatigue_status** (optional — only if fatigue_metrics present):
- systemic_acwr from fatigue_metrics.systemic.acwr
- status: "fresh" (<0.8), "building" (0.8-1.1), "fatigued" (1.1-1.5), "overreached" (>1.5)
- high_risk_muscles: list muscles with ACWR >1.5 from fatigue_metrics.per_muscle
- recommendation: specific volume adjustment citing ACWR threshold (e.g., "chest ACWR 1.6 — reduce push sets by 15%")

Do NOT include these optional fields if you lack the necessary input data. Leave them as null or omit from output."""
