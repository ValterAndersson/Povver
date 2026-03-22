# tool_definitions.py
"""
17 MCP tools as Anthropic API tool definitions (JSON Schema).
Source of truth: mcp_server/src/tools.ts
"""

MCP_TOOLS: list[dict] = [
    {
        "name": "get_training_snapshot",
        "description": "Get compact overview: user profile, active routine, next workout, recent workouts (summary), strength records",
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "list_routines",
        "description": "List all routines",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_routine",
        "description": "Get a specific routine with template names and exercise summaries",
        "input_schema": {
            "type": "object",
            "properties": {
                "routine_id": {"type": "string", "description": "Routine ID"},
                "include_templates": {"type": "boolean", "description": "Include template exercise summaries", "default": True},
            },
            "required": ["routine_id"],
        },
    },
    {
        "name": "list_templates",
        "description": "List all workout templates (names + IDs, no exercises). Use get_template for full exercise list.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_template",
        "description": "Get a specific template with full exercise list",
        "input_schema": {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID"},
            },
            "required": ["template_id"],
        },
    },
    {
        "name": "list_workouts",
        "description": "List recent workouts (summaries: date, exercises, set counts). Use get_workout for full set data.",
        "input_schema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max results (default 10)", "default": 10},
            },
            "required": [],
        },
    },
    {
        "name": "get_workout",
        "description": "Get a specific workout with full exercise and set data",
        "input_schema": {
            "type": "object",
            "properties": {
                "workout_id": {"type": "string", "description": "Workout ID"},
            },
            "required": ["workout_id"],
        },
    },
    {
        "name": "search_exercises",
        "description": "Search exercise catalog",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "limit": {"type": "integer", "description": "Max results", "default": 10},
            },
            "required": ["query"],
        },
    },
    {
        "name": "get_training_analysis",
        "description": "Get training analysis insights",
        "input_schema": {
            "type": "object",
            "properties": {
                "sections": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Sections: insights, weekly_review, recommendation_history",
                },
                "include_expired": {"type": "boolean", "description": "Include expired/applied recommendations", "default": False},
            },
            "required": [],
        },
    },
    {
        "name": "get_muscle_group_progress",
        "description": "Get muscle group progress over time",
        "input_schema": {
            "type": "object",
            "properties": {
                "group": {"type": "string", "description": "Muscle group name"},
                "weeks": {"type": "integer", "description": "Number of weeks", "default": 8},
            },
            "required": ["group"],
        },
    },
    {
        "name": "get_exercise_progress",
        "description": "Get exercise progress over time",
        "input_schema": {
            "type": "object",
            "properties": {
                "exercise": {"type": "string", "description": "Exercise name"},
                "weeks": {"type": "integer", "description": "Number of weeks", "default": 8},
            },
            "required": ["exercise"],
        },
    },
    {
        "name": "query_sets",
        "description": "Query raw set-level training data",
        "input_schema": {
            "type": "object",
            "properties": {
                "exercise_name": {"type": "string", "description": "Exercise name (fuzzy match)"},
                "muscle_group": {"type": "string", "description": "Muscle group (e.g., chest, back, shoulders)"},
                "muscle": {"type": "string", "description": "Specific muscle (e.g., posterior deltoid)"},
                "exercise_ids": {"type": "array", "items": {"type": "string"}, "description": "Exercise IDs (max 10)"},
                "limit": {"type": "integer", "description": "Max results", "default": 50},
            },
            "required": [],
        },
    },
    {
        "name": "create_routine",
        "description": "Create a new routine",
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Routine name"},
                "template_ids": {"type": "array", "items": {"type": "string"}, "description": "Template IDs"},
                "frequency": {"type": "integer", "description": "Days per week"},
            },
            "required": ["name", "template_ids"],
        },
    },
    {
        "name": "update_routine",
        "description": "Update an existing routine",
        "input_schema": {
            "type": "object",
            "properties": {
                "routine_id": {"type": "string", "description": "Routine ID"},
                "updates": {"type": "object", "description": "Fields to update"},
            },
            "required": ["routine_id", "updates"],
        },
    },
    {
        "name": "create_template",
        "description": "Create a new workout template",
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Template name"},
                "exercises": {
                    "type": "array",
                    "description": "Exercises with set prescriptions",
                    "items": {
                        "type": "object",
                        "properties": {
                            "exercise_id": {"type": "string", "description": "Exercise ID from search_exercises"},
                            "name": {"type": "string", "description": "Exercise name"},
                            "position": {"type": "integer", "description": "Order in template (0-based)"},
                            "sets": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "type": {"type": "string", "description": "Set type", "default": "Working Set"},
                                        "reps": {"type": "integer", "description": "Target reps"},
                                        "weight": {"type": ["number", "null"], "description": "Target weight (kg) or null for bodyweight"},
                                        "rir": {"type": "integer", "description": "Reps in reserve (0-5)"},
                                    },
                                    "required": ["reps", "weight", "rir"],
                                },
                            },
                        },
                        "required": ["exercise_id", "position", "sets"],
                    },
                },
            },
            "required": ["name", "exercises"],
        },
    },
    {
        "name": "update_template",
        "description": "Update an existing template",
        "input_schema": {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID"},
                "updates": {
                    "type": "object",
                    "description": "Fields to update",
                    "properties": {
                        "name": {"type": "string"},
                        "description": {"type": "string"},
                        "exercises": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "exercise_id": {"type": "string"},
                                    "name": {"type": "string"},
                                    "position": {"type": "integer"},
                                    "sets": {
                                        "type": "array",
                                        "items": {
                                            "type": "object",
                                            "properties": {
                                                "type": {"type": "string", "default": "Working Set"},
                                                "reps": {"type": "integer"},
                                                "weight": {"type": ["number", "null"]},
                                                "rir": {"type": "integer"},
                                            },
                                            "required": ["reps", "weight", "rir"],
                                        },
                                    },
                                },
                                "required": ["exercise_id", "position", "sets"],
                            },
                        },
                    },
                },
            },
            "required": ["template_id", "updates"],
        },
    },
    {
        "name": "list_memories",
        "description": "List agent memories about the user",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
]
