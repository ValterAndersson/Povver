# app/tools/memory_tools.py
"""Memory and session variable tools for the agent."""

from __future__ import annotations

from app.context import RequestContext


async def save_memory(*, ctx: RequestContext, content: str, category: str) -> dict:
    """Save a fact about the user to persistent memory."""
    from app.memory import get_memory_manager
    mm = get_memory_manager()
    return await mm.save_memory(ctx.user_id, content, category, ctx.conversation_id)


async def retire_memory(*, ctx: RequestContext, memory_id: str, reason: str) -> dict:
    """Retire (soft-delete) a memory that is no longer accurate."""
    from app.memory import get_memory_manager
    mm = get_memory_manager()
    return await mm.retire_memory(ctx.user_id, memory_id, reason)


async def list_memories(*, ctx: RequestContext, limit: int = 50) -> dict:
    """List active memories for the current user."""
    from app.memory import get_memory_manager
    mm = get_memory_manager()
    memories = await mm.list_active_memories(ctx.user_id, limit=limit)
    return {"memories": memories, "count": len(memories)}


import re
_SESSION_VAR_KEY_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]{0,63}$")


async def set_session_var(*, ctx: RequestContext, key: str, value: str) -> dict:
    """Set a session variable on the current conversation."""
    if not _SESSION_VAR_KEY_RE.match(key):
        raise ValueError(f"Invalid session var key: must match [a-zA-Z_][a-zA-Z0-9_]{{0,63}}")
    from app.firestore_client import get_firestore_client
    fs = get_firestore_client()
    coll = fs.CONVERSATION_COLLECTION
    await fs.db.document(
        f"users/{ctx.user_id}/{coll}/{ctx.conversation_id}"
    ).update({f"session_vars.{key}": value})
    return {"set": key, "value": value}


async def delete_session_var(*, ctx: RequestContext, key: str) -> dict:
    """Delete a session variable from the current conversation."""
    if not _SESSION_VAR_KEY_RE.match(key):
        raise ValueError(f"Invalid session var key: must match [a-zA-Z_][a-zA-Z0-9_]{{0,63}}")
    from google.cloud.firestore import DELETE_FIELD
    from app.firestore_client import get_firestore_client
    fs = get_firestore_client()
    coll = fs.CONVERSATION_COLLECTION
    await fs.db.document(
        f"users/{ctx.user_id}/{coll}/{ctx.conversation_id}"
    ).update({f"session_vars.{key}": DELETE_FIELD})
    return {"deleted": key}


async def search_past_conversations(*, ctx: RequestContext, query: str, limit: int = 5) -> dict:
    """Search past conversations by keyword in summaries."""
    from app.firestore_client import get_firestore_client
    fs = get_firestore_client()
    coll = fs.CONVERSATION_COLLECTION
    convs_query = (
        fs.db.collection(f"users/{ctx.user_id}/{coll}")
        .order_by("created_at", direction="DESCENDING")
        .limit(20)
    )
    results = []
    async for conv_doc in convs_query.stream():
        conv_data = conv_doc.to_dict()
        summary = conv_data.get("summary", "")
        if query.lower() in summary.lower():
            results.append({
                "conversation_id": conv_doc.id,
                "summary": summary,
                "date": str(conv_data.get("completed_at", "")),
            })
            if len(results) >= limit:
                break
    return {"results": results}
