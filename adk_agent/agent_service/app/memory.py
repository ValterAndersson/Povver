# app/memory.py
"""Agent Memory Manager — persistent cross-conversation memory.

Tier 3 of the 4-tier memory system. Stores learned facts about the user
in users/{uid}/agent_memory/{auto-id}.
"""

from __future__ import annotations

from datetime import datetime, timezone
from google.cloud.firestore import AsyncClient


_mm_instance: 'MemoryManager | None' = None


def get_memory_manager() -> 'MemoryManager':
    """Module-level singleton — reuses gRPC channel."""
    global _mm_instance
    if _mm_instance is None:
        _mm_instance = MemoryManager()
    return _mm_instance


class MemoryManager:
    def __init__(self):
        self.db = AsyncClient()

    async def save_memory(
        self, user_id: str, content: str, category: str, conversation_id: str
    ) -> dict:
        data = {
            "content": content,
            "category": category,
            "active": True,
            "created_at": datetime.now(timezone.utc),
            "source_conversation_id": conversation_id,
        }
        ref = await self.db.collection(f"users/{user_id}/agent_memory").add(data)
        return {"id": ref[1].id, **data}

    async def retire_memory(
        self, user_id: str, memory_id: str, reason: str
    ) -> dict:
        doc_ref = self.db.document(f"users/{user_id}/agent_memory/{memory_id}")
        doc = await doc_ref.get()
        if not doc.exists:
            return {"error": f"Memory {memory_id} not found"}
        await doc_ref.update({
            "active": False,
            "retired_at": datetime.now(timezone.utc),
            "retire_reason": reason,
        })
        return {"retired": True, "memory_id": memory_id}

    async def list_active_memories(self, user_id: str, limit: int = 50) -> list[dict]:
        query = (
            self.db.collection(f"users/{user_id}/agent_memory")
            .where("active", "==", True)
            .order_by("created_at", direction="DESCENDING")
            .limit(limit)
        )
        return [{"id": doc.id, **doc.to_dict()} async for doc in query.stream()]

    async def generate_conversation_summary(
        self, user_id: str, conversation_id: str, llm_client, model: str
    ) -> str | None:
        """Generate a summary for a completed conversation (lazy, Tier 4)."""
        from app.firestore_client import FirestoreClient
        coll = FirestoreClient.CONVERSATION_COLLECTION
        conv_ref = self.db.document(
            f"users/{user_id}/{coll}/{conversation_id}"
        )
        conv = await conv_ref.get()
        if not conv.exists:
            return None
        if conv.to_dict().get("summary"):
            return conv.to_dict()["summary"]

        # Load last 10 messages
        msgs_query = (
            self.db.collection(
                f"users/{user_id}/{coll}/{conversation_id}/messages"
            )
            .order_by("created_at", direction="DESCENDING")
            .limit(10)
        )
        msgs = [doc.to_dict() async for doc in msgs_query.stream()]
        msgs.reverse()

        if not msgs:
            return None

        # Single-shot summary
        transcript = "\n".join(
            f"{m.get('type', 'user_prompt')}: {m.get('content', '')}" for m in msgs
        )
        prompt = (
            "Summarize this coaching conversation in 1-2 sentences. "
            "Focus on what was discussed and any decisions made.\n\n"
            f"{transcript}"
        )

        summary_text = ""
        async for chunk in llm_client.stream(
            model, [{"role": "user", "content": prompt}]
        ):
            if chunk.is_text:
                summary_text += chunk.text

        # Persist
        await conv_ref.update({
            "summary": summary_text,
            "completed_at": datetime.now(timezone.utc),
        })
        return summary_text
