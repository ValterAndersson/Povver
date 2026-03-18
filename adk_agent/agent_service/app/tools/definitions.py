# app/tools/definitions.py
"""Tool definitions — JSON schemas for each tool.

Each register_*_skills() function is called once at startup to populate the
tool registry with skill functions and their parameter schemas.
"""

from app.tools.registry import register_tool
from app.skills import coach_skills
from app.skills import copilot_skills
from app.skills import planner_skills
from app.skills import progression_skills
from app.skills import workout_skills


def register_coach_skills():
    """Register read-only coach data access tools."""
    register_tool(
        "get_user_profile",
        coach_skills.get_user_profile,
        "Get the user's profile information",
        {"type": "object", "properties": {}, "required": []},
    )
    register_tool(
        "search_exercises",
        coach_skills.search_exercises,
        "Search the exercise catalog by name",
        {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "limit": {"type": "integer", "description": "Max results (default 10)"},
            },
            "required": ["query"],
        },
    )
    register_tool(
        "get_planning_context",
        coach_skills.get_planning_context,
        "Get the full planning context including active routine, templates, recent workouts",
        {"type": "object", "properties": {}, "required": []},
    )
    register_tool(
        "get_training_analysis",
        coach_skills.get_training_analysis,
        "Get pre-computed training analysis (insights and weekly review)",
        {
            "type": "object",
            "properties": {
                "sections": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Sections to include",
                },
            },
            "required": [],
        },
    )
    register_tool(
        "get_exercise_progress",
        coach_skills.get_exercise_progress,
        "Get per-exercise progress with e1RM and volume trends",
        {
            "type": "object",
            "properties": {
                "exercise_id": {"type": "string", "description": "Exercise ID"},
                "weeks": {"type": "integer", "description": "Weeks of history (default 8)"},
            },
            "required": ["exercise_id"],
        },
    )
    register_tool(
        "get_muscle_group_progress",
        coach_skills.get_muscle_group_progress,
        "Get weekly series for a muscle group",
        {
            "type": "object",
            "properties": {
                "muscle_group": {"type": "string", "description": "Muscle group name"},
                "weeks": {"type": "integer", "description": "Weeks of history (default 8)"},
            },
            "required": ["muscle_group"],
        },
    )
    register_tool(
        "query_training_sets",
        coach_skills.query_training_sets,
        "Query raw set-level training data for an exercise",
        {
            "type": "object",
            "properties": {
                "exercise_id": {"type": "string", "description": "Exercise ID"},
                "start": {"type": "string", "description": "Start date YYYY-MM-DD"},
                "end": {"type": "string", "description": "End date YYYY-MM-DD"},
                "limit": {"type": "integer", "description": "Max results (default 50)"},
            },
            "required": ["exercise_id"],
        },
    )


def register_planner_skills():
    """Register write tools that create workout/routine artifacts."""
    register_tool(
        "propose_workout",
        planner_skills.propose_workout,
        "Create a workout template artifact. Returns session_plan for user confirmation.",
        {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Workout name"},
                "exercises": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "Exercises with name, exercise_id, sets, reps, rir, weight_kg",
                },
                "focus": {"type": "string", "description": "Brief goal description"},
                "duration_minutes": {"type": "integer", "description": "Estimated duration (default 45)"},
                "coach_notes": {"type": "string", "description": "Rationale for this plan"},
                "dry_run": {"type": "boolean", "description": "Preview without persisting (default false)"},
            },
            "required": ["title", "exercises"],
        },
    )
    register_tool(
        "propose_routine",
        planner_skills.propose_routine,
        "Create a multi-day routine artifact. Returns routine_summary for user confirmation.",
        {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Routine name"},
                "frequency": {"type": "integer", "description": "Times per week"},
                "workouts": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "List of workouts, each with title and exercises list",
                },
                "description": {"type": "string", "description": "Routine description"},
                "dry_run": {"type": "boolean", "description": "Preview without persisting (default false)"},
            },
            "required": ["name", "frequency", "workouts"],
        },
    )
    register_tool(
        "update_routine",
        planner_skills.update_routine,
        "Update an existing routine via Firebase Function",
        {
            "type": "object",
            "properties": {
                "routine_id": {"type": "string", "description": "Routine ID to update"},
                "routine_name": {"type": "string", "description": "Routine name"},
                "workouts": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "Full workout list with titles and exercises",
                },
            },
            "required": ["routine_id", "routine_name", "workouts"],
        },
    )
    register_tool(
        "update_template",
        planner_skills.update_template,
        "Update exercises in an existing template via Firebase Function",
        {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID to update"},
                "exercises": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "New exercise list with name, exercise_id, sets, reps, rir, weight_kg",
                },
            },
            "required": ["template_id", "exercises"],
        },
    )


# ---------------------------------------------------------------------------
# Copilot skills (Fast Lane — regex-routed, no LLM)
# ---------------------------------------------------------------------------

def register_copilot_skills():
    """Register copilot (fast lane) skills for active workout logging."""
    register_tool(
        "log_set",
        copilot_skills.log_set,
        "Log a completed set with explicit reps, weight, and RIR.",
        {
            "type": "object",
            "properties": {
                "exercise_instance_id": {"type": "string", "description": "Instance ID of the exercise in the active workout"},
                "set_id": {"type": "string", "description": "ID of the set to log"},
                "reps": {"type": "integer", "description": "Number of reps completed"},
                "weight_kg": {"type": "number", "description": "Weight in kg"},
                "rir": {"type": "integer", "description": "Reps in reserve (default 0)", "default": 0},
            },
            "required": ["exercise_instance_id", "set_id", "reps", "weight_kg"],
        },
    )
    register_tool(
        "log_set_shorthand",
        copilot_skills.log_set_shorthand,
        "Complete the current set with shorthand reps and weight. Auto-advances to next set.",
        {
            "type": "object",
            "properties": {
                "reps": {"type": "integer", "description": "Number of reps"},
                "weight_kg": {"type": "number", "description": "Weight in kg"},
            },
            "required": ["reps", "weight_kg"],
        },
    )
    register_tool(
        "get_next_set",
        copilot_skills.get_next_set,
        "Get the next planned set from the active workout.",
        {"type": "object", "properties": {}, "required": []},
    )


# ---------------------------------------------------------------------------
# Workout skills (LLM-directed active workout operations)
# ---------------------------------------------------------------------------

def register_workout_skills():
    """Register workout execution skills for active workout mutations."""
    register_tool(
        "get_workout_state",
        workout_skills.get_workout_state,
        "Fetch the full active workout state including exercises, sets, and totals.",
        {"type": "object", "properties": {}, "required": []},
    )
    register_tool(
        "swap_exercise",
        workout_skills.swap_exercise,
        "Swap an exercise in the active workout for a different one.",
        {
            "type": "object",
            "properties": {
                "exercise_instance_id": {"type": "string", "description": "Instance ID of the exercise to replace"},
                "new_exercise_id": {"type": "string", "description": "Catalog ID of the replacement exercise"},
                "new_exercise_name": {"type": "string", "description": "Display name of the replacement exercise"},
            },
            "required": ["exercise_instance_id", "new_exercise_id", "new_exercise_name"],
        },
    )
    register_tool(
        "add_exercise",
        workout_skills.add_exercise,
        "Add an exercise to the active workout with planned sets.",
        {
            "type": "object",
            "properties": {
                "exercise_id": {"type": "string", "description": "Catalog exercise ID"},
                "name": {"type": "string", "description": "Display name"},
                "sets": {"type": "integer", "description": "Number of working sets", "default": 3},
                "reps": {"type": "integer", "description": "Target reps per set", "default": 10},
                "weight_kg": {"type": "number", "description": "Target weight in kg", "default": 0},
                "rir": {"type": "integer", "description": "Target RIR", "default": 2},
                "warmup_sets": {"type": "integer", "description": "Number of warmup sets", "default": 0},
            },
            "required": ["exercise_id", "name"],
        },
    )
    register_tool(
        "remove_exercise",
        workout_skills.remove_exercise,
        "Remove an exercise entirely from the active workout.",
        {
            "type": "object",
            "properties": {
                "exercise_instance_id": {"type": "string", "description": "Instance ID of the exercise to remove"},
            },
            "required": ["exercise_instance_id"],
        },
    )
    register_tool(
        "prescribe_set",
        workout_skills.prescribe_set,
        "Modify planned values (weight and/or reps) on a specific set.",
        {
            "type": "object",
            "properties": {
                "exercise_instance_id": {"type": "string", "description": "Instance ID of the exercise"},
                "set_id": {"type": "string", "description": "ID of the set to modify"},
                "weight_kg": {"type": "number", "description": "New weight in kg (optional)"},
                "reps": {"type": "integer", "description": "New rep target (optional)"},
            },
            "required": ["exercise_instance_id", "set_id"],
        },
    )
    register_tool(
        "add_set",
        workout_skills.add_set,
        "Add a new planned set to an existing exercise. Use set_type 'warmup', 'working', or 'dropset'.",
        {
            "type": "object",
            "properties": {
                "exercise_instance_id": {"type": "string", "description": "Instance ID of the exercise"},
                "set_type": {"type": "string", "enum": ["warmup", "working", "dropset"], "description": "Type of set", "default": "working"},
                "reps": {"type": "integer", "description": "Target reps", "default": 10},
                "rir": {"type": "integer", "description": "Target RIR (0-5)", "default": 2},
                "weight_kg": {"type": "number", "description": "Target weight in kg (optional)"},
            },
            "required": ["exercise_instance_id"],
        },
    )
    register_tool(
        "remove_set",
        workout_skills.remove_set,
        "Remove a specific set from an exercise. Only planned sets can be removed.",
        {
            "type": "object",
            "properties": {
                "exercise_instance_id": {"type": "string", "description": "Instance ID of the exercise"},
                "set_id": {"type": "string", "description": "ID of the set to remove"},
            },
            "required": ["exercise_instance_id", "set_id"],
        },
    )
    register_tool(
        "complete_workout",
        workout_skills.complete_workout,
        "Complete the active workout - finalize totals and archive.",
        {"type": "object", "properties": {}, "required": []},
    )


# ---------------------------------------------------------------------------
# Progression skills (background progression writes)
# ---------------------------------------------------------------------------

def register_progression_skills():
    """Register progression skills for background training adjustments."""
    register_tool(
        "apply_progression",
        progression_skills.apply_progression,
        "Apply progression changes to a template or routine. All changes are audited.",
        {
            "type": "object",
            "properties": {
                "target_type": {"type": "string", "enum": ["template", "routine"], "description": "Target type"},
                "target_id": {"type": "string", "description": "ID of the template or routine"},
                "changes": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "List of changes with path/from/to/rationale",
                },
                "summary": {"type": "string", "description": "Human-readable summary"},
                "rationale": {"type": "string", "description": "Full explanation"},
                "trigger": {"type": "string", "description": "Trigger source", "default": "user_request"},
                "auto_apply": {"type": "boolean", "description": "Apply immediately or queue for review", "default": True},
            },
            "required": ["target_type", "target_id", "changes", "summary", "rationale"],
        },
    )
    register_tool(
        "suggest_weight_increase",
        progression_skills.suggest_weight_increase,
        "Suggest a weight increase for an exercise in a template.",
        {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID"},
                "exercise_index": {"type": "integer", "description": "Exercise index (0-based)"},
                "new_weight": {"type": "number", "description": "New weight in kg"},
                "rationale": {"type": "string", "description": "Why this increase is recommended"},
            },
            "required": ["template_id", "exercise_index", "new_weight", "rationale"],
        },
    )
    register_tool(
        "suggest_deload",
        progression_skills.suggest_deload,
        "Suggest a deload (60% reduction) for an exercise in a template.",
        {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID"},
                "exercise_index": {"type": "integer", "description": "Exercise index (0-based)"},
                "current_weight": {"type": "number", "description": "Current weight in kg"},
                "rationale": {"type": "string", "description": "Why the deload is recommended"},
            },
            "required": ["template_id", "exercise_index", "current_weight", "rationale"],
        },
    )


def register_memory_tools():
    """Register memory and session variable tools."""
    from app.tools import memory_tools

    register_tool(
        "save_memory",
        memory_tools.save_memory,
        "Save a fact about the user to persistent memory (preferences, injuries, goals)",
        {
            "type": "object",
            "properties": {
                "content": {"type": "string", "description": "The fact to remember"},
                "category": {
                    "type": "string",
                    "enum": ["preference", "injury", "goal", "schedule", "personal", "training_note"],
                    "description": "Memory category",
                },
            },
            "required": ["content", "category"],
        },
    )
    register_tool(
        "retire_memory",
        memory_tools.retire_memory,
        "Retire a memory that is no longer accurate or relevant",
        {
            "type": "object",
            "properties": {
                "memory_id": {"type": "string", "description": "ID of the memory to retire"},
                "reason": {"type": "string", "description": "Why the memory is being retired"},
            },
            "required": ["memory_id", "reason"],
        },
    )
    register_tool(
        "list_memories",
        memory_tools.list_memories,
        "List all active memories for the current user",
        {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max results (default 50)"},
            },
            "required": [],
        },
    )
    register_tool(
        "set_session_var",
        memory_tools.set_session_var,
        "Set a session variable for the current conversation",
        {
            "type": "object",
            "properties": {
                "key": {"type": "string", "description": "Variable name"},
                "value": {"type": "string", "description": "Variable value"},
            },
            "required": ["key", "value"],
        },
    )
    register_tool(
        "delete_session_var",
        memory_tools.delete_session_var,
        "Delete a session variable from the current conversation",
        {
            "type": "object",
            "properties": {
                "key": {"type": "string", "description": "Variable name to delete"},
            },
            "required": ["key"],
        },
    )
    register_tool(
        "search_past_conversations",
        memory_tools.search_past_conversations,
        "Search past conversations by keyword",
        {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search keyword"},
                "limit": {"type": "integer", "description": "Max results (default 5)"},
            },
            "required": ["query"],
        },
    )


def register_all_skills():
    """Register all skill tools. Called once at startup."""
    register_coach_skills()
    register_planner_skills()
    register_copilot_skills()
    register_workout_skills()
    register_progression_skills()
    register_memory_tools()
