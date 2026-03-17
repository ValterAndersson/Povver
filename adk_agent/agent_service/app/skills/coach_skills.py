# app/skills/coach_skills.py
"""Coach skills — read-only data access tools that query Firestore directly.

Migrated from canvas_orchestrator/app/skills/coach_skills.py:
- Replaced CanvasFunctionsClient HTTP calls with FirestoreClient async calls
- Replaced ContextVar user_id with explicit RequestContext parameter
- Returns plain dicts (tool registry handles wrapping)
- All functions are async and accept ctx as keyword-only first arg
"""

from __future__ import annotations

import logging

from app.context import RequestContext
from app.firestore_client import get_firestore_client

logger = logging.getLogger(__name__)


async def get_user_profile(*, ctx: RequestContext) -> dict:
    """Get the user's profile information."""
    fs = get_firestore_client()
    return await fs.get_user(ctx.user_id)


async def search_exercises(*, ctx: RequestContext, query: str, limit: int = 10) -> dict:
    """Search the exercise catalog by name."""
    fs = get_firestore_client()
    results = await fs.search_exercises(query, limit)
    return {"exercises": results, "count": len(results)}


async def get_planning_context(*, ctx: RequestContext) -> dict:
    """Get the full planning context including active routine, templates, recent workouts."""
    fs = get_firestore_client()
    return await fs.get_planning_context(ctx.user_id)


async def get_training_analysis(*, ctx: RequestContext, sections: list[str] | None = None) -> dict:
    """Get pre-computed training analysis (insights and weekly review).

    sections parameter accepted for future filtering but currently returns all data.
    """
    fs = get_firestore_client()
    analysis = await fs.get_analysis_summary(ctx.user_id)
    weekly = await fs.get_weekly_review(ctx.user_id)
    return {"analysis": analysis, "weekly_review": weekly}


async def get_muscle_group_progress(*, ctx: RequestContext, muscle_group: str, weeks: int = 8) -> dict:
    """Get weekly series for a muscle group."""
    fs = get_firestore_client()
    return await fs.get_muscle_group_summary(ctx.user_id, muscle_group, weeks)


async def get_exercise_progress(*, ctx: RequestContext, exercise_id: str, weeks: int = 8) -> dict:
    """Get per-exercise progress with e1RM and volume trends."""
    fs = get_firestore_client()
    return await fs.get_exercise_summary(ctx.user_id, exercise_id)


async def query_training_sets(
    *, ctx: RequestContext, exercise_id: str,
    start: str | None = None, end: str | None = None,
    limit: int = 50,
) -> dict:
    """Query raw set-level training data for an exercise."""
    fs = get_firestore_client()
    filters: dict = {"limit": limit}
    if start:
        filters["date_from"] = start
    if end:
        filters["date_to"] = end
    sets = await fs.query_sets(ctx.user_id, exercise_id, filters)
    return {"sets": sets, "count": len(sets)}
