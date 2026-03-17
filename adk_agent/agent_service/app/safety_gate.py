# app/safety_gate.py
"""Safety Gate — enforces confirmation for destructive / write operations.

Migrated from canvas_orchestrator/app/shell/safety_gate.py.
Changes: ContextVar replaced with explicit RequestContext parameter.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any

from app.context import RequestContext

logger = logging.getLogger(__name__)


class WriteOperation(str, Enum):
    """Tracked write operations that require safety gate."""
    PROPOSE_WORKOUT = "propose_workout"
    PROPOSE_ROUTINE = "propose_routine"
    CREATE_TEMPLATE = "create_template"
    UPDATE_ROUTINE = "update_routine"


# Keywords that indicate the user wants something destructive
DESTRUCTIVE_KEYWORDS = frozenset([
    "delete", "remove", "clear", "reset", "erase", "destroy", "wipe",
])

# Keywords that indicate explicit permission / confirmation
CONFIRM_KEYWORDS = frozenset([
    "confirm", "yes", "do it", "go ahead", "publish", "save",
    "create it", "make it", "build it", "looks good", "approved",
])


@dataclass
class SafetyResult:
    """Result of a safety-gate check."""
    needs_confirmation: bool
    reason: str | None = None


@dataclass
class SafetyDecision:
    """Full decision for write-operation gate (used internally by agent loop)."""
    allow_execute: bool
    dry_run: bool
    reason: str
    requires_confirmation: bool = False

    @property
    def should_preview(self) -> bool:
        """True if we should show preview instead of executing."""
        return self.dry_run or self.requires_confirmation


def check_safety(message: str, ctx: RequestContext) -> SafetyResult:
    """Check whether a user message requires confirmation before acting.

    Scans for destructive keywords (delete, remove, etc.).
    Pure function — no I/O, no side-effects.

    Args:
        message: The user's message text.
        ctx: Request context (available for future per-user overrides).

    Returns:
        SafetyResult indicating whether confirmation is needed.
    """
    lower = message.lower().strip()

    for keyword in DESTRUCTIVE_KEYWORDS:
        if keyword in lower:
            logger.info(
                "SAFETY_GATE: Destructive keyword '%s' detected [user=%s]",
                keyword, ctx.user_id,
            )
            return SafetyResult(
                needs_confirmation=True,
                reason=f"Message contains destructive keyword: '{keyword}'",
            )

    return SafetyResult(needs_confirmation=False)


def check_message_for_confirmation(message: str) -> bool:
    """Check if a user message contains explicit confirmation.

    Args:
        message: User's message.

    Returns:
        True if message contains confirmation keywords.
    """
    lower = message.lower().strip()

    for keyword in CONFIRM_KEYWORDS:
        if lower == keyword or lower.startswith(f"{keyword} ") or lower.endswith(f" {keyword}"):
            return True

    return False


def check_safety_gate(
    operation: WriteOperation,
    message: str,
    conversation_history: list[dict[str, Any]] | None = None,
    force_dry_run: bool = False,
) -> SafetyDecision:
    """Check if a write operation should execute or require confirmation.

    Logic:
    1. If force_dry_run=True, always preview
    2. If message contains explicit confirmation, allow execute
    3. If previous message was a preview, and this is confirmation, allow execute
    4. Otherwise, return preview and require confirmation

    Args:
        operation: The write operation being attempted.
        message: Current user message.
        conversation_history: Previous messages (to detect preview->confirm flow).
        force_dry_run: Force preview mode regardless of confirmation.

    Returns:
        SafetyDecision with allow_execute, dry_run, and reason.
    """
    if force_dry_run:
        return SafetyDecision(
            allow_execute=False,
            dry_run=True,
            reason="Forced dry run mode",
        )

    if check_message_for_confirmation(message):
        logger.info("SAFETY_GATE: Explicit confirmation detected: %s", message[:30])
        return SafetyDecision(
            allow_execute=True,
            dry_run=False,
            reason="Explicit confirmation in message",
        )

    if conversation_history:
        for msg in reversed(conversation_history[-3:]):
            if msg.get("role") == "assistant":
                content = msg.get("content", "")
                if "Ready to publish" in content or "preview" in content.lower():
                    if any(kw in message.lower() for kw in ["yes", "ok", "confirm", "go"]):
                        logger.info("SAFETY_GATE: Preview->confirm flow detected")
                        return SafetyDecision(
                            allow_execute=True,
                            dry_run=False,
                            reason="Confirmation after preview",
                        )

    logger.info("SAFETY_GATE: Requiring confirmation for %s", operation)
    return SafetyDecision(
        allow_execute=False,
        dry_run=True,
        requires_confirmation=True,
        reason=f"Write operation '{operation}' requires confirmation",
    )


def format_confirmation_prompt(operation: WriteOperation, preview_data: dict[str, Any]) -> str:
    """Format a confirmation prompt based on the preview data."""
    if operation == WriteOperation.PROPOSE_WORKOUT:
        title = preview_data.get("preview", {}).get("title", "workout")
        exercise_count = preview_data.get("preview", {}).get("exercise_count", 0)
        return f"Ready to publish '{title}' ({exercise_count} exercises). Say 'confirm' to publish."

    elif operation == WriteOperation.PROPOSE_ROUTINE:
        name = preview_data.get("preview", {}).get("name", "routine")
        workout_count = preview_data.get("preview", {}).get("workout_count", 0)
        return f"Ready to publish '{name}' ({workout_count} workouts). Say 'confirm' to publish."

    return "Ready to publish. Say 'confirm' to proceed."


__all__ = [
    "SafetyResult",
    "SafetyDecision",
    "WriteOperation",
    "check_safety",
    "check_safety_gate",
    "check_message_for_confirmation",
    "format_confirmation_prompt",
]
