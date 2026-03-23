# tests/test_instruction.py
"""Tests for SHELL_INSTRUCTION content and build_system_instruction builder."""

from app.instruction import SHELL_INSTRUCTION, CORE_INSTRUCTION, WORKOUT_INSTRUCTION, build_system_instruction
from app.context import RequestContext


def _make_ctx(**overrides) -> RequestContext:
    defaults = dict(user_id="u-123", conversation_id="c-1", correlation_id="r-1")
    defaults.update(overrides)
    return RequestContext(**defaults)


# ── SHELL_INSTRUCTION content tests ──────────────────────────────────────


def test_shell_instruction_is_non_empty_string():
    assert isinstance(SHELL_INSTRUCTION, str)
    assert len(SHELL_INSTRUCTION) > 500


def test_shell_instruction_contains_key_sections():
    """All production-critical sections must be present."""
    required_sections = [
        "## IDENTITY",
        "## ABSOLUTE RULES",
        "## REASONING FRAMEWORK",
        "## RESPONSE CRAFT",
        "## USING YOUR TOOLS",
        "## INTERPRETING DATA",
        "## TRAINING KNOWLEDGE",
        "## BUILDING & MODIFYING WORKOUTS & ROUTINES",
        "## WEIGHT PRESCRIPTION",
        "## ACTIVE WORKOUT MODE",
        "## CONVERSATION HISTORY",
        "## EXAMPLES",
    ]
    for section in required_sections:
        assert section in SHELL_INSTRUCTION, f"Missing section: {section}"


def test_shell_instruction_no_forbidden_terms():
    """Must not contain Gemini-specific, ContextVar, or session-state references."""
    lower = SHELL_INSTRUCTION.lower()
    forbidden = ["gemini", "flash", "contextvar", "context_var", "session_id", "vertex"]
    for term in forbidden:
        assert term not in lower, f"Forbidden term found: {term}"


def test_shell_instruction_uses_request_context_not_context_prefix():
    """DATE AWARENESS should reference 'request context', not 'context prefix'."""
    assert "request context" in SHELL_INSTRUCTION
    assert "context prefix" not in SHELL_INSTRUCTION


def test_shell_instruction_has_conversation_history_section():
    """Memory guidance: conversation history section must exist with key advice."""
    assert "## CONVERSATION HISTORY" in SHELL_INSTRUCTION
    assert "conversation history" in SHELL_INSTRUCTION.lower()
    # Should mention referencing earlier messages
    assert "earlier" in SHELL_INSTRUCTION.lower()


# ── build_system_instruction tests ───────────────────────────────────────


def test_build_includes_today_date():
    ctx = _make_ctx(today="2026-03-17")
    result = build_system_instruction(ctx)
    assert "today=2026-03-17" in result


def test_build_includes_user_id():
    ctx = _make_ctx(user_id="u-abc")
    result = build_system_instruction(ctx)
    assert "user_id=u-abc" in result


def test_build_with_workout_id_includes_it():
    ctx = _make_ctx(workout_id="w-xyz")
    result = build_system_instruction(ctx)
    assert "workout_id=w-xyz" in result


def test_build_without_workout_id_omits_it():
    ctx = _make_ctx(workout_id=None)
    result = build_system_instruction(ctx)
    assert "workout_id=" not in result


def test_build_with_planning_prompt_appends_it():
    ctx = _make_ctx(today="2026-03-17")
    prompt = "Focus on progressive overload for bench press."
    result = build_system_instruction(ctx, planning_prompt=prompt)
    assert prompt in result
    assert "## PLANNING PROMPT" in result
    # Planning prompt should come after the main instruction
    main_end = result.index("## PLANNING PROMPT")
    assert main_end > len(SHELL_INSTRUCTION) // 2  # sanity: it's near the end


def test_build_without_planning_prompt_omits_section():
    ctx = _make_ctx()
    result = build_system_instruction(ctx)
    assert "## PLANNING PROMPT" not in result


def test_build_today_unknown_when_none():
    ctx = _make_ctx(today=None)
    result = build_system_instruction(ctx)
    assert "today=unknown" in result


def test_build_without_workout_contains_core_only():
    """Without a workout_id, only CORE_INSTRUCTION is included (no workout mode)."""
    ctx = _make_ctx(today="2026-01-01", workout_id=None)
    result = build_system_instruction(ctx)
    assert CORE_INSTRUCTION in result
    assert WORKOUT_INSTRUCTION not in result


def test_build_with_workout_contains_full_instruction():
    """With a workout_id, both CORE and WORKOUT instructions are included."""
    ctx = _make_ctx(today="2026-01-01", workout_id="w-123")
    result = build_system_instruction(ctx)
    assert CORE_INSTRUCTION in result
    assert WORKOUT_INSTRUCTION in result
