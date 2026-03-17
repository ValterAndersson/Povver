"""4-lane message router — migrated from shell/router.py.

Lanes:
- Fast Lane: Regex -> direct skill execution (no LLM, <500ms)
- Slow Lane: Shell Agent (LLM) for conversational reasoning
- Functional Lane: LLM for structured JSON in/out (Smart Buttons)
- Worker Lane: Background scripts (triggered by PubSub, not routed here)
"""

from __future__ import annotations

import json
import logging
import re
from enum import Enum
from typing import Any

logger = logging.getLogger(__name__)


class Lane(str, Enum):
    """Request processing lanes."""
    FAST = "fast"
    SLOW = "slow"
    FUNCTIONAL = "functional"
    WORKER = "worker"


# Fast Lane patterns — regex match -> direct skill execution, no LLM
FAST_PATTERNS = [
    # "log", "done", "finished", "completed" (optionally followed by "set")
    re.compile(r"^(log|done|finished|completed)(\s+set)?$", re.I),
    # Shorthand: "8@100", "8 @ 100kg"
    re.compile(r"^(\d+)\s*@\s*(\d+(?:\.\d+)?)\s*(?:kg|lbs?)?$", re.I),
    # "log 8 reps at 100kg", "8 reps @ 100"
    re.compile(
        r"^(?:log\s+)?(\d+)\s*(?:reps?\s*)?(?:@|at)\s*(\d+(?:\.\d+)?)\s*(?:kg|lbs?|pounds?)?$",
        re.I,
    ),
    # "next", "next set"
    re.compile(r"^next(\s+set)?$", re.I),
    # "what's next?"
    re.compile(r"^what.?s\s+next\??$", re.I),
    # "rest", "resting", "ok", "ready"
    re.compile(r"^(rest|resting|ok|ready)$", re.I),
    # "log set ..."
    re.compile(r"^log\s+set\b", re.I),
    # Bare rep count: "8", "12"
    re.compile(r"^(\d+)\s*(?:reps?)?$", re.I),
]

# Functional Lane intents (JSON payloads from UI Smart Buttons)
FUNCTIONAL_INTENTS = frozenset([
    "SWAP_EXERCISE",
    "AUTOFILL_SET",
    "SUGGEST_WEIGHT",
    "MONITOR_STATE",
])


def route_request(payload: str | dict[str, Any]) -> Lane:
    """Route a message to the appropriate lane.

    - str: Text message -> route via regex (Fast/Slow)
    - dict: JSON payload -> route via intent field (Functional)
    """
    if isinstance(payload, dict):
        return _route_dict(payload)

    text = payload.strip()

    # Try JSON parse (frontend may serialize JSON as string)
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return _route_dict(parsed)
    except (json.JSONDecodeError, TypeError):
        pass

    # Check fast lane patterns
    for pattern in FAST_PATTERNS:
        if pattern.match(text):
            return Lane.FAST

    return Lane.SLOW


def _route_dict(payload: dict[str, Any]) -> Lane:
    """Route a JSON payload based on intent or structure."""
    intent = payload.get("intent")
    if intent:
        if intent in FUNCTIONAL_INTENTS:
            return Lane.FUNCTIONAL
        return Lane.SLOW

    # Dict with message field -> route as text
    message = payload.get("message")
    if message and isinstance(message, str):
        return route_request(message)

    return Lane.SLOW
