"""LLM usage tracking for cost attribution.

Captures token counts from Vertex AI / google-genai responses and writes
to the top-level Firestore collection ``llm_usage``.  All writes are
fire-and-forget: failures are logged but never crash the caller.

Gated by the ``ENABLE_USAGE_TRACKING`` env var (default: "false").

Categories:
    system         No user context (catalog enrichment, background system jobs)
    user_scoped    Background job for a specific user (training analyst)
    user_initiated User is actively waiting (shell agent, functional lane)
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

TRACKING_ENABLED = os.getenv("ENABLE_USAGE_TRACKING", "false").lower() == "true"
logger.info("Usage tracking: %s", "ENABLED" if TRACKING_ENABLED else "DISABLED")

# Singleton Firestore client — stateless and thread-safe, safe for concurrent
# requests on Vertex AI Agent Engine.  Benign double-init if two threads race
# past the None check (both clients work, one gets discarded).
_db = None


def _get_db():
    global _db
    if _db is None:
        from google.cloud import firestore

        _db = firestore.Client()
    return _db


def track_usage(
    *,
    user_id: Optional[str],
    category: str,
    system: str,
    feature: str,
    model: str,
    prompt_tokens: int,
    completion_tokens: int,
    total_tokens: int,
    thinking_tokens: Optional[int] = None,
) -> None:
    """Write a single usage record to Firestore.

    All parameters are keyword-only to prevent positional mistakes.
    Silently returns on any error so the caller's hot path is never affected.
    """
    if not TRACKING_ENABLED:
        return
    if total_tokens <= 0:
        return
    try:
        from google.cloud import firestore as _fs

        db = _get_db()
        db.collection("llm_usage").add({
            "user_id": user_id,
            "category": category,
            "system": system,
            "feature": feature,
            "model": model,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "thinking_tokens": thinking_tokens,
            "total_tokens": total_tokens,
            "created_at": _fs.SERVER_TIMESTAMP,
        })
    except Exception as e:
        logger.warning("Usage tracking write failed (non-fatal): %s", e)


# ---------------------------------------------------------------------------
# SDK-specific helpers to extract usage_metadata from different response types
# ---------------------------------------------------------------------------


def extract_usage_from_genai_response(response) -> Dict[str, Any]:
    """Extract token counts from a ``google.genai`` SDK response."""
    meta = getattr(response, "usage_metadata", None)
    if not meta:
        return {}
    return {
        "prompt_tokens": getattr(meta, "prompt_token_count", 0) or 0,
        "completion_tokens": getattr(meta, "candidates_token_count", 0) or 0,
        "total_tokens": getattr(meta, "total_token_count", 0) or 0,
        "thinking_tokens": getattr(meta, "thoughts_token_count", None),
    }


def extract_usage_from_vertex_response(response) -> Dict[str, Any]:
    """Extract token counts from a ``vertexai.generative_models`` response."""
    meta = getattr(response, "usage_metadata", None)
    if not meta:
        return {}
    return {
        "prompt_tokens": getattr(meta, "prompt_token_count", 0) or 0,
        "completion_tokens": getattr(meta, "candidates_token_count", 0) or 0,
        "total_tokens": getattr(meta, "total_token_count", 0) or 0,
        "thinking_tokens": getattr(meta, "thoughts_token_count", None),
    }


def accumulate_usage_from_chunk(chunk: dict, accumulator: dict) -> None:
    """Accumulate ``usage_metadata`` from ADK streaming chunks.

    **NOTE**: This function is currently unused.  ADK converts ``LlmResponse``
    objects into ``Event`` objects but does NOT copy ``usage_metadata`` onto the
    Event, so chunks yielded by ``AdkApp.stream_query()`` never contain token
    counts.  Usage tracking for the shell agent is handled instead by the
    ``after_model_callback`` on ``ShellAgent`` which calls ``track_usage()``
    directly per LLM turn (ContextVar doesn't work across ADK's thread
    boundary).

    Kept for reference and in case a future ADK version starts propagating
    usage_metadata on Events.
    """
    meta = chunk.get("usage_metadata")
    if not meta:
        return
    accumulator["prompt_tokens"] = (
        accumulator.get("prompt_tokens", 0)
        + (meta.get("prompt_token_count", 0) or 0)
    )
    accumulator["completion_tokens"] = (
        accumulator.get("completion_tokens", 0)
        + (meta.get("candidates_token_count", 0) or 0)
    )
    accumulator["total_tokens"] = (
        accumulator.get("total_tokens", 0)
        + (meta.get("total_token_count", 0) or 0)
    )
