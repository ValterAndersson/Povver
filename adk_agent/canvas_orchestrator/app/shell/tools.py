"""
Shell Tools - Tool definitions for ShellAgent using pure skills.

CRITICAL: This module imports ONLY from app/skills/.
NO imports from app/agents/ (coach_agent.py, planner_agent.py).

Tool categories:
- Read tools: From coach_skills.py (analytics, user data)
- Write tools: From planner_skills.py (direct execution, cards have accept/dismiss buttons)

Security:
- Tool signatures do NOT include user_id (prevents LLM hallucination)
- user_id is retrieved from contextvars (set in agent_engine_app.py)
- Thread-safe for concurrent requests in Agent Engine

The tools defined here wrap skill functions with ADK-compatible signatures.
"""

from __future__ import annotations

import functools
import json
import logging
import time
from typing import Any, Dict, List, Optional

from google.adk.tools import FunctionTool

# Import context from contextvars-based context module
from app.shell.context import (
    MAX_SEARCH_CALLS,
    SessionContext,
    get_current_context,
    increment_search_count,
    set_current_context,
)


# Tools banned during active workout mode — returning structured error
# with recovery guidance steers the LLM to the right tool.
WORKOUT_BANNED_TOOLS = {
    "tool_get_training_context": "Use tool_get_exercise_progress for single-exercise history instead.",
    "tool_get_training_analysis": "Use tool_get_exercise_progress for exercise data mid-workout.",
    "tool_query_training_sets": "Use tool_get_exercise_progress for recent set data mid-workout.",
    "tool_propose_routine": "Not available mid-workout. Focus on the current session.",
    "tool_update_routine": "Not available mid-workout. Focus on the current session.",
    "tool_propose_workout": "Not available mid-workout. Focus on the current session.",
    "tool_update_template": "Not available mid-workout. Focus on the current session.",
}


def _check_workout_ban(tool_name: str) -> Optional[Dict[str, str]]:
    """Return error dict if this tool is banned in workout mode, else None."""
    if tool_name not in WORKOUT_BANNED_TOOLS:
        return None
    try:
        ctx = get_current_context()
        if ctx.workout_mode:
            return {
                "error": "TOOL_NOT_AVAILABLE_WORKOUT",
                "message": WORKOUT_BANNED_TOOLS[tool_name],
            }
    except RuntimeError:
        # Not in a request context — not in workout mode
        pass
    return None


def set_tool_context(ctx: SessionContext, message: str) -> None:
    """
    Set the context for tool execution.

    This is called by agent callbacks before tool/model calls.
    Alias for set_current_context for semantic clarity in agent.py.

    Args:
        ctx: SessionContext with user_id, canvas_id, etc.
        message: Raw message (for reference in tools)
    """
    set_current_context(ctx, message)


# =============================================================================
# IMPORTS FROM PURE SKILLS (NO LEGACY AGENTS)
# =============================================================================

# Read skills - no Safety Gate needed
from app.skills.coach_skills import (
    get_training_context,
    get_user_profile,
    search_exercises,
    get_exercise_details,
    # Token-safe v2 analytics (PREFERRED for progress questions)
    get_muscle_group_progress,
    get_muscle_progress,
    get_exercise_progress,
    query_training_sets,
    # Pre-computed analysis (single consolidated call)
    get_training_analysis,
)

# Write skills - direct execution (no Safety Gate - cards have accept/dismiss buttons)
from app.skills.planner_skills import (
    propose_workout as direct_propose_workout,
    propose_routine as direct_propose_routine,
    propose_routine_update as direct_propose_routine_update,
    propose_template_update as direct_propose_template_update,
    get_planning_context as _get_planning_context,
)

# Workout skills - active workout execution (LLM-directed)
from app.skills.workout_skills import (
    log_set as workout_log_set,
    add_exercise as workout_add_exercise,
    prescribe_set as workout_prescribe_set,
    swap_exercise as workout_swap_exercise,
    complete_workout as workout_complete,
    get_workout_state_formatted,
)

logger = logging.getLogger(__name__)


def timed_tool(func):
    """Decorator that logs structured JSON after each tool call with timing."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        start = time.time()
        corr_id = None
        try:
            ctx = get_current_context()
            corr_id = ctx.correlation_id if ctx else None
        except Exception:
            pass
        try:
            result = func(*args, **kwargs)
            latency = int((time.time() - start) * 1000)
            logger.info(json.dumps({
                "event": "tool_called",
                "tool": func.__name__,
                "success": True,
                "latency_ms": latency,
                "correlation_id": corr_id,
                "result_keys": list(result.keys()) if isinstance(result, dict) else None,
            }))
            return result
        except Exception as e:
            logger.info(json.dumps({
                "event": "tool_called",
                "tool": func.__name__,
                "success": False,
                "latency_ms": int((time.time() - start) * 1000),
                "correlation_id": corr_id,
                "error": str(e),
            }))
            raise
    return wrapper


# =============================================================================
# READ TOOLS (Analytics & User Data)
# Note: user_id is NOT exposed to LLM - retrieved from context vars.
# =============================================================================

@timed_tool
def tool_get_training_context() -> Dict[str, Any]:
    """
    Get the user's training context: active routine, templates, schedule.

    Use this to understand the user's current training structure.
    """
    ban = _check_workout_ban("tool_get_training_context")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "No user_id available in context"}

    result = get_training_context(ctx.user_id)
    return result.to_dict()


@timed_tool
def tool_get_user_profile() -> Dict[str, Any]:
    """
    Get user's fitness profile: goals, experience level, equipment.

    Use this for general profile questions.
    NOTE: When building workouts or routines, use tool_get_planning_context instead —
    it includes the profile PLUS active routine, templates, and recent workouts.
    """
    ctx = get_current_context()
    
    if not ctx.user_id:
        return {"error": "No user_id available in context"}
    
    result = get_user_profile(ctx.user_id)
    return result.to_dict()


@timed_tool
def tool_search_exercises(
    *,
    muscle_group: Optional[str] = None,
    movement_type: Optional[str] = None,
    category: Optional[str] = None,
    equipment: Optional[str] = None,
    query: Optional[str] = None,
    limit: int = 15,
    fields: str = "lean",
) -> Dict[str, Any]:
    """
    Search the exercise catalog.
    
    IMPORTANT: Use muscle_group for body-part searches.
    Use movement_type (not split) for push/pull/legs programming.
    
    Args:
        muscle_group: Body part category. Comma-separated OK.
            Values: "chest", "back", "legs", "shoulders", "arms", "core", "glutes",
                    "quadriceps", "hamstrings", "biceps", "triceps", "calves"
            Example: muscle_group="chest" or muscle_group="chest,shoulders,triceps"
        
        movement_type: Movement pattern. USE THIS for PPL splits.
            Values: "push", "pull", "hinge", "squat", "lunge", "carry", "core"
            Example: movement_type="push" gets chest press, shoulder press, tricep extensions
                     movement_type="pull" gets rows, pulldowns, curls
        
        category: Exercise complexity.
            Values: "compound", "isolation", "bodyweight"
        
        equipment: Equipment required. Comma-separated OK.
            Values: "barbell", "dumbbell", "cable", "machine", "bodyweight"
        
        query: Free text search for exercise names.
            Catalog format is "Name (Equipment)" — e.g., "Deadlift (Barbell)",
            "Leg Press (Machine)". Search by BASE NAME: query="deadlift",
            query="bench press", query="leg press".
            Don't prefix equipment in query — use equipment filter instead.
            Good: query="deadlift", equipment="barbell"
            Bad: query="Barbell Deadlift"

        limit: Max results (default 15)

        fields: Output format. Choose based on need:
            "minimal" - id + name only (smallest, for large searches)
            "lean" - id, name, category, equipment (default, good for planning)
            "full" - all fields (when you need muscles, instructions, etc.)

    Returns:
        List of exercises with fields based on 'fields' parameter

    Strategy:
        - PPL: movement_type="push" / "pull" / muscle_group="legs"
        - Upper/Lower: muscle_group="chest,back" / muscle_group="legs"
        - Prefer broad filters over specific names. One search with
          muscle_group="legs" beats 5 separate name queries.
        - If sparse results, drop filters and proceed with best available
        - Use fields="minimal" for large result sets to save context
    """
    call_num = increment_search_count()
    if call_num > MAX_SEARCH_CALLS:
        return {
            "error": (
                f"Search limit reached ({MAX_SEARCH_CALLS} calls). "
                "Use the exercises you already have to build the workout/routine now. "
                "Call tool_propose_workout or tool_propose_routine with your selections."
            ),
        }

    result = search_exercises(
        muscle_group=muscle_group,
        movement_type=movement_type,
        category=category,
        equipment=equipment,
        query=query,
        limit=limit,
        fields=fields,
    )
    return result.to_dict()


@timed_tool
def tool_get_exercise_details(*, exercise_id: str) -> Dict[str, Any]:
    """
    Get detailed information about a specific exercise.
    
    Returns full exercise data including muscles, instructions, tips.
    """
    result = get_exercise_details(exercise_id)
    return result.to_dict()


@timed_tool
def tool_get_planning_context() -> Dict[str, Any]:
    """
    Get complete planning context in one call.
    
    Returns user profile, active routine, templates, recent workouts.
    Use this FIRST when planning a workout or routine.
    
    RETURNS (key fields):
        user: User profile with attributes (goals, experience, equipment)
        
        activeRoutine: The user's active training routine (if any)
            - name, frequency, template_ids, last_completed_template_id
        
        nextWorkout: Deterministic next workout in the routine
            - templateId, templateIndex, template (with full exercises)
        
        templates: Routine templates metadata
            - id, name, description, exerciseCount
        
        recentWorkoutsSummary: Last N completed workouts (default 5, max 20)
            Each workout contains:
            - id: Workout document ID
            - end_time: When workout was completed
            - total_sets: Total working sets performed
            - total_volume: Total weight moved (kg)
            - exercises: Title-level exercise list (NOT full set data)
                Format: [{ name: "Bench Press", sets: 4 }, ...]

            WHAT THIS PROVIDES:
            - Exercise names from recent workouts
            - Working set count per exercise
            - Enough to answer "What exercises did I do last workout?"

            WHAT THIS DOES NOT PROVIDE:
            - Individual set details (reps, weight, RIR)
            - Rep ranges or intensity metrics
            - For set-level drilldown, use tool_query_training_sets instead

        strengthSummary: User's top exercises by e1RM (from recent workouts).
            Each: { id, name, weight, reps, e1rm }. Use for weight estimation
            when prescribing exercises the user hasn't done (see WEIGHT PRESCRIPTION).
    
    WHEN TO USE:
        - "What should I do today?" → check nextWorkout.template
        - "What did I do last workout?" → check recentWorkoutsSummary[0].exercises
        - "What exercises are in my Push day?" → check templates or nextWorkout
        - Planning a new workout → need user context + templates
    
    WHEN NOT TO USE (use these instead):
        - "How many sets of bench did I do?" → tool_query_training_sets (set details)
        - "How is my chest developing?" → tool_get_muscle_group_progress (trends)
        - "What was my heaviest bench set?" → tool_get_exercise_progress (PRs)
    """
    ctx = get_current_context()
    
    if not ctx.user_id:
        return {"error": "No user_id available in context"}
    
    result = _get_planning_context(user_id=ctx.user_id)
    return result.to_dict()


# =============================================================================
# TOKEN-SAFE TRAINING ANALYTICS v2 (PREFERRED)
# These tools use bounded, paginated endpoints that prevent agent timeouts.
# =============================================================================

@timed_tool
def tool_get_muscle_group_progress(
    *,
    muscle_group: str,
    window_weeks: int = 12,
) -> Dict[str, Any]:
    """
    Get comprehensive muscle group progress summary - TOKEN SAFE.
    
    PREFERRED for "How is my chest/back/etc developing?" questions.
    Returns bounded data (<15KB) with weekly series, top exercises,
    and flags (plateau, deload, overreach).
    
    Args:
        muscle_group: Target muscle group. REQUIRED.
            Valid values: chest, back, shoulders, arms, core, legs, glutes
        
        window_weeks: Analysis window in weeks (1-52, default 12)
    
    Returns (metric definitions):
        weeks: Array of weekly data points, each containing:
            week_start: ISO date (YYYY-MM-DD, always Monday)
            
            sets: Total working sets (excludes warmups)
            
            hard_sets: Stimulating sets weighted by proximity to failure.
                Calculated: RIR 0-2 = full credit (1.0), RIR 3-4 = half credit (0.5),
                RIR 5+ or warmups = no credit (0.0).
                Example: 10 sets with avg RIR 2 → ~10 hard_sets
            
            volume: Total weight × reps across all sets.
                Example: 3 sets of 10 reps @ 100kg = 3,000 kg volume
            
            effective_volume: Volume weighted by muscle contribution.
                Example: Bench press (60% chest, 25% shoulders, 15% triceps)
                → If bench volume = 3000, chest effective_volume = 1800
                
            avg_rir: Average RIR across all working sets (null if not tracked)
            
            load_min: Lightest weight used (kg) - useful for warm-up detection
            load_max: Heaviest weight used (kg) - indicator of peak strength
            
            failure_rate: Percentage of sets taken to failure (RIR 0)
                Example: 2 failure sets out of 10 total = 20%
                
            reps_bucket: Distribution of sets by rep range
                Keys: "1-5" (strength), "6-10" (hypertrophy), "11-15", "16-20" (endurance)
        
        top_exercises: Top 5 exercises by effective volume contribution
        
        flags: Diagnostic flags (deterministic rules, not AI):
            plateau: true if e1rm flat (±1%) for 4+ weeks with stable volume
            deload: true if volume dropped >40% week-over-week
            overreach: true if failure_rate >35% for 2+ weeks with rising volume
        
    Example:
        tool_get_muscle_group_progress(muscle_group="chest", window_weeks=12)
        
    Error Recovery:
        If muscle_group is invalid, returns list of valid options.
    """
    ctx = get_current_context()
    
    if not ctx.user_id:
        return {"error": "No user_id available in context"}
    
    result = get_muscle_group_progress(
        user_id=ctx.user_id,
        muscle_group=muscle_group,
        window_weeks=window_weeks,
    )
    return result.to_dict()


@timed_tool
def tool_get_muscle_progress(
    *,
    muscle: str,
    window_weeks: int = 12,
) -> Dict[str, Any]:
    """
    Get individual muscle progress summary - TOKEN SAFE.
    
    Use for specific muscle questions like "How are my rhomboids?" 
    or "How is my front delt developing?"
    
    NOTE: Muscles are MORE GRANULAR than muscle groups. 
    Muscle groups (chest, back, arms) are broad categories.
    Muscles (pectoralis_major, rhomboids, biceps_brachii) are specific anatomical targets.
    
    Args:
        muscle: Target muscle. REQUIRED.
            Valid muscles by group:
              Back: latissimus_dorsi, rhomboids, trapezius, erector_spinae, teres_major, teres_minor
              Chest: pectoralis_major, pectoralis_minor
              Shoulders: deltoid_anterior (front), deltoid_lateral (side), deltoid_posterior (rear), rotator_cuff
              Arms: biceps_brachii, triceps_brachii, brachialis, brachioradialis, forearms
              Core: rectus_abdominis, obliques, transverse_abdominis
              Legs: quadriceps, hamstrings, calves, adductors, abductors, tibialis_anterior
              Glutes: gluteus_maximus, gluteus_medius, gluteus_minimus
        
        window_weeks: Analysis window in weeks (1-52, default 12)
    
    Returns (metric definitions - same as muscle group progress):
        weeks: Array of weekly data with:
            effective_volume: Volume weighted by muscle contribution from exercises.
                Different exercises contribute differently to each muscle.
                Example: Bench press contributes 60% to pectoralis_major, but
                cable fly contributes 85%. Effective volume captures this.
            
            hard_sets: Sets weighted by proximity to failure (RIR 0-2 = 1.0, RIR 3-4 = 0.5)
            
            load_min/load_max: Weight range used (kg)
            
            failure_rate: % of sets at RIR 0
        
        top_exercises: Exercises that most effectively train this muscle
        
        flags: plateau, deload, overreach (same rules as muscle_group)
        
    Example:
        tool_get_muscle_progress(muscle="rhomboids", window_weeks=12)
        tool_get_muscle_progress(muscle="deltoid_anterior", window_weeks=8)
        
    Error Recovery:
        If muscle is invalid, returns list of valid muscles with suggestions.
    """
    ctx = get_current_context()
    
    if not ctx.user_id:
        return {"error": "No user_id available in context"}
    
    result = get_muscle_progress(
        user_id=ctx.user_id,
        muscle=muscle,
        window_weeks=window_weeks,
    )
    return result.to_dict()


@timed_tool
def tool_get_exercise_progress(
    *,
    exercise_id: Optional[str] = None,
    exercise_name: Optional[str] = None,
    window_weeks: int = 12,
) -> Dict[str, Any]:
    """
    Get exercise progress summary with PR tracking - TOKEN SAFE.
    
    Use for "How is my bench press progressing?" questions.
    Returns weekly series, last session recap, PR markers.
    
    ACCEPTS EITHER exercise_id OR exercise_name:
    - exercise_id: Direct lookup by catalog ID
    - exercise_name: Fuzzy name search (e.g., "bench press", "squats", "deadlift")
    
    The fuzzy search matches against exercises in the user's training history.
    For example, "bench" will match "Bench Press", "Dumbbell Bench Press", etc.
    
    Args:
        exercise_id: Exercise ID from catalog (optional if exercise_name provided)
        
        exercise_name: Exercise name for fuzzy search (PREFERRED for user queries)
            Examples: "bench press", "squats", "deadlift", "lat pulldown"
        
        window_weeks: Analysis window in weeks (1-52, default 12)
    
    Returns (metric definitions):
        weeks: Array of weekly data with:
            week_start: ISO date (YYYY-MM-DD, Monday)
            
            sets: Total working sets performed
            
            volume: Total weight × reps (kg)
            
            e1rm_max: Estimated one-rep max for the week.
                ONLY calculated for sets with ≤12 reps (reliable range).
                Formula: Epley (weight × (1 + reps/30))
                Example: 100kg × 8 reps → e1RM ≈ 127kg
                Note: Higher rep sets (>12) don't produce e1RM - unreliable.
            
            load_min: Lightest weight used (kg)
            load_max: Heaviest weight used (kg) - peak strength indicator
            
            avg_rir: Average RIR across working sets (null if not tracked)
        
        last_session: Most recent workout performance
            sets: Array of actual sets with reps, weight_kg, rir
            date: When it was performed
        
        prs: Personal record markers
            all_time_e1rm: Best e1RM ever recorded
            window_e1rm: Best e1RM in the analysis window
        
        flags:
            plateau: true if e1rm_max is within ±1% for 4+ consecutive weeks
        
    Examples:
        # By name (preferred for user queries):
        tool_get_exercise_progress(exercise_name="bench press", window_weeks=12)
        tool_get_exercise_progress(exercise_name="squats")
        
        # By ID (when you have the ID from another query):
        tool_get_exercise_progress(exercise_id="barbell-bench-press", window_weeks=12)
    """
    ctx = get_current_context()
    
    if not ctx.user_id:
        return {"error": "No user_id available in context"}
    
    if not exercise_id and not exercise_name:
        return {"error": "exercise_id or exercise_name is required"}
    
    result = get_exercise_progress(
        user_id=ctx.user_id,
        exercise_id=exercise_id,
        exercise_name=exercise_name,
        window_weeks=window_weeks,
    )
    return result.to_dict()


@timed_tool
def tool_query_training_sets(
    *,
    muscle_group: Optional[str] = None,
    muscle: Optional[str] = None,
    exercise_ids: Optional[List[str]] = None,
    exercise_name: Optional[str] = None,
    start: Optional[str] = None,
    end: Optional[str] = None,
    limit: int = 50,
) -> Dict[str, Any]:
    """
    Query raw set facts for detailed evidence - DRILLDOWN ONLY.

    Use this tool when you need to see ACTUAL SET DATA for evidence-based coaching.
    Prefer summary endpoints (muscle_group_progress, exercise_progress) first.

    EXACTLY ONE filter required: muscle_group, muscle, exercise_ids, or exercise_name.

    Args:
        muscle_group: Filter by muscle group (e.g., "chest")
            Mutually exclusive with muscle and exercise_ids.

        muscle: Filter by specific muscle (e.g., "rhomboids")
            Mutually exclusive with muscle_group and exercise_ids.

        exercise_ids: Filter by exercise IDs (max 10)
            Mutually exclusive with other filters.

        exercise_name: Filter by exercise name (fuzzy search)
            Examples: "bench press", "squats", "lat pulldown"
            Searches user's training history for matching exercise names.
            PREFERRED when you have a name from user input.

        start: Start date YYYY-MM-DD (optional)
        end: End date YYYY-MM-DD (optional)
        limit: Max results (default 50, max 200)

    Returns (each set_fact contains):
        workout_date: When this set was performed (YYYY-MM-DD)

        exercise_id: Catalog ID of the exercise
        exercise_name: Human-readable name

        reps: Number of repetitions performed

        weight_kg: Load used (always in kg, normalized from any input unit)
            Example: 100 lbs input → stored as 45.4 kg

        volume: reps × weight_kg for this set
            Example: 10 reps × 100kg = 1000 kg volume

        rir: Reps in Reserve (how many more reps could have been done)
            0 = failure, 1 = very hard, 2 = hard, 3+ = moderate
            null if not tracked by user

        rpe: Rate of Perceived Exertion (10 - RIR, if tracked)
            10 = failure, 9 = 1 rep left, 8 = 2 reps left

        e1rm: Estimated one-rep max for this set (null if reps > 12)
            Formula: Epley (weight × (1 + reps/30))
            Only calculated for ≤12 reps (reliable strength estimate range)

        is_warmup: true if this was a warm-up set (excluded from analytics)
        is_failure: true if set taken to absolute failure (RIR 0)

        muscle_group_contrib: How this exercise contributes to muscle groups
            Example: {"chest": 0.6, "shoulders": 0.25, "arms": 0.15}

        muscle_contrib: How this exercise contributes to specific muscles
            Example: {"pectoralis_major": 0.6, "deltoid_anterior": 0.25, "triceps_brachii": 0.15}

    Example use cases:
        # See last 20 chest sets for a user asking about chest training
        tool_query_training_sets(muscle_group="chest", limit=20)

        # Check recent bench press performance
        tool_query_training_sets(exercise_ids=["barbell-bench-press"], limit=30)

        # Investigate rhomboid training specifically
        tool_query_training_sets(muscle="rhomboids", limit=15)

    Error Recovery:
        Returns 400 if zero or multiple filters provided.
    """
    ban = _check_workout_ban("tool_query_training_sets")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "No user_id available in context"}

    result = query_training_sets(
        user_id=ctx.user_id,
        muscle_group=muscle_group,
        muscle=muscle,
        exercise_ids=exercise_ids,
        exercise_name=exercise_name,
        start=start,
        end=end,
        limit=limit,
    )
    return result.to_dict()


# =============================================================================
# PRE-COMPUTED ANALYSIS TOOL (consolidated)
# =============================================================================

@timed_tool
def tool_get_training_analysis(
    *,
    sections: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """Get pre-computed AI training analysis — PREFERRED for progress questions.

    Returns up to 2 sections of pre-computed analysis. Default: all sections.
    ~6KB total — well within token budget for a single call.

    Args:
        sections: Optional filter. Valid values:
            "insights", "weekly_review", "recommendation_history"
            Default (None): returns all available sections in a single call.

    Returns:
        insights: [{
            id, type: "post_workout",
            workout_id, workout_date,
            summary (2-3 sentences),
            highlights: [{ type: "pr"|"volume_up"|"consistency"|"intensity", message, exercise_id? }],
            flags: [{ type: "stall"|"volume_drop"|"overreach"|"fatigue", severity: "info"|"warning"|"action", message }],
            recommendations: [{ type: "progression"|"deload"|"swap"|"volume_adjust", target, action, confidence }],
            created_at, expires_at
        }]

        weekly_review: {
            id (YYYY-WNN), week_ending,
            summary (paragraph),
            training_load: { sessions, total_sets, total_volume, vs_last_week: { sets_delta, volume_delta } },
            muscle_balance: [{ muscle_group, weekly_sets, trend, status }],
            exercise_trends: [{ exercise_name, trend: "improving"|"plateaued"|"declining", e1rm_slope, note }],
            progression_candidates: [{ exercise_name, current_weight, suggested_weight, rationale, confidence }],
            stalled_exercises: [{ exercise_name, weeks_stalled, suggested_action, rationale }],
            periodization: {
                current_phase: "hypertrophy | strength | endurance | mixed",
                weeks_in_phase: number,
                suggestion: "phase change recommendation if applicable",
                reasoning: "evidence from data"
            },
            routine_recommendations: [
                {
                    type: "add_exercise | remove_exercise | frequency_change | volume_adjust | restructure",
                    target: "muscle group or template name",
                    suggestion: "specific recommendation",
                    reasoning: "evidence from data"
                }
            ],
            fatigue_status: {
                overall_acwr: number,
                interpretation: "optimal | underloading | overreaching | high_overreach",
                flags: [{ muscle, acwr, concern }],
                recommendation: "text"
            }
        }

        recommendation_history: [{
            id, created_at, state: "pending_review"|"applied"|"rejected"|"failed",
            scope: "template"|"exercise", trigger: "post_workout"|"weekly_review",
            target: { exercise_name, template_name, muscle_group },
            recommendation: { type, summary, rationale, confidence, change_count },
            applied_at, applied_by: "agent"|"user"|null
        }]

    Examples:
        tool_get_training_analysis()  # all sections
        tool_get_training_analysis(sections=["insights"])  # insights only
        tool_get_training_analysis(sections=["weekly_review"])  # weekly review only
        tool_get_training_analysis(sections=["recommendation_history"])  # rec history only
    """
    ban = _check_workout_ban("tool_get_training_analysis")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "No user_id available in context"}

    result = get_training_analysis(
        user_id=ctx.user_id,
        sections=sections,
    )
    return result.to_dict()


# =============================================================================
# WRITE TOOLS (Direct Execution - cards have accept/dismiss buttons)
# Note: user_id and canvas_id are retrieved from context vars.
# =============================================================================

@timed_tool
def tool_propose_workout(
    *,
    title: str,
    exercises: List[Dict[str, Any]],
    focus: Optional[str] = None,
    duration_minutes: int = 45,
    coach_notes: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Create and publish a workout plan to the canvas.
    
    The card has accept/dismiss buttons - no confirmation needed.
    
    Args:
        title: Workout name (e.g., "Push Day", "Leg Hypertrophy")
        exercises: List of exercises, each with:
            - name: Exercise name in catalog format "Name (Equipment)",
              e.g. "Deadlift (Barbell)", "Bench Press (Barbell)",
              "Lateral Raise (Dumbbell)", "Leg Press (Machine)".
              Never use "Equipment Name" format like "Barbell Deadlift".
            - exercise_id: Catalog ID
            - sets: Number of working sets (3-4)
            - reps: Target reps (8-12 for hypertrophy)
            - rir: Target RIR for final set
            - weight_kg: Target weight in kg. REQUIRED for all resistance
              exercises — never omit. Estimate from strengthSummary if
              no direct history.
        focus: Brief goal description
        duration_minutes: Estimated duration
        coach_notes: Rationale for the plan
    """
    ban = _check_workout_ban("tool_propose_workout")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "Missing user_id in context"}

    result = direct_propose_workout(
        user_id=ctx.user_id,
        title=title,
        exercises=exercises,
        focus=focus,
        duration_minutes=duration_minutes,
        coach_notes=coach_notes,
        correlation_id=ctx.correlation_id,
        dry_run=False,  # Always publish - card has accept/dismiss buttons
    )

    return result.to_dict()


@timed_tool
def tool_propose_routine(
    *,
    name: str,
    frequency: int,
    workouts: List[Dict[str, Any]],
    description: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Create a complete routine with multiple workout days.

    The card has save/dismiss buttons - no confirmation needed.

    Args:
        name: Routine name (e.g., "Push Pull Legs", "Upper Lower")
        frequency: Times per week (3, 4, 5, 6)
        workouts: List of workout days, each with:
            - title: Day name (e.g., "Push", "Pull", "Legs")
            - exercises: List of exercises (same format as propose_workout,
              names in catalog format "Name (Equipment)")
        description: Brief routine description
    """
    ban = _check_workout_ban("tool_propose_routine")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "Missing user_id in context"}

    # Validate workouts have exercises before calling skill
    empty_days = [
        w.get("title", f"Day {i+1}")
        for i, w in enumerate(workouts)
        if not w.get("exercises")
    ]
    if empty_days:
        return {
            "error": f"Workouts missing exercises: {', '.join(empty_days)}. "
                     "Each workout must have a non-empty exercises array.",
        }

    result = direct_propose_routine(
        user_id=ctx.user_id,
        name=name,
        frequency=frequency,
        workouts=workouts,
        description=description,
        correlation_id=ctx.correlation_id,
        dry_run=False,  # Always publish - card has save/dismiss buttons
    )

    return result.to_dict()


# =============================================================================
# UPDATE TOOLS (Modify Existing Routines/Templates)
# These tools PROPOSE updates - user confirms via canvas UI.
# =============================================================================

@timed_tool
def tool_update_routine(
    *,
    routine_id: str,
    workouts: List[Dict[str, Any]],
    name: Optional[str] = None,
    description: Optional[str] = None,
    frequency: Optional[int] = None,
    routine_name: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Update an existing routine with modified workouts.
    
    Use this when the user wants to MODIFY their current routine, not create a new one.
    Example triggers:
        - "Improve my current routine"
        - "Change my Push day to include more chest"
        - "Add a fourth day to my PPL"
    
    For CREATING a new routine, use tool_propose_routine instead.
    
    The card shows "Update Routine" button - user confirms the changes.
    UI will indicate "Updating: [routine name]" to make it clear this is a modification.
    
    Args:
        routine_id: ID of the routine to update (from tool_get_planning_context)
        
        workouts: List of workout days with modifications. Each workout:
            - title: Day name (e.g., "Push", "Pull", "Legs")
            - exercises: List of exercises with name, exercise_id, sets, reps, rir, weight_kg
            - source_template_id: (IMPORTANT) Original template ID if updating an existing day.
                                  Include this to ensure the existing template is updated
                                  rather than creating a new one.
        
        name: New routine name (optional - keeps existing if not provided)
        description: New description (optional)
        frequency: New frequency (optional)
        routine_name: Current routine name for UI display (optional but recommended).
                      Used to show "Updating: [routine_name]" in the card header.
                      Get this from activeRoutine.name in tool_get_planning_context result.
    
    Returns:
        Status of the published update proposal
    
    Example flow:
        1. User: "Improve my Push Pull Legs routine"
        2. Agent: tool_get_planning_context() → gets routine_id, template_ids
        3. Agent: Analyzes current templates, plans improvements
        4. Agent: tool_update_routine(
             routine_id="abc123",
             workouts=[
               {
                 "title": "Push",
                 "source_template_id": "template-push-xyz",  # ← Original template
                 "exercises": [improved exercises...]
               },
               ...
             ]
           )
        5. User sees card with "Updating: Push Pull Legs" indicator
        6. User clicks "Update Routine" → existing routine/templates are updated
    """
    ban = _check_workout_ban("tool_update_routine")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "Missing user_id in context"}

    result = direct_propose_routine_update(
        user_id=ctx.user_id,
        routine_id=routine_id,
        workouts=workouts,
        name=name,
        description=description,
        frequency=frequency,
        routine_name=routine_name,
        correlation_id=ctx.correlation_id,
        dry_run=False,
    )

    return result.to_dict()


@timed_tool
def tool_update_template(
    *,
    template_id: str,
    exercises: List[Dict[str, Any]],
    name: Optional[str] = None,
    coach_notes: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Update a single workout template with modified exercises.

    Use this when:
    - Modifying a standalone template (not part of a routine)
    - Making targeted changes to ONE day of a routine
    - Quick adjustments without rebuilding the entire routine

    Example triggers:
        - "Change my Push day to add more chest work"
        - "Update my leg template with more quad exercises"
        - "Improve just the Pull workout"

    For routine-wide changes, use tool_update_routine instead.

    The card shows "Update Template" button - user confirms the changes.
    UI will indicate this is an update, not a new template.

    Args:
        template_id: ID of the template to update (from tool_get_planning_context)

        exercises: List of exercises with modifications. Each exercise:
            - name: Exercise name in catalog format "Name (Equipment)"
            - exercise_id: Catalog ID
            - sets: Number of working sets (3-4)
            - reps: Target reps (8-12 for hypertrophy)
            - rir: Target RIR for final set
            - weight_kg: Target weight in kg. REQUIRED for all
              resistance exercises — never omit. Estimate from
              strengthSummary if no direct history.

        name: New template name (optional - keeps existing if not provided)
        coach_notes: Rationale for the changes

    Returns:
        Status of the published update proposal
    """
    ban = _check_workout_ban("tool_update_template")
    if ban:
        return ban

    ctx = get_current_context()

    if not ctx.user_id:
        return {"error": "Missing user_id in context"}

    result = direct_propose_template_update(
        user_id=ctx.user_id,
        template_id=template_id,
        exercises=exercises,
        name=name,
        coach_notes=coach_notes,
        correlation_id=ctx.correlation_id,
        dry_run=False,
    )

    return result.to_dict()


# =============================================================================
# WORKOUT TOOLS (Active Workout Mode)
# These tools are only available when workout_mode=True in context.
# =============================================================================

@timed_tool
def tool_log_set(
    *,
    exercise_instance_id: str,
    set_id: str,
    reps: int,
    weight_kg: float,
    rir: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Log a completed set in the active workout.

    Use this when the user reports completing a set (e.g., "8 at 100kg").
    Extract the set_id from the Workout Brief (next planned set marked with →).

    Args:
        exercise_instance_id: Exercise instance ID from the brief (e.g., "ex-abc123")
        set_id: Set ID from the brief (e.g., "set-003")
        reps: Number of reps performed
        weight_kg: Weight used in kg
        rir: Reps in reserve (optional, 0-4)

    Returns:
        Success message or error
    """
    ctx = get_current_context()

    if not ctx.workout_mode:
        return {"error": "Not in active workout mode"}

    result = workout_log_set(
        user_id=ctx.user_id,
        workout_id=ctx.active_workout_id,
        exercise_instance_id=exercise_instance_id,
        set_id=set_id,
        reps=reps,
        weight_kg=weight_kg,
        rir=rir,
    )
    return result.to_dict()


def _calculate_warmup_ramp(
    working_weight_kg: float,
    count: int = 3,
    progression: str = "standard",
) -> list:
    """Calculate warmup set ramp based on working weight.

    Args:
        working_weight_kg: Target working set weight in kg.
        count: Number of warmup sets (0-4).
        progression: "standard" (50/65/80%), "conservative" (60/80%),
                     or "aggressive" (40/55/70/85%).

    Returns:
        List of warmup set dicts with id, weight, reps, rir, set_type.
        Empty list if working_weight_kg < 30 or count <= 0.
    """
    import uuid

    if count <= 0 or working_weight_kg < 30:
        return []

    ramps = {
        "standard": [0.50, 0.65, 0.80],
        "conservative": [0.60, 0.80],
        "aggressive": [0.40, 0.55, 0.70, 0.85],
    }

    percentages = ramps.get(progression, ramps["standard"])
    if count < len(percentages):
        step = len(percentages) / count
        percentages = [percentages[int(i * step)] for i in range(count)]
    elif count > len(percentages):
        percentages = percentages[:count]

    rep_scheme = [10, 8, 5, 3]

    def _round_2_5(w):
        return round(w / 2.5) * 2.5

    sets = []
    for i, pct in enumerate(percentages):
        reps = rep_scheme[i] if i < len(rep_scheme) else 3
        sets.append({
            "id": f"set-{uuid.uuid4().hex[:8]}",
            "weight": _round_2_5(working_weight_kg * pct),
            "reps": reps,
            "rir": 5,
            "set_type": "warmup",
        })

    return sets


@timed_tool
def tool_add_exercise(
    *,
    exercise_id: str,
    name: str,
    sets: int = 3,
    reps: int = 10,
    weight_kg: Optional[float] = None,
    rir: Optional[int] = 2,
    warmup_sets: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Add a new exercise to the active workout with planned sets.

    Use when the user wants to add an exercise mid-workout.
    The exercise must exist in the catalog — use tool_search_exercises first
    to find the exercise_id and name.

    Args:
        exercise_id: Catalog exercise ID (from tool_search_exercises)
        name: Exercise name in catalog format "Name (Equipment)"
        sets: Number of working sets (default 3)
        reps: Target reps per working set (default 10)
        weight_kg: Target weight in kg (optional — omit if unknown)
        rir: Target RIR for each working set (default 2)
        warmup_sets: Number of warm-up sets before working sets (default None).
            Uses standard ramp: 50/65/80% of weight_kg with decreasing reps.
            Only useful for compounds with weight_kg >= 30.

    Returns:
        Success with the new exercise instance_id, or error
    """
    ctx = get_current_context()

    if not ctx.workout_mode:
        return {"error": "Not in active workout mode"}

    import uuid

    all_sets = []
    if warmup_sets and warmup_sets > 0 and weight_kg:
        all_sets.extend(_calculate_warmup_ramp(weight_kg, count=warmup_sets))

    working = [
        {
            "id": f"set-{uuid.uuid4().hex[:8]}",
            "reps": reps,
            "weight": weight_kg,
            "rir": rir,
        }
        for _ in range(sets)
    ]
    all_sets.extend(working)

    result = workout_add_exercise(
        user_id=ctx.user_id,
        workout_id=ctx.active_workout_id,
        exercise_id=exercise_id,
        name=name,
        sets=all_sets,
    )
    return result.to_dict()


@timed_tool
def tool_prescribe_set(
    *,
    exercise_instance_id: str,
    set_id: str,
    weight_kg: Optional[float] = None,
    reps: Optional[int] = None,
    rir: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Update planned values (weight, reps, rir) on a planned set.

    Use when the user asks to change the prescribed weight, reps, or RIR
    for an exercise's planned sets. Only works on planned (not done) sets.

    Call this once per set that needs changing. Get set IDs from the Workout Brief.

    Args:
        exercise_instance_id: Exercise instance ID from the brief (e.g., "ex-abc123")
        set_id: Set ID from the brief (e.g., "set-003")
        weight_kg: New target weight in kg (optional)
        reps: New target reps (optional)
        rir: New target RIR (optional)

    Returns:
        Success message or error
    """
    ctx = get_current_context()

    if not ctx.workout_mode:
        return {"error": "Not in active workout mode"}

    result = workout_prescribe_set(
        user_id=ctx.user_id,
        workout_id=ctx.active_workout_id,
        exercise_instance_id=exercise_instance_id,
        set_id=set_id,
        weight_kg=weight_kg,
        reps=reps,
        rir=rir,
    )
    return result.to_dict()


@timed_tool
def tool_swap_exercise(
    *,
    exercise_instance_id: str,
    new_exercise_query: str,
) -> Dict[str, Any]:
    """
    Swap an exercise in the active workout.

    Use this when the user wants to replace an exercise (e.g., "swap to dumbbells").
    First search for the new exercise using tool_search_exercises, then swap.

    Args:
        exercise_instance_id: Exercise instance ID to swap (from brief)
        new_exercise_query: Query to find replacement exercise

    Returns:
        Success message or error
    """
    ctx = get_current_context()

    if not ctx.workout_mode:
        return {"error": "Not in active workout mode"}

    # Search for the new exercise
    search_result = search_exercises(query=new_exercise_query, limit=1)
    if not search_result.success:
        return {"error": f"No exercise found for '{new_exercise_query}'"}

    # search_exercises returns SkillResult(data={"items": [...], "count": n})
    items = search_result.data.get("items", [])
    if not items:
        return {"error": f"No exercise found for '{new_exercise_query}'"}

    new_exercise_id = items[0].get("id")
    if not new_exercise_id:
        return {"error": "Failed to get exercise ID from search result"}

    result = workout_swap_exercise(
        user_id=ctx.user_id,
        workout_id=ctx.active_workout_id,
        exercise_instance_id=exercise_instance_id,
        new_exercise_id=new_exercise_id,
    )
    return result.to_dict()


@timed_tool
def tool_complete_workout() -> Dict[str, Any]:
    """
    Complete the active workout and archive it.

    Use this when the user says they're done (e.g., "I'm done", "finish workout").

    Returns:
        Summary of completed workout or error
    """
    ctx = get_current_context()

    if not ctx.workout_mode:
        return {"error": "Not in active workout mode"}

    result = workout_complete(
        user_id=ctx.user_id,
        workout_id=ctx.active_workout_id,
    )
    return result.to_dict()


@timed_tool
def tool_get_workout_state() -> Dict[str, Any]:
    """
    Get current workout state (refresh the brief).

    Rarely needed since the brief is auto-injected at the start of each message.
    Use only if you need to refresh mid-conversation.

    Returns:
        Formatted workout state
    """
    ctx = get_current_context()

    if not ctx.workout_mode:
        return {"error": "Not in active workout mode"}

    brief = get_workout_state_formatted(
        user_id=ctx.user_id,
        workout_id=ctx.active_workout_id,
    )
    return {"success": True, "brief": brief}


# =============================================================================
# TOOL REGISTRY
# =============================================================================

# All tools available to ShellAgent
all_tools = [
    # Read tools (user context)
    FunctionTool(func=tool_get_training_context),
    FunctionTool(func=tool_get_user_profile),
    FunctionTool(func=tool_search_exercises),
    FunctionTool(func=tool_get_exercise_details),
    FunctionTool(func=tool_get_planning_context),

    # Token-safe Training Analytics v2 (PREFERRED for progress questions)
    FunctionTool(func=tool_get_muscle_group_progress),
    FunctionTool(func=tool_get_muscle_progress),
    FunctionTool(func=tool_get_exercise_progress),
    FunctionTool(func=tool_query_training_sets),

    # Pre-computed analysis (single consolidated call)
    FunctionTool(func=tool_get_training_analysis),

    # Write tools - Create new (cards have accept/dismiss buttons)
    FunctionTool(func=tool_propose_workout),
    FunctionTool(func=tool_propose_routine),

    # Write tools - Update existing (cards have update/dismiss buttons)
    FunctionTool(func=tool_update_routine),
    FunctionTool(func=tool_update_template),

    # Workout tools - Active workout execution (workout_mode only)
    FunctionTool(func=tool_log_set),
    FunctionTool(func=tool_add_exercise),
    FunctionTool(func=tool_prescribe_set),
    FunctionTool(func=tool_swap_exercise),
    FunctionTool(func=tool_complete_workout),
    FunctionTool(func=tool_get_workout_state),
]


__all__ = [
    # Tool registry for ShellAgent
    "all_tools",
    # Context setter for agent callbacks
    "set_tool_context",
    # Read tools
    "tool_get_training_context",
    "tool_get_user_profile",
    "tool_search_exercises",
    "tool_get_exercise_details",
    "tool_get_planning_context",
    # Token-safe v2 analytics (PREFERRED)
    "tool_get_muscle_group_progress",
    "tool_get_muscle_progress",
    "tool_get_exercise_progress",
    "tool_query_training_sets",
    # Pre-computed analysis (single consolidated call)
    "tool_get_training_analysis",
    # Write tools - Create
    "tool_propose_workout",
    "tool_propose_routine",
    # Write tools - Update
    "tool_update_routine",
    "tool_update_template",
    # Workout tools - Active workout execution
    "tool_log_set",
    "tool_add_exercise",
    "tool_prescribe_set",
    "tool_swap_exercise",
    "tool_complete_workout",
    "tool_get_workout_state",
]
