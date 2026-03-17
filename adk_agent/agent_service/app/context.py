# app/context.py
"""Request context — replaces ContextVar approach from ADK."""

from dataclasses import dataclass


@dataclass(frozen=True)
class RequestContext:
    """Immutable per-request context. Passed as function arg, not ContextVar."""
    user_id: str
    conversation_id: str
    correlation_id: str
    workout_id: str | None = None  # Active workout ID from iOS (enables workout mode)
    workout_mode: bool = False     # True when workout_id is present
    today: str | None = None  # YYYY-MM-DD, set from client timezone
