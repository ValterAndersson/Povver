# app/context_builder.py
"""360 View Context Builder — assembles the full system context.

Auto-loaded before the LLM sees anything. Assembles:
1. INSTRUCTION (coaching persona + request context)
2. AGENT MEMORIES (cross-conversation)
3. RECENT CONVERSATIONS (last 5 summaries)
4. USER PROFILE + TRAINING SNAPSHOT
5. CONVERSATION HISTORY (last 20 messages)
"""

from __future__ import annotations

import asyncio
import logging

from app.context import RequestContext
from app.firestore_client import get_firestore_client, FirestoreClient
from app.instruction import build_system_instruction
from app.memory import get_memory_manager

logger = logging.getLogger(__name__)

MEMORY_GUIDANCE = """
## Memory Usage
You have access to save_memory, retire_memory, and list_memories tools.
Save important facts the user shares (preferences, injuries, goals, schedule).
Retire memories that are contradicted or no longer relevant.
Your saved memories are loaded automatically at the start of each conversation.
"""


async def build_system_context(
    ctx: RequestContext,
    llm_client=None,
    model: str = "gemini-3-flash-preview",
) -> tuple[str, list[dict]]:
    """Build instruction string and conversation history.

    Loads planning context, memories, history, and recent summaries in parallel,
    then assembles the full instruction with all context sections appended to the
    base instruction from build_system_instruction().

    Returns: (instruction, history_messages)
    """
    fs = get_firestore_client()
    mm = get_memory_manager()

    # Parallel loads
    planning_task = fs.get_planning_context(ctx.user_id)
    memories_task = mm.list_active_memories(ctx.user_id, limit=50)
    history_task = fs.get_conversation_messages(
        ctx.user_id, ctx.conversation_id, limit=80
    )
    summaries_task = _load_recent_summaries(fs, ctx.user_id, limit=5)
    alerts_task = _load_active_alerts(fs, ctx.user_id)

    planning, memories, history, summaries, alerts = await asyncio.gather(
        planning_task, memories_task, history_task, summaries_task,
        alerts_task,
        return_exceptions=True,
    )

    # Handle errors gracefully — first-time users may have no data
    if isinstance(planning, Exception):
        logger.warning("Failed to load planning context: %s", planning)
        planning = {}
    if isinstance(memories, Exception):
        logger.warning("Failed to load memories: %s", memories)
        memories = []
    if isinstance(history, Exception):
        logger.warning("Failed to load history: %s", history)
        history = []
    if isinstance(summaries, Exception):
        logger.warning("Failed to load summaries: %s", summaries)
        summaries = []
    if isinstance(alerts, Exception):
        logger.warning("Failed to load active alerts: %s", alerts)
        alerts = {}

    # Lazy summary generation for previous conversation
    if llm_client and isinstance(summaries, list):
        try:
            await _maybe_generate_previous_summary(fs, mm, ctx, llm_client, model)
        except Exception as e:
            logger.warning("Failed to generate previous summary: %s", e)

    # Build base instruction with request context
    base_instruction = build_system_instruction(ctx)

    # Append additional context sections
    extra_sections = [MEMORY_GUIDANCE]

    if memories:
        mem_text = "\n".join(f"- [{m['category']}] {m['content']}" for m in memories)
        extra_sections.append(f"## What You Know About This User\n{mem_text}")

    if summaries:
        sum_text = "\n".join(f"- {s}" for s in summaries)
        extra_sections.append(f"## Recent Conversations\n{sum_text}")

    if isinstance(planning, dict):
        extra_sections.append(_format_snapshot(planning))

    if isinstance(alerts, dict) and alerts:
        extra_sections.append(_format_active_alerts(alerts))

    # Session vars
    try:
        session_vars = await _get_session_vars(fs, ctx)
        if session_vars:
            vars_text = "\n".join(f"- {k}: {v}" for k, v in session_vars.items())
            extra_sections.append(f"## Session State\n{vars_text}")
    except Exception as e:
        logger.warning("Failed to load session vars: %s", e)

    instruction = base_instruction + "\n\n" + "\n\n".join(extra_sections)

    # Format history for LLM
    formatted_history = _format_history(history)

    # Compact history if it exceeds token budget
    if llm_client and formatted_history:
        try:
            formatted_history = await _compact_history_if_needed(
                formatted_history, llm_client, model
            )
        except Exception as e:
            logger.warning("History compaction failed, using full history: %s", e)

    return instruction, formatted_history


async def _load_active_alerts(
    fs: FirestoreClient, user_id: str
) -> dict:
    """Load the latest plateau_report, volume_optimization, and periodization_status
    from analysis_insights for the Active Alerts context section.

    Queries recent insights (last 7 days) filtered by section type.
    Returns dict keyed by section name with the latest data for each.
    """
    alerts = {}
    target_sections = {"plateau_report", "volume_optimization", "periodization_status"}

    try:
        from datetime import datetime, timedelta, timezone
        cutoff = datetime.now(timezone.utc) - timedelta(days=7)

        query = (
            fs.db.collection(f"users/{user_id}/analysis_insights")
            .where("created_at", ">=", cutoff)
            .order_by("created_at", direction="DESCENDING")
            .limit(20)
        )

        async for doc in query.stream():
            data = doc.to_dict()
            section = data.get("section") or data.get("type")
            if section in target_sections and section not in alerts:
                alerts[section] = data
                if len(alerts) >= len(target_sections):
                    break

        # Also check weekly_reviews for periodization_status if not found in insights
        if "periodization_status" not in alerts:
            review_query = (
                fs.db.collection(f"users/{user_id}/weekly_reviews")
                .order_by("created_at", direction="DESCENDING")
                .limit(1)
            )
            async for doc in review_query.stream():
                data = doc.to_dict()
                if data.get("periodization_status"):
                    alerts["periodization_status"] = {
                        "section": "periodization_status",
                        **data["periodization_status"],
                    }

    except Exception as e:
        logger.warning("Failed to load active alerts for user %s: %s", user_id, e)

    return alerts


async def _load_recent_summaries(
    fs: FirestoreClient, user_id: str, limit: int
) -> list[str]:
    """Load recent conversation summaries.

    Queries by completed_at descending and filters out docs without summaries
    in Python. This avoids the Firestore orderBy-on-inequality-field issue
    that would sort by summary text alphabetically instead of by recency.
    """
    coll = fs.CONVERSATION_COLLECTION
    query = (
        fs.db.collection(f"users/{user_id}/{coll}")
        .order_by("completed_at", direction="DESCENDING")
        .limit(limit * 2)  # Over-fetch to account for docs without summaries
    )
    summaries = []
    async for doc in query.stream():
        summary = doc.to_dict().get("summary")
        if summary:
            summaries.append(summary)
            if len(summaries) >= limit:
                break
    return summaries


async def _maybe_generate_previous_summary(
    fs: FirestoreClient, mm, ctx: RequestContext, llm_client, model: str
) -> None:
    """Lazy summary: check if previous conversation needs a summary."""
    coll = fs.CONVERSATION_COLLECTION
    query = (
        fs.db.collection(f"users/{ctx.user_id}/{coll}")
        .order_by("created_at", direction="DESCENDING")
        .limit(2)
    )
    convs = [doc async for doc in query.stream()]
    if len(convs) < 2:
        return
    prev = convs[1]  # Second most recent
    if not prev.to_dict().get("summary"):
        await mm.generate_conversation_summary(
            ctx.user_id, prev.id, llm_client, model
        )


async def _get_session_vars(
    fs: FirestoreClient, ctx: RequestContext
) -> dict | None:
    """Load session variables from conversation doc."""
    coll = fs.CONVERSATION_COLLECTION
    doc = await fs.db.document(
        f"users/{ctx.user_id}/{coll}/{ctx.conversation_id}"
    ).get()
    if doc.exists:
        return doc.to_dict().get("session_vars")
    return None


def _format_active_alerts(alerts: dict) -> str:
    """Format active alerts as brief pointers — details fetched on demand."""
    flags = []

    plateau = alerts.get("plateau_report")
    if plateau:
        exercises = plateau.get("plateaued_exercises", [])
        for ex in exercises[:3]:
            name = ex.get("exercise_name", "?")
            weeks = ex.get("weeks_stalled", "?")
            action = ex.get("suggested_action", "review")
            flags.append(f"Plateau: {name} ({weeks}wk, suggested: {action})")

    volume = alerts.get("volume_optimization")
    if volume:
        volume_data = volume.get("volume_by_muscle", {})
        deficit_count = sum(1 for v in volume_data.values() if v.get("status") == "deficit")
        surplus_count = sum(1 for v in volume_data.values() if v.get("status") == "surplus")
        if deficit_count:
            flags.append(f"{deficit_count} muscle group(s) below MEV")
        if surplus_count:
            flags.append(f"{surplus_count} muscle group(s) above MRV")

    period = alerts.get("periodization_status")
    if period:
        acwr = period.get("acwr")
        if acwr is not None:
            flags.append(f"ACWR: {acwr}")
        if period.get("suggest_deload"):
            flags.append("Deload recommended")

    if not flags:
        return ""

    return "## Active Flags\n" + "\n".join(f"- {f}" for f in flags) + \
        "\nUse get_training_analysis for full details if relevant to the user's question."


def _format_snapshot(planning: dict) -> str:
    """Format planning context as brief orientation — not a data source."""
    parts = []
    user = planning.get("user", {})
    if user.get("name"):
        parts.append(f"User: {user['name']}")

    # fitness_level / fitness_goal: check both flat (HTTP compact) and nested (legacy)
    attrs = user.get("attributes", {})
    fitness_level = attrs.get("fitness_level") or user.get("fitness_level")
    fitness_goal = attrs.get("fitness_goal") or user.get("fitness_goal")
    if fitness_level:
        parts.append(f"Level: {fitness_level}")
    if fitness_goal:
        parts.append(f"Goal: {fitness_goal}")

    weight_unit = user.get("weight_unit", "kg")
    parts.append(f"Unit: {weight_unit}")

    # active_routine (legacy snake_case) or activeRoutine (HTTP camelCase)
    routine = planning.get("active_routine") or planning.get("activeRoutine")
    if routine:
        parts.append(f"Routine: {routine.get('name', 'Unknown')}")

    if not parts:
        return ""

    return "## Training Snapshot\n" + " | ".join(parts)


HISTORY_TOKEN_BUDGET = 8000  # ~32K chars — compact if history exceeds this
RECENT_TURNS_TO_KEEP = 3    # Always keep the last N user→assistant turns uncompacted

COMPACTION_PROMPT = """Summarize this conversation history concisely. Preserve:
- Key data points and numbers the coach referenced (weights, reps, dates, percentages)
- What tools were called and the important data they returned
- Decisions made and recommendations given
- The user's goals, concerns, and preferences expressed

Write the summary as a narrative, not a list. Use 200-400 words. Focus on what the model would need to continue the conversation coherently."""


def _estimate_tokens(messages: list[dict]) -> int:
    """Rough token estimate: chars / 4."""
    import json as _json
    total = 0
    for msg in messages:
        total += len(_json.dumps(msg, default=str))
    return total // 4


def _find_turn_boundary(messages: list[dict], keep_recent: int) -> int:
    """Find the index where 'recent' turns start.

    A turn starts with a user message. We count backwards from the end
    to find the boundary that keeps `keep_recent` complete turns.
    """
    turns_found = 0
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("role") == "user":
            turns_found += 1
            if turns_found >= keep_recent:
                return i
    return 0


async def _compact_history_if_needed(
    messages: list[dict], llm_client, model: str
) -> list[dict]:
    """Compact conversation history if it exceeds the token budget.

    Splits history into old and recent portions at a turn boundary.
    Summarizes old portion using the LLM and prepends as a summary message.
    """
    import json as _json

    estimated = _estimate_tokens(messages)
    if estimated <= HISTORY_TOKEN_BUDGET:
        return messages

    logger.info(
        "History exceeds token budget (%d > %d), compacting",
        estimated, HISTORY_TOKEN_BUDGET,
    )

    # Split at turn boundary
    boundary = _find_turn_boundary(messages, RECENT_TURNS_TO_KEEP)
    if boundary <= 0:
        return messages  # Not enough turns to compact

    old_messages = messages[:boundary]
    recent_messages = messages[boundary:]

    # Summarize old messages
    old_text = _json.dumps(old_messages, indent=1, default=str)
    summary_messages = [
        {"role": "system", "content": COMPACTION_PROMPT},
        {"role": "user", "content": old_text},
    ]

    summary_text = ""
    async for chunk in llm_client.stream(model, summary_messages, None, None):
        if chunk.is_text:
            summary_text += chunk.text

    if not summary_text.strip():
        logger.warning("Compaction produced empty summary, keeping full history")
        return messages

    logger.info(
        "Compacted %d old messages into summary (%d chars), keeping %d recent",
        len(old_messages), len(summary_text), len(recent_messages),
    )

    # Return summary + recent turns
    compacted = [
        {
            "role": "user",
            "content": (
                "[CONVERSATION SUMMARY — earlier turns compacted]\n"
                + summary_text.strip()
            ),
        },
    ]
    compacted.extend(recent_messages)
    return compacted


def _format_history(messages: list[dict]) -> list[dict]:
    """Format Firestore messages to LLM history format.

    Tool interactions from prior turns are merged into the assistant's text
    as a [DATA CONTEXT] block. Gemini's thinking models require thought
    signatures on native function calls, which are ephemeral — so we can't
    replay them from stored data. Text-based context achieves the same goal:
    the model knows what tools it called and what data came back.

    Firestore message types → LLM roles:
    - user_prompt   → {"role": "user", "content": ...}
    - agent_response / agentResponse → {"role": "assistant", "content": ...}
    - tool_calls    → accumulated into next agent_response as [DATA CONTEXT]
    - tool_result   → accumulated into next agent_response as [DATA CONTEXT]
    - artifact      → skipped (rendered as cards in the UI)
    - summary       → {"role": "user", "content": ...} (compacted history)
    """
    import json as _json

    TYPE_TO_ROLE = {
        "user_prompt": "user",
        "agent_response": "assistant",
        "agentResponse": "assistant",
    }

    # First pass: collect tool interactions to merge into assistant responses
    # The Firestore ordering is: user_prompt → tool_calls → tool_result(s) → agent_response
    formatted = []
    pending_tool_context: list[str] = []

    for msg in messages:
        msg_type = msg.get("type", "user_prompt")

        # Accumulate tool calls as text context
        if msg_type == "tool_calls":
            content = msg.get("content", "[]")
            calls = _json.loads(content) if isinstance(content, str) else content
            for call in calls:
                pending_tool_context.append(
                    f"Called {call.get('name', '?')}({_json.dumps(call.get('args', {}), default=str)})"
                )
            continue

        # Accumulate tool results as text context
        if msg_type == "tool_result":
            content = msg.get("content", "{}")
            result = _json.loads(content) if isinstance(content, str) else content
            tool_name = msg.get("tool_name", "unknown")
            # Compact large results to avoid bloating context
            result_str = _json.dumps(result, default=str)
            if len(result_str) > 2000:
                result_str = result_str[:2000] + "..."
            pending_tool_context.append(
                f"Result from {tool_name}: {result_str}"
            )
            continue

        # Assistant response — prepend any accumulated tool context
        role = TYPE_TO_ROLE.get(msg_type)
        if role == "assistant" and pending_tool_context:
            tool_block = "[DATA CONTEXT — tools called this turn]\n" + "\n".join(pending_tool_context)
            content = msg.get("content", "")
            formatted.append({
                "role": "assistant",
                "content": tool_block + "\n\n" + content,
            })
            pending_tool_context.clear()
            continue

        if role:
            # Flush any orphaned tool context before a user message
            if role == "user" and pending_tool_context:
                formatted.append({
                    "role": "assistant",
                    "content": "[DATA CONTEXT — tools called this turn]\n" + "\n".join(pending_tool_context),
                })
                pending_tool_context.clear()
            formatted.append({"role": role, "content": msg.get("content", "")})
            continue

        # Compacted history summary
        if msg_type == "summary":
            formatted.append({
                "role": "user",
                "content": (
                    "[CONVERSATION SUMMARY — earlier turns compacted]\n"
                    + msg.get("content", "")
                ),
            })
            continue

        # Skip artifacts and unknown types

    # Flush any trailing tool context
    if pending_tool_context:
        formatted.append({
            "role": "assistant",
            "content": "[DATA CONTEXT — tools called this turn]\n" + "\n".join(pending_tool_context),
        })

    return formatted


__all__ = ["build_system_context", "MEMORY_GUIDANCE"]
