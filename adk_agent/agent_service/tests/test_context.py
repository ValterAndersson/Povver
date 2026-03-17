# tests/test_context.py
import pytest
from app.context import RequestContext


def test_request_context_creation():
    ctx = RequestContext(
        user_id="user123",
        conversation_id="conv456",
        correlation_id="corr789",
    )
    assert ctx.user_id == "user123"
    assert ctx.conversation_id == "conv456"
    assert ctx.correlation_id == "corr789"
    assert ctx.workout_mode is False
    assert ctx.workout_id is None


def test_request_context_workout_mode():
    ctx = RequestContext(
        user_id="user123",
        conversation_id="conv456",
        correlation_id="corr789",
        workout_mode=True,
        workout_id="aw001",
    )
    assert ctx.workout_mode is True
    assert ctx.workout_id == "aw001"


def test_request_context_is_immutable():
    ctx = RequestContext(user_id="u", conversation_id="c", correlation_id="r")
    with pytest.raises(AttributeError):
        ctx.user_id = "other"
