# app/context.py
"""Request context — replaces ContextVar approach from ADK."""

from dataclasses import dataclass


@dataclass(frozen=True)
class RequestContext:
    """Immutable per-request context. Passed as function arg, not ContextVar."""
    user_id: str
    conversation_id: str
    correlation_id: str
    workout_id: str | None = None
    workout_mode: bool = False
    active_workout_id: str | None = None
    today: str | None = None  # YYYY-MM-DD, set from client timezone
