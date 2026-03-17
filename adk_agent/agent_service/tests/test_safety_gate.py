import pytest
from app.safety_gate import check_safety, SafetyResult
from app.context import RequestContext


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


def test_safe_message(ctx):
    result = check_safety("How's my training going?", ctx)
    assert result.needs_confirmation is False


def test_delete_triggers_confirmation(ctx):
    result = check_safety("delete my routine", ctx)
    assert result.needs_confirmation is True


def test_remove_triggers_confirmation(ctx):
    result = check_safety("remove all my data", ctx)
    assert result.needs_confirmation is True


def test_clear_triggers_confirmation(ctx):
    result = check_safety("clear my workout history", ctx)
    assert result.needs_confirmation is True


def test_reset_triggers_confirmation(ctx):
    result = check_safety("reset everything", ctx)
    assert result.needs_confirmation is True


def test_reason_includes_keyword(ctx):
    result = check_safety("please delete this", ctx)
    assert result.needs_confirmation is True
    assert "delete" in result.reason


def test_safe_message_has_no_reason(ctx):
    result = check_safety("Show me my bench press progress", ctx)
    assert result.needs_confirmation is False
    assert result.reason is None


def test_case_insensitive(ctx):
    result = check_safety("DELETE my routine", ctx)
    assert result.needs_confirmation is True
