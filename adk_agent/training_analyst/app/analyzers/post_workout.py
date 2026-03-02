"""Post-workout analyzer - immediate feedback after workout completion.

Data budget: ~8KB to LLM
- Trimmed workout (~1.5KB): exercise names + set summaries
- 4 weeks of rollups (~2KB): weekly totals
- Exercise series (~4KB): weekly points for exercises in this workout

Model: gemini-2.5-pro (temperature=0.2)
Output: users/{uid}/analysis_insights/{autoId} (TTL 7 days)
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from app.analyzers.base import BaseAnalyzer
from app.config import MODEL_PRO, TTL_INSIGHTS
from app.firestore_client import get_db


class PostWorkoutAnalyzer(BaseAnalyzer):
    """Analyzes completed workouts against recent aggregated trends."""

    def __init__(self):
        super().__init__(MODEL_PRO)

    def analyze(self, user_id: str, workout_id: str) -> Dict[str, Any]:
        """
        Analyze a completed workout.

        Args:
            user_id: User ID
            workout_id: Completed workout document ID

        Returns:
            Result dict with success status and insight_id
        """
        self.log_event("post_workout_started", user_id=user_id, workout_id=workout_id)

        db = get_db()

        # 1. Read workout (trimmed to ~1.5KB)
        workout = self._read_workout_trimmed(db, user_id, workout_id)
        if not workout:
            raise ValueError(f"Workout {workout_id} not found for user {user_id}")

        # 2. Read 8 weeks of analytics rollups (~4KB)
        rollups_list = self._read_rollups(db, user_id, weeks=8)

        # 3. Read exercise series for exercises in this workout (~8KB)
        exercise_ids = [
            ex["exercise_id"] for ex in workout.get("exercises", [])
            if ex.get("exercise_id")
        ]
        series = self._read_exercise_series(db, user_id, exercise_ids, weeks=8)

        # 4. Read routine summary (template IDs → template names)
        routine_context = self._read_routine_summary(db, user_id)

        # 5. Read exercise catalog (batch read muscles for exercises in workout)
        exercise_catalog = self._read_exercise_catalog(db, exercise_ids)

        # 6. Compute fatigue metrics from rollups
        rollups_map = {r["week_id"]: r for r in rollups_list}
        fatigue_metrics = self._compute_fatigue_metrics(rollups_map)

        # 6b. Read recommendation history for deduplication context
        recommendation_history = self._read_recommendation_history(
            db, user_id, weeks=4
        )

        # 7. Build LLM input (~20KB total)
        llm_input_data = {
            "workout": workout,
            "recent_rollups": rollups_list,
            "exercise_series": series,
        }
        if routine_context:
            llm_input_data["routine_context"] = routine_context
        if exercise_catalog:
            llm_input_data["exercise_catalog"] = exercise_catalog
        if fatigue_metrics:
            llm_input_data["fatigue_metrics"] = fatigue_metrics
        if recommendation_history:
            llm_input_data["recommendation_history"] = recommendation_history

        llm_input = json.dumps(llm_input_data, indent=2, default=str)

        # 8. Call LLM
        result = self.call_llm(
            self._get_system_prompt(), llm_input,
            required_keys=["summary", "highlights", "flags", "recommendations"],
            user_id=user_id,
        )

        # 9. Write to analysis_insights
        insight_id = self._write_insight(db, user_id, workout_id, workout, result)

        self.log_event(
            "post_workout_completed",
            user_id=user_id,
            workout_id=workout_id,
            insight_id=insight_id,
        )

        return {"success": True, "insight_id": insight_id}

    def _read_workout_trimmed(
        self, db, user_id: str, workout_id: str
    ) -> Optional[Dict[str, Any]]:
        """Read workout and trim to exercise summaries only (~1.5KB).

        NEVER passes raw set data to LLM. Extracts only:
        - Exercise names, IDs, working set count
        - Top weight, rep range, avg RIR, volume, e1RM
        - Workout-level analytics summary (if present)
        """
        doc = (
            db.collection("users").document(user_id)
            .collection("workouts").document(workout_id).get()
        )
        if not doc.exists:
            return None

        data = doc.to_dict()
        started = data.get("started_at") or data.get("start_time")
        ended = data.get("ended_at") or data.get("end_time")

        # Calculate duration
        duration_minutes = data.get("duration_minutes")
        if not duration_minutes and started and ended:
            try:
                delta = ended - started
                duration_minutes = round(delta.total_seconds() / 60)
            except Exception:
                duration_minutes = None

        # Extract date string
        workout_date = None
        if ended:
            try:
                workout_date = ended.strftime("%Y-%m-%d") if hasattr(ended, "strftime") else str(ended)[:10]
            except Exception:
                pass

        trimmed = {
            "workout_date": workout_date,
            "duration_minutes": duration_minutes,
            "notes": data.get("notes"),  # Workout-level context
            "exercises": [],
        }

        for ex in data.get("exercises", []):
            sets = ex.get("sets", [])
            # Filter to working sets only (exclude warmups)
            # Sets use type: "warmup" | "working" (not is_warmup boolean)
            working_sets = [s for s in sets if s.get("type") != "warmup"]
            if not working_sets:
                # All sets are warmups — skip this exercise entirely
                continue

            weights = [s.get("weight_kg", 0) for s in working_sets if s.get("weight_kg")]
            reps_list = [s.get("reps", 0) for s in working_sets if s.get("reps")]
            rirs = [s.get("rir") for s in working_sets if s.get("rir") is not None]

            volume = sum(
                (s.get("weight_kg", 0) or 0) * (s.get("reps", 0) or 0)
                for s in working_sets
            )

            # e1RM from best set (Epley, reps <= 12)
            e1rm = None
            for s in working_sets:
                r = s.get("reps", 0) or 0
                w = s.get("weight_kg", 0) or 0
                if 0 < r <= 12 and w > 0:
                    est = round(w * (1 + r / 30), 1)
                    if e1rm is None or est > e1rm:
                        e1rm = est

            # Rep range string
            rep_range = None
            if reps_list:
                mn, mx = min(reps_list), max(reps_list)
                rep_range = str(mn) if mn == mx else f"{mn}-{mx}"

            ex_entry = {
                "name": ex.get("exercise_name") or ex.get("name"),
                "exercise_id": ex.get("exercise_id"),
                "working_sets": len(working_sets),
                "top_weight_kg": max(weights) if weights else None,
                "rep_range": rep_range,
                "avg_rir": round(sum(rirs) / len(rirs), 1) if rirs else None,
                "volume": round(volume),
                "e1rm": e1rm,
                "notes": ex.get("notes"),  # Exercise-level context
            }
            # Remove None notes to save token budget
            if ex_entry.get("notes") is None:
                ex_entry.pop("notes", None)
            trimmed["exercises"].append(ex_entry)

        # Include workout-level analytics summary if present
        analytics = data.get("analytics")
        if analytics:
            trimmed["analytics_summary"] = {
                "total_sets": analytics.get("total_sets"),
                "total_volume": analytics.get("total_volume") or analytics.get("total_weight"),
                "muscle_groups_hit": list(
                    (analytics.get("muscle_groups") or {}).keys()
                )[:10],
            }

        # Include template_diff if user deviated from template (~500B)
        template_diff = data.get("template_diff")
        if template_diff and template_diff.get("changes_detected"):
            trimmed["template_diff"] = {
                "summary": template_diff.get("summary", ""),
                "weight_changes": template_diff.get("weight_changes", []),
                "rep_changes": template_diff.get("rep_changes", []),
                "exercises_added": [
                    e.get("exercise_name", e.get("exercise_id"))
                    for e in template_diff.get("exercises_added", [])
                ],
                "exercises_removed": [
                    e.get("exercise_name", e.get("exercise_id"))
                    for e in template_diff.get("exercises_removed", [])
                ],
                "exercises_swapped": [
                    {
                        "from": s.get("from_name", s.get("from_id")),
                        "to": s.get("to_name", s.get("to_id")),
                    }
                    for s in template_diff.get("exercises_swapped", [])
                ],
                "sets_added": template_diff.get("sets_added_count", 0),
                "sets_removed": template_diff.get("sets_removed_count", 0),
            }

        # Remove None notes to save token budget
        if trimmed.get("notes") is None:
            trimmed.pop("notes", None)

        return trimmed

    def _read_rollups(
        self, db, user_id: str, weeks: int
    ) -> List[Dict[str, Any]]:
        """Read weekly analytics rollups (~500B each).

        Reads from users/{uid}/analytics_rollups ordered by doc ID desc.
        """
        rollups = []
        ref = (
            db.collection("users").document(user_id)
            .collection("analytics_rollups")
        )

        # Rollup doc IDs are week-start dates (YYYY-MM-DD) or yyyy-ww
        # Rollup doc IDs are week-start dates — fetch recent and sort in Python
        # (avoids needing a composite index on __name__)
        docs = ref.order_by("updated_at", direction="DESCENDING").limit(weeks).stream()

        for doc in docs:
            data = doc.to_dict()
            rollups.append({
                "week_id": doc.id,
                "workouts": data.get("workouts", 0),
                "total_sets": data.get("total_sets", 0),
                "total_weight": data.get("total_weight", 0),
                "hard_sets_total": data.get("hard_sets_total", 0),
                "low_rir_sets_total": data.get("low_rir_sets_total", 0),
                # Per-muscle breakdowns for ACWR computation
                "load_per_muscle": data.get("load_per_muscle", {}),
                "hard_sets_per_muscle": data.get("hard_sets_per_muscle", {}),
            })

        return rollups

    def _read_exercise_series(
        self, db, user_id: str, exercise_ids: List[str], weeks: int
    ) -> List[Dict[str, Any]]:
        """Read exercise series weekly points for specific exercises.

        Each series doc has a 'weeks' map: { "YYYY-MM-DD": { sets, volume, e1rm_max, ... } }
        We extract only the last N weeks of data.
        """
        series = []
        ref = (
            db.collection("users").document(user_id)
            .collection("series_exercises")
        )

        for ex_id in exercise_ids[:15]:  # Cap to avoid oversized reads
            doc = ref.document(ex_id).get()
            if not doc.exists:
                continue

            data = doc.to_dict()
            weeks_map = self.extract_weeks_map(data)

            # Sort week keys descending, take last N
            sorted_weeks = sorted(weeks_map.keys(), reverse=True)[:weeks]

            weekly_points = []
            for wk in sorted_weeks:
                raw = weeks_map[wk]
                weekly_points.append({
                    "week_start": wk,
                    "sets": raw.get("sets") or raw.get("set_count", 0),
                    "volume": raw.get("volume", 0),
                    "e1rm_max": raw.get("e1rm_max"),
                    "hard_sets": raw.get("hard_sets", 0),
                    "load_max": raw.get("load_max"),
                    "avg_rir": (
                        round(raw["rir_sum"] / raw["rir_count"], 1)
                        if raw.get("rir_count")
                        else None
                    ),
                })

            series.append({
                "exercise_id": ex_id,
                "exercise_name": data.get("exercise_name") or data.get("name"),
                "weeks": weekly_points,
            })

        return series

    def _read_routine_summary(
        self, db, user_id: str
    ) -> Optional[Dict[str, Any]]:
        """Read routine summary with full exercise lists per template.

        For swap recommendations, the LLM needs to know which exercises
        exist across the entire routine to avoid suggesting duplicates.
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

        # Batch read templates
        template_refs = [
            db.collection("users").document(user_id)
            .collection("templates").document(tid)
            for tid in template_ids[:10]  # Cap at 10
        ]
        template_docs = db.get_all(template_refs)

        templates = []
        all_exercise_ids = set()
        for tdoc in template_docs:
            if tdoc.exists:
                tdata = tdoc.to_dict()
                exercises = []
                for ex in tdata.get("exercises", []):
                    ex_id = ex.get("exercise_id")
                    if ex_id:
                        all_exercise_ids.add(ex_id)
                    exercises.append({
                        "exercise_id": ex_id,
                        "name": ex.get("name"),
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
            "all_exercise_ids": list(all_exercise_ids),
        }

    def _read_exercise_catalog(
        self, db, exercise_ids: List[str]
    ) -> Optional[List[Dict[str, Any]]]:
        """Read exercise catalog (batch read muscles for exercises in workout).

        Caps at 15 exercises to avoid oversized reads.
        """
        if not exercise_ids:
            return None

        # Cap at 15 exercises
        capped_ids = exercise_ids[:15]

        # Batch read from exercise_catalog
        exercise_refs = [
            db.collection("exercise_catalog").document(ex_id)
            for ex_id in capped_ids
        ]
        exercise_docs = db.get_all(exercise_refs)

        catalog = []
        for edoc in exercise_docs:
            if edoc.exists:
                edata = edoc.to_dict()
                muscles = edata.get("muscles", {})
                catalog.append({
                    "exercise_id": edoc.id,
                    "name": edata.get("name", edoc.id),
                    "primary_muscles": muscles.get("primary", []),
                    "secondary_muscles": muscles.get("secondary", []),
                })

        return catalog if catalog else None

    def _read_recommendation_history(
        self, db, user_id: str, weeks: int = 4
    ) -> List[Dict[str, Any]]:
        """Read recent recommendation history for deduplication context.

        Returns deep format with full changes array, rationale, signals,
        and state — used by the LLM to avoid redundant recommendations.
        ~4KB addition to ~20KB input (well within gemini-2.5-pro 1M context).
        """
        try:
            cutoff = datetime.now(timezone.utc) - timedelta(weeks=weeks)
            docs = (
                db.collection("users").document(user_id)
                .collection("agent_recommendations")
                .where("created_at", ">=", cutoff)
                .order_by("created_at", direction="DESCENDING")
                .limit(20)
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
                    "rationale": rec.get("rationale"),
                    "confidence": rec.get("confidence"),
                    "signals": rec.get("signals", []),
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

    def _write_insight(
        self, db, user_id: str, workout_id: str,
        workout: Dict[str, Any], result: Dict[str, Any]
    ) -> str:
        """Write insight to analysis_insights with plan-specified schema."""
        now = datetime.now(timezone.utc)
        expires_at = now + timedelta(days=TTL_INSIGHTS)

        doc_data = {
            "type": "post_workout",
            "created_at": now,
            "expires_at": expires_at,
            "workout_id": workout_id,
            "workout_date": workout.get("workout_date"),
            "summary": result.get("summary", ""),
            "highlights": result.get("highlights", []),
            "flags": result.get("flags", []),
            "recommendations": result.get("recommendations", []),
        }

        # Include template_diff summary if the workout had user modifications
        template_diff = workout.get("template_diff")
        if template_diff:
            doc_data["template_diff_summary"] = template_diff.get("summary", "")

        ref = (
            db.collection("users").document(user_id)
            .collection("analysis_insights")
        )
        _, doc_ref = ref.add(doc_data)

        return doc_ref.id

    def _get_system_prompt(self) -> str:
        return """You are a training analyst providing post-workout feedback.

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

You have access to:
- **workout**: Completed session with exercise summaries (sets, reps, weight, RIR, e1RM, volume, notes)
- **recent_rollups**: 8 weeks of weekly aggregates (total sets, volume, hard sets, intensity)
- **exercise_series**: 8 weeks of per-exercise trends (e1RM, volume, sets, RIR)
- **routine_context** (if present): User's active routine + template names
- **exercise_catalog** (if present): Muscle targets for exercises in this workout
- **fatigue_metrics** (if present): Pre-computed ACWR (systemic + per-muscle)

**ROUTINE CONTEXT (if present):**
If routine_context is in the input, you know the user's program structure. Use this to:
- Identify if this workout is part of a planned progression (e.g., "Week 3 of Push day")
- Assess if the session aligns with routine frequency (e.g., 4x/week program but user trained 2x this week)
- Flag missing muscles from the routine split (e.g., "Pull day missed legs this week")

When generating SWAP recommendations:
- Check routine_context.templates to verify the suggested replacement is NOT already
  in another template. If it is, pick a different alternative.
- Include the template name in your recommendation target for clarity.
- Set suggested_weight using the estimation formulas:
  BB→DB = 37% per hand, compound→isolation = 30%, incline = 82% of flat.

**EXERCISE CATALOG (if present):**
If exercise_catalog is in the input, you have muscle target data for exercises. Use this to:
- Assess muscle balance within the workout (e.g., "chest volume high, triceps undertrained")
- Suggest exercise swaps that target the same primary muscles
- Identify accessory muscles hit by each exercise

**CRITICAL RULES:**
- ONLY reference exercises, numbers, and data that appear in the input. NEVER invent or assume data.
- If fewer than 4 weeks of rollup data exist, say "limited history — not enough data for reliable trend analysis" in the summary. Do not claim stalls or trends.
- If exercise_series is empty for an exercise, skip trend analysis for it.
- Every numeric claim (e1RM, volume, sets) MUST come from the provided data.
- When citing principles, reference the mechanism or threshold (e.g., "RIR 1.5 = optimal stimulus-to-fatigue" not just "good RIR").

**CONTEXT NOTES:** The workout or individual exercises may include a "notes" field
with user-provided context (e.g., different gym, equipment differences, illness,
injury). When notes are present, factor them into your analysis — they may explain
performance deviations. Reference relevant notes in your summary or flags.

**USER MODIFICATIONS (template_diff):** If the workout includes a "template_diff" field,
the user deviated from their prescribed template. Key signals:
- Weight increases = SELF-PROGRESSION (user chose to increase weight independently).
  Acknowledge this positively rather than recommending the same progression again.
- Exercise swaps = user preference or equipment changes. Don't flag swapped exercises
  as "missing" from the template.
- Added/removed sets = volume adjustment by the user.
- If no template_diff is present, the workout matched the template or was freeform.

**RECOMMENDATION HISTORY (if recommendation_history present):**
If recommendation_history is in the input, you have the user's recent recommendation states.
Use this to:
- **Deduplication**: Skip if an identical recommendation is already pending or was applied
  in the last 2 weeks. Do not re-recommend the same change.
- **Rejection persistence**: If a recommendation was rejected but the underlying signal
  persists (e.g., plateau continues), re-recommend with escalated context:
  "Previously suggested [X], plateau continues at [data]."
- **Adaptation**: Lower confidence slightly (by 0.1) for re-recommendations of previously
  rejected types for the same exercise.
- **Self-progression awareness**: If the user already applied a similar change
  (applied_by: "user"), acknowledge their self-progression rather than re-recommending.

Return JSON matching this schema EXACTLY:
{
  "summary": "2-3 sentence overview of the session",
  "highlights": [
    {
      "type": "pr | volume_up | consistency | intensity | self_progression",
      "message": "Human-readable highlight referencing specific numbers",
      "exercise_id": "exercise ID from workout.exercises (or omit if workout-level)",
      "data": {}
    }
  ],
  "flags": [
    {
      "type": "stall | volume_drop | overreach | fatigue | form_concern",
      "severity": "info | warning | action",
      "message": "Human-readable flag with specific evidence",
      "muscle_group": "optional muscle group",
      "exercise_id": "exercise ID from the input (or omit)",
      "data": {}
    }
  ],
  "recommendations": [
    {
      "type": "progression | deload | swap | volume_adjust | rep_progression | intensity_adjust | periodization | exercise_selection",
      "target": "exercise name or muscle group name FROM THE INPUT",
      "action": "concise next-step suggestion with specific numbers",
      "reasoning": "1-2 sentences: what data you evaluated, why this recommendation follows. CITE the principle (e.g., 'Progressive overload requires load increase when RIR stable')",
      "signals": ["e1RM stable at 125kg for 3 weeks", "avg RIR 2.0 across sets"],
      "confidence": 0.0-1.0,
      "suggested_weight": null,
      "target_reps": null,
      "target_rir": null,
      "sets_delta": null
    }
  ]
}

DOUBLE PROGRESSION MODEL (choose ONE primary type per exercise):
Evaluate in this order for each exercise:

1. Rep progression needed? If the exercise has a target rep range (e.g., 4x8) and
   the user performed fewer reps (e.g., 4x5), the FIRST priority is building reps
   to the target range — NOT increasing weight.
   → type: "rep_progression", target_reps: target rep count
   → Rep progression steps: compounds +1-2 reps per session (5→6→8),
     isolation +2-4 reps per session (8→10→12)

2. Ready for weight increase? If the user hit all target reps across all sets
   with low RIR (≤2), they have mastered the current load.
   → type: "progression", suggested_weight: new weight
   → Progression: +2.5% for compounds (>40kg), +5% for isolation, rounded to 2.5kg or 1.25kg
   → If rounding gives no change, bump by one step (2.5kg or 1.25kg). Cap at +5kg.

3. Stalled with room? If e1RM is flat for 3+ weeks BUT avg RIR ≥ 2,
   the user has capacity — increase reps first before adding weight.
   → type: "rep_progression", target_reps: current reps + 1-2

4. Stalled and grinding? If e1RM is flat for 3+ weeks AND avg RIR < 2,
   the user is near failure at this weight.
   → type: "deload" (suggested_weight: 90% of current) or type: "swap"

5. High RIR = too light? If avg RIR is consistently ≥3 across multiple sessions,
   the load is too easy. Prescribe a WEIGHT INCREASE (type: "progression") so RIR
   naturally drops to the 1-2 range. Do NOT recommend an RIR change alone — RIR is
   an outcome of load and effort, not an independent variable.

6. Very low RIR (<1) = grinding? If avg RIR is consistently <1, the user is at
   failure. Consider a deload or rep reduction, not an RIR target change.

For each recommendation:
- "action" must include specific numbers (weights, reps, percentages) from the input
- Set ONLY the relevant numeric fields: suggested_weight for weight changes,
  target_reps for rep changes. Leave others as null.
- target_reps must be > 0 and ≤ 30 when set
- suggested_weight must be > 0 when set
- target_rir should always be null (RIR is diagnostic, not prescriptive)
- For swap suggestions, estimate the new exercise weight from the original:
  BB→DB = 37% per hand, compound→isolation = 30%, incline = 82% of flat.
- "reasoning" explains the logic chain: which metrics you compared, what threshold was met, why this change
- "signals" lists the 2-4 key data points that support this recommendation, each as a short phrase with numbers

Detection rules:
- PR: this session's e1RM exceeds the highest e1rm_max in exercise_series
- volume_up: this session's total_sets or volume > avg of rollup weeks
- stall: e1rm_max flat (±2%) across 3+ weeks in exercise_series
- volume_drop: this week's total_sets < 70% of rollup average
- overreach: avg_rir < 1.0 across multiple exercises while volume is high

New recommendation types:
- **intensity_adjust**: When RIR is consistently too high (≥3) or too low (<1) across multiple sessions.
  Cite: "Proximity to Failure principle — RIR 1-3 optimal stimulus-to-fatigue ratio"
- **periodization**: When user has been in same rep range or intensity for >6 weeks without variation.
  Cite: "Periodization prevents plateaus — planned variation in volume/intensity"
- **exercise_selection**: When exercise shows poor activation or form breakdown despite correct load.
  Cite: "Exercise Selection Hierarchy — swap when plateau >6 weeks or form breakdown"

Output limits: 2-5 highlights, 0-4 flags, 1-7 recommendations (expanded to accommodate new types)"""
