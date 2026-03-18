# app/firestore_client.py
"""Async Firestore client for the agent service.

Uses AsyncClient to avoid blocking the async agent loop.
Mirrors the query patterns from the Node.js shared modules —
the Firestore schema is the shared contract.
"""

from __future__ import annotations

import logging
import os
from typing import Any

from google.cloud.firestore import AsyncClient

logger = logging.getLogger(__name__)


_instance: 'FirestoreClient | None' = None


def get_firestore_client() -> 'FirestoreClient':
    """Module-level singleton — reuses gRPC channel across requests."""
    global _instance
    if _instance is None:
        _instance = FirestoreClient()
    return _instance


class FirestoreClient:
    CONVERSATION_COLLECTION = os.getenv("CONVERSATION_COLLECTION", "conversations")

    def __init__(self):
        self.db = AsyncClient()

    # --- Routines ---

    async def get_routine(self, user_id: str, routine_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}/routines/{routine_id}").get()
        if not doc.exists:
            raise ValueError(f"Routine {routine_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    async def list_routines(self, user_id: str) -> list[dict]:
        docs = self.db.collection(f"users/{user_id}/routines").stream()
        return [{"id": doc.id, **doc.to_dict()} async for doc in docs]

    # --- Templates ---

    async def get_template(self, user_id: str, template_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}/templates/{template_id}").get()
        if not doc.exists:
            raise ValueError(f"Template {template_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    async def list_templates(self, user_id: str, include_exercises: bool = False) -> list[dict]:
        docs = self.db.collection(f"users/{user_id}/templates").stream()
        results = []
        async for doc in docs:
            data = doc.to_dict()
            if include_exercises:
                results.append({"id": doc.id, **data})
            else:
                results.append({
                    "id": doc.id,
                    "name": data.get("name"),
                    "description": data.get("description"),
                    "exercise_count": len(data.get("exercises", [])),
                    "exercise_names": [e.get("name") for e in data.get("exercises", [])],
                    "created_at": data.get("created_at"),
                    "updated_at": data.get("updated_at"),
                })
        return results

    # --- User ---

    async def get_user(self, user_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}").get()
        if not doc.exists:
            raise ValueError(f"User {user_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    # --- User Attributes ---

    async def get_user_attributes(self, user_id: str) -> dict:
        """Read user_attributes/{uid} subcollection doc (fitness_level, fitness_goal, etc.)."""
        doc = await self.db.document(f"users/{user_id}/user_attributes/{user_id}").get()
        return doc.to_dict() if doc.exists else {}

    # --- Workouts ---

    async def list_recent_workouts(self, user_id: str, limit: int = 5) -> list[dict]:
        query = (
            self.db.collection(f"users/{user_id}/workouts")
            .order_by("end_time", direction="DESCENDING")
            .limit(limit)
        )
        results = []
        async for doc in query.stream():
            data = doc.to_dict()
            exercises = data.get("exercises", [])
            results.append({
                "id": doc.id,
                "name": data.get("name"),
                "source_template_id": data.get("source_template_id"),
                "start_time": data.get("start_time"),
                "end_time": data.get("end_time"),
                "exercises": [{
                    "name": ex.get("name"),
                    "exercise_id": ex.get("exercise_id"),
                    "sets": len(ex.get("sets", [])),
                } for ex in exercises],
                "analytics": {
                    "total_sets": (data.get("analytics") or {}).get("total_sets"),
                    "total_reps": (data.get("analytics") or {}).get("total_reps"),
                    "total_volume": (data.get("analytics") or {}).get("total_weight"),
                } if data.get("analytics") else None,
            })
        return results

    # --- Training Data ---

    async def get_analysis_summary(self, user_id: str) -> dict | None:
        """Get most recent analysis insight."""
        query = (
            self.db.collection(f"users/{user_id}/analysis_insights")
            .order_by("created_at", direction="DESCENDING")
            .limit(1)
        )
        docs = [doc async for doc in query.stream()]
        if not docs:
            return None
        return {"id": docs[0].id, **docs[0].to_dict()}

    async def get_weekly_review(self, user_id: str) -> dict | None:
        """Get most recent weekly review."""
        query = (
            self.db.collection(f"users/{user_id}/weekly_reviews")
            .order_by("created_at", direction="DESCENDING")
            .limit(1)
        )
        docs = [doc async for doc in query.stream()]
        if not docs:
            return None
        return {"id": docs[0].id, **docs[0].to_dict()}

    async def get_weekly_stats(self, user_id: str, week_start: str | None = None) -> dict | None:
        """Get weekly stats. week_start is YYYY-MM-DD (Monday). Defaults to current week."""
        if not week_start:
            from datetime import date, timedelta
            today = date.today()
            monday = today - timedelta(days=today.weekday())
            week_start = monday.isoformat()
        doc = await self.db.document(f"users/{user_id}/weekly_stats/{week_start}").get()
        if not doc.exists:
            return None
        return doc.to_dict()

    # --- Planning Context (360 view assembly) ---

    async def get_planning_context(self, user_id: str) -> dict:
        """Assemble the full planning context for the agent.

        Mirrors get-planning-context.js: reads user doc, user_attributes,
        active routine + templates, recent workouts, analysis.
        """
        import asyncio

        user_task = self.get_user(user_id)
        attrs_task = self.get_user_attributes(user_id)
        routines_task = self.list_routines(user_id)
        templates_task = self.list_templates(user_id)
        workouts_task = self.list_recent_workouts(user_id, limit=5)
        analysis_task = self.get_analysis_summary(user_id)
        weekly_task = self.get_weekly_stats(user_id)

        user, attrs, routines, templates, workouts, analysis, weekly = await asyncio.gather(
            user_task, attrs_task, routines_task, templates_task,
            workouts_task, analysis_task, weekly_task,
        )

        # Determine active routine
        active_routine_id = user.get("activeRoutineId")
        active_routine = next((r for r in routines if r["id"] == active_routine_id), None)

        # Weight unit from user_attributes (mirrors get-planning-context.js)
        weight_format = attrs.get("weight_format", "kilograms")
        weight_unit = "lbs" if weight_format == "pounds" else "kg"

        return {
            "user": {
                "name": user.get("name"),
                "attributes": attrs,
                "weight_unit": weight_unit,
            },
            "active_routine": active_routine,
            "templates": templates,
            "recent_workouts": workouts,
            "analysis": analysis,
            "weekly_stats": weekly,
        }

    # --- Training Analytics v2 ---

    async def get_muscle_group_summary(self, user_id: str, muscle_group: str, weeks: int = 8) -> dict:
        """Weekly series for a muscle group (from analytics_series_muscle_group)."""
        doc = await self.db.document(
            f"users/{user_id}/analytics_series_muscle_group/{muscle_group}"
        ).get()
        if not doc.exists:
            return {"muscle_group": muscle_group, "weeks": []}
        return {"id": doc.id, **doc.to_dict()}

    async def get_muscle_summary(self, user_id: str, muscle: str, weeks: int = 8) -> dict:
        """Weekly series for a specific muscle (from analytics_series_muscle)."""
        doc = await self.db.document(
            f"users/{user_id}/analytics_series_muscle/{muscle}"
        ).get()
        if not doc.exists:
            return {"muscle": muscle, "weeks": []}
        return {"id": doc.id, **doc.to_dict()}

    async def get_exercise_summary(self, user_id: str, exercise_id: str) -> dict:
        """Per-exercise series with e1RM and volume trends.
        Keyed by exercise_id (not name) in analytics_series_exercise collection.
        """
        doc = await self.db.document(
            f"users/{user_id}/analytics_series_exercise/{exercise_id}"
        ).get()
        if not doc.exists:
            return {"exercise_id": exercise_id, "points_by_day": {}}
        return {"id": doc.id, **doc.to_dict()}

    async def query_sets(self, user_id: str, exercise_id: str, filters: dict | None = None) -> list[dict]:
        """Raw set-level drilldown from set_facts collection.
        Queries by exercise_id (matching existing composite index).
        """
        query = self.db.collection(f"users/{user_id}/set_facts")
        if exercise_id:
            query = query.where("exercise_id", "==", exercise_id)
        if filters:
            if filters.get("date_from"):
                query = query.where("workout_date", ">=", filters["date_from"])
            if filters.get("date_to"):
                query = query.where("workout_date", "<=", filters["date_to"])
        query = query.order_by("workout_date", direction="DESCENDING").limit(filters.get("limit", 50) if filters else 50)
        return [{"id": doc.id, **doc.to_dict()} async for doc in query.stream()]

    async def get_active_snapshot_lite(self, user_id: str) -> dict:
        """Lightweight context: active routine, this week summary."""
        import asyncio
        user_doc, weekly = await asyncio.gather(
            self.db.document(f"users/{user_id}").get(),
            self.get_weekly_stats(user_id),
        )
        user = user_doc.to_dict() if user_doc.exists else {}
        return {
            "active_routine_id": user.get("activeRoutineId"),
            "weekly_stats": weekly,
        }

    async def get_active_events(self, user_id: str, limit: int = 10) -> list[dict]:
        """Recent training events from agent_recommendations."""
        query = (
            self.db.collection(f"users/{user_id}/agent_recommendations")
            .order_by("created_at", direction="DESCENDING")
            .limit(limit)
        )
        return [{"id": doc.id, **doc.to_dict()} async for doc in query.stream()]

    # --- Exercises ---

    async def search_exercises(self, query: str, limit: int = 10) -> list[dict]:
        """Search exercises via the existing searchExercises Firebase Function.

        Uses HTTP call instead of direct Firestore query because Firestore's
        inequality filter requires orderBy on the inequality field first,
        making client-side name filtering unreliable.
        """
        import httpx
        url = os.getenv("MYON_FUNCTIONS_BASE_URL",
                        "https://us-central1-myon-53d85.cloudfunctions.net")
        api_key = os.getenv("MYON_API_KEY", "")
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                f"{url}/searchExercises",
                params={"query": query, "limit": str(limit)},
                headers={"x-api-key": api_key},
            )
            data = resp.json()
            return data.get("exercises", [])

    # --- Conversations ---

    async def get_conversation_messages(
        self, user_id: str, conversation_id: str, limit: int = 20
    ) -> list[dict]:
        """Load recent messages for a conversation."""
        coll = self.CONVERSATION_COLLECTION
        query = (
            self.db.collection(f"users/{user_id}/{coll}/{conversation_id}/messages")
            .order_by("created_at", direction="DESCENDING")
            .limit(limit)
        )
        docs = [doc async for doc in query.stream()]
        docs.reverse()  # Chronological order
        return [{"id": doc.id, **doc.to_dict()} for doc in docs]

    async def save_message(
        self, user_id: str, conversation_id: str, message: dict
    ) -> str:
        """Save a message to a conversation.
        Message format: {type: 'user_prompt'|'agent_response'|'artifact',
                         content: str, created_at: datetime}
        """
        coll = self.CONVERSATION_COLLECTION
        ref = await self.db.collection(
            f"users/{user_id}/{coll}/{conversation_id}/messages"
        ).add(message)
        return ref[1].id

    async def save_artifact(
        self, user_id: str, conversation_id: str, artifact_id: str, artifact: dict
    ) -> None:
        """Persist an artifact to the conversation's artifacts subcollection."""
        coll = self.CONVERSATION_COLLECTION
        from datetime import datetime, timezone
        await self.db.document(
            f"users/{user_id}/{coll}/{conversation_id}/artifacts/{artifact_id}"
        ).set({
            "type": artifact.get("artifact_type"),
            "content": artifact.get("content", {}),
            "actions": artifact.get("actions", []),
            "status": artifact.get("status", "proposed"),
            "created_at": datetime.now(timezone.utc),
        })
