# app/critic.py
"""Critic — response validation for coaching advice and artifact creation.

Migrated from canvas_orchestrator/app/shell/critic.py.
Changes: ContextVar replaced with explicit RequestContext parameter.

Runs a second-pass check on agent responses for:
1. Safety violations (dangerous advice)
2. Hallucination detection (claims without data backing)
3. Medical advice detection
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any

from app.context import RequestContext

logger = logging.getLogger(__name__)


class CriticSeverity(str, Enum):
    """Severity levels for critic findings."""
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass
class CriticFinding:
    """A single finding from the critic."""
    severity: CriticSeverity
    category: str
    message: str
    suggestion: str | None = None


@dataclass
class CriticResult:
    """Result of critic evaluation."""
    approved: bool
    issues: list[str]
    revised_response: str | None = None
    findings: list[CriticFinding] = field(default_factory=list)

    @property
    def has_errors(self) -> bool:
        return any(f.severity == CriticSeverity.ERROR for f in self.findings)


# ============================================================================
# SAFETY PATTERNS — flag dangerous advice
# ============================================================================

SAFETY_PATTERNS: list[tuple[re.Pattern, str, CriticSeverity]] = [
    # Pain-related advice
    (re.compile(r"\b(work through|push through|ignore)\b.{0,20}\bpain\b", re.I),
     "Advising to ignore pain is dangerous", CriticSeverity.ERROR),

    # Extreme volume recommendations
    (re.compile(r"\b(40|50|60)\+?\s+sets?\b.{0,20}\b(per\s+muscle|weekly)\b", re.I),
     "Extreme volume recommendation (>30 sets/muscle/week)", CriticSeverity.WARNING),

    # Dangerous rep ranges for compound lifts
    (re.compile(r"\b(deadlift|squat|clean)\b.{0,30}\b(1|2)\s+reps?\b.{0,20}\b(max|failure)\b", re.I),
     "1-2 rep max on compound lift without safety context", CriticSeverity.WARNING),
]


# ============================================================================
# MEDICAL ADVICE PATTERNS — flag unsolicited medical recommendations
# ============================================================================

MEDICAL_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\b(take|use|try)\b.{0,15}\b(ibuprofen|advil|aspirin|tylenol|naproxen|acetaminophen|nsaid)\b", re.I),
     "Response contains specific medication recommendation"),

    (re.compile(r"\b(should|need to|must)\b.{0,15}\b(see a doctor|visit.*doctor|consult.*physician)\b", re.I),
     "Response contains medical referral (may be appropriate but flagged for review)"),
]


# ============================================================================
# HALLUCINATION PATTERNS — claims without data
# ============================================================================

HALLUCINATION_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"your\s+(e1rm|1rm|max)\s+(is|was|hit)\s+\d+", re.I),
     "Specific e1RM claim - verify data was fetched"),

    (re.compile(r"you('ve|.have)\s+(gained|lost|improved)\s+\d+", re.I),
     "Specific progress claim - verify data was fetched"),
]


def _check_safety(response: str) -> list[CriticFinding]:
    """Check for safety violations in response."""
    findings = []
    for pattern, description, severity in SAFETY_PATTERNS:
        if pattern.search(response):
            findings.append(CriticFinding(
                severity=severity,
                category="safety",
                message=description,
                suggestion="Review and modify advice to be safer",
            ))
    return findings


def _check_medical_advice(response: str) -> list[CriticFinding]:
    """Check for unsolicited medical advice."""
    findings = []
    for pattern, description in MEDICAL_PATTERNS:
        if pattern.search(response):
            findings.append(CriticFinding(
                severity=CriticSeverity.ERROR,
                category="medical",
                message=description,
                suggestion="Remove specific medication names; suggest consulting a professional instead",
            ))
    return findings


def _check_hallucination(
    response: str,
    analytics_data: dict[str, Any] | None = None,
) -> list[CriticFinding]:
    """Check for hallucinated claims without data backing."""
    findings = []
    if not analytics_data:
        for pattern, description in HALLUCINATION_PATTERNS:
            if pattern.search(response):
                findings.append(CriticFinding(
                    severity=CriticSeverity.WARNING,
                    category="hallucination",
                    message=description,
                    suggestion="Ensure analytics tools were called before making data claims",
                ))
    return findings


def _check_artifact_quality(
    response: str,
    artifact_data: dict[str, Any] | None = None,
) -> list[CriticFinding]:
    """Check artifact creation quality."""
    findings = []
    if not artifact_data:
        return findings

    if artifact_data.get("type") == "session_plan":
        blocks = artifact_data.get("content", {}).get("blocks", [])
        if len(blocks) < 3:
            findings.append(CriticFinding(
                severity=CriticSeverity.WARNING,
                category="artifact_quality",
                message=f"Workout has only {len(blocks)} exercises (minimum 3 recommended)",
            ))
        missing_ids = [b["name"] for b in blocks if not b.get("exercise_id")]
        if missing_ids:
            findings.append(CriticFinding(
                severity=CriticSeverity.WARNING,
                category="artifact_quality",
                message=f"Exercises missing IDs: {', '.join(missing_ids[:3])}",
                suggestion="Use search_exercises to get valid exercise IDs",
            ))

    return findings


def review_response(response: str, ctx: RequestContext) -> CriticResult:
    """Run critic evaluation on an agent response.

    Checks for safety violations, medical advice, and hallucination patterns.
    Pure function — no I/O, no side-effects.

    Args:
        response: The agent's response text.
        ctx: Request context (available for future per-user overrides).

    Returns:
        CriticResult with approval status and issues found.
    """
    findings: list[CriticFinding] = []

    findings.extend(_check_safety(response))
    findings.extend(_check_medical_advice(response))
    findings.extend(_check_hallucination(response))

    issues = [f.message for f in findings]
    approved = not any(f.severity == CriticSeverity.ERROR for f in findings)

    if findings:
        logger.info(
            "CRITIC: %d findings (%s) [user=%s]",
            len(findings),
            "APPROVED" if approved else "REJECTED",
            ctx.user_id,
        )
        for f in findings:
            logger.info("  [%s] %s: %s", f.severity.value.upper(), f.category, f.message)

    return CriticResult(
        approved=approved,
        issues=issues,
        revised_response=None,
        findings=findings,
    )


def run_critic(
    response: str,
    response_type: str = "general",
    analytics_data: dict[str, Any] | None = None,
    artifact_data: dict[str, Any] | None = None,
) -> CriticResult:
    """Full critic pass (used internally when ctx is not available).

    Args:
        response: Agent response text.
        response_type: Type of response ("coaching", "artifact", "general").
        analytics_data: Analytics data used (for verification).
        artifact_data: Created artifact (for quality check).

    Returns:
        CriticResult with pass/fail and findings.
    """
    findings: list[CriticFinding] = []

    findings.extend(_check_safety(response))
    findings.extend(_check_medical_advice(response))

    if response_type in ("coaching", "general"):
        findings.extend(_check_hallucination(response, analytics_data))

    if response_type == "artifact" and artifact_data:
        findings.extend(_check_artifact_quality(response, artifact_data))

    issues = [f.message for f in findings]
    approved = not any(f.severity == CriticSeverity.ERROR for f in findings)

    if findings:
        logger.info(
            "CRITIC: %d findings (%s)",
            len(findings),
            "APPROVED" if approved else "REJECTED",
        )

    return CriticResult(approved=approved, issues=issues, findings=findings)


def should_run_critic(routing_intent: str | None, response_length: int) -> bool:
    """Determine if critic should run for this response."""
    critic_intents = {
        "ANALYZE_PROGRESS",
        "PLAN_ARTIFACT",
        "PLAN_ROUTINE",
        "EDIT_PLAN",
    }

    if routing_intent in critic_intents:
        return True

    if response_length > 500:
        return True

    return False


__all__ = [
    "CriticSeverity",
    "CriticFinding",
    "CriticResult",
    "review_response",
    "run_critic",
    "should_run_critic",
]
