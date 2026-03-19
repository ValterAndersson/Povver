# app/firestore_client.py
"""Async Firestore client for the agent service.

Read methods that benefit from server-side projections (list, query, analytics)
are delegated to Firebase Functions via the shared FunctionsClient.
Simple single-doc reads and conversation operations remain on direct Firestore.
"""

from __future__ import annotations

import logging
import os

from google.cloud.firestore import AsyncClient

from app.http_client import get_functions_client

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
        self._http = get_functions_client()

    # --- User (direct Firestore — simple single-doc reads) ---

    async def get_user(self, user_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}").get()
        if not doc.exists:
            raise ValueError(f"User {user_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    async def get_user_attributes(self, user_id: str) -> dict:
        """Read user_attributes/{uid} subcollection doc (fitness_level, fitness_goal, etc.)."""
        doc = await self.db.document(f"users/{user_id}/user_attributes/{user_id}").get()
        return doc.to_dict() if doc.exists else {}

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

    # --- Planning Context (HTTP — server-side compact projection) ---

    async def get_planning_context(self, user_id: str) -> dict:
        """Fetch the full planning context via getPlanningContext Firebase Function.

        Uses the compact view which returns server-side projected data
        instead of assembling 7 parallel Firestore reads client-side.
        """
        return await self._http.post(
            "/getPlanningContext",
            user_id=user_id,
            body={"view": "compact", "workoutLimit": 10},
        )

    # --- Templates (HTTP — server-side projection) ---

    async def list_templates(self, user_id: str, include_exercises: bool = False) -> list[dict]:
        """List templates via getUserTemplates Firebase Function.

        When include_exercises=False, requests view=summary for smaller payloads.
        When include_exercises=True, omits view param to get full template data.
        """
        params = {}
        if not include_exercises:
            params["view"] = "summary"
        data = await self._http.get(
            "/getUserTemplates",
            user_id=user_id,
            params=params if params else None,
        )
        return data.get("templates", [])

    # --- Workouts (HTTP — server-side projection) ---

    async def list_recent_workouts(self, user_id: str, limit: int = 5) -> list[dict]:
        """List recent workouts via getUserWorkouts Firebase Function."""
        data = await self._http.get(
            "/getUserWorkouts",
            user_id=user_id,
            params={"view": "summary", "limit": str(limit)},
        )
        return data.get("workouts", [])

    # --- Training Analytics (HTTP) ---

    async def get_analysis_summary(self, user_id: str) -> dict | None:
        """Get analysis summary via getAnalysisSummary Firebase Function.

        Uses POST because the endpoint reads from req.body.
        """
        return await self._http.post(
            "/getAnalysisSummary",
            user_id=user_id,
            body={"include_expired": False},
        )

    async def get_weekly_review(self, user_id: str) -> dict | None:
        """Get weekly review via getAnalysisSummary with sections filter.

        Uses POST because the endpoint reads from req.body.
        """
        return await self._http.post(
            "/getAnalysisSummary",
            user_id=user_id,
            body={"sections": ["weekly_review"]},
        )

    async def get_muscle_group_summary(self, user_id: str, muscle_group: str, weeks: int = 8) -> dict:
        """Weekly series for a muscle group via getMuscleGroupSummary Firebase Function.

        Uses POST because the endpoint reads from req.body, not query params.
        """
        return await self._http.post(
            "/getMuscleGroupSummary",
            user_id=user_id,
            body={"muscle_group": muscle_group, "window_weeks": weeks},
        )

    async def get_exercise_summary(self, user_id: str, exercise_id: str) -> dict:
        """Per-exercise series via getExerciseSummary Firebase Function.

        Uses POST because the endpoint reads from req.body, not query params.
        """
        return await self._http.post(
            "/getExerciseSummary",
            user_id=user_id,
            body={"exercise_name": exercise_id, "weeks": 8},
        )

    async def query_sets(self, user_id: str, exercise_id: str, filters: dict | None = None) -> list[dict]:
        """Raw set-level drilldown via querySets Firebase Function."""
        body: dict = {
            "target": {"exercise_id": exercise_id},
            "limit": (filters or {}).get("limit", 50),
        }
        if filters:
            if filters.get("date_from"):
                body["target"]["date_from"] = filters["date_from"]
            if filters.get("date_to"):
                body["target"]["date_to"] = filters["date_to"]
        data = await self._http.post(
            "/querySets",
            user_id=user_id,
            body=body,
        )
        return data.get("sets", [])

    # --- Exercises (HTTP — uses shared client instead of inline httpx) ---

    async def search_exercises(self, query: str, limit: int = 10) -> list[dict]:
        """Search exercises via searchExercises Firebase Function.

        Uses the shared FunctionsClient for connection pooling instead of
        creating an inline httpx.AsyncClient per call.
        """
        data = await self._http.get(
            "/searchExercises",
            params={"query": query, "limit": str(limit)},
        )
        return data.get("exercises", [])

    # --- Conversations (direct Firestore — no HTTP endpoint) ---

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
