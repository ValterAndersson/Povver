import pytest
from app.planner import plan_tools
from app.context import RequestContext


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


def test_routine_request_suggests_planning(ctx):
    tools = plan_tools(
        "Create me a push pull legs routine",
        ctx,
        ["get_planning_context", "propose_routine", "search_exercises"],
    )
    assert "get_planning_context" in tools


def test_progress_question_suggests_analysis(ctx):
    tools = plan_tools(
        "How's my bench press progressing?",
        ctx,
        ["get_planning_context", "get_exercise_progress", "search_exercises"],
    )
    assert "get_exercise_progress" in tools or "get_planning_context" in tools


def test_unknown_intent_returns_empty(ctx):
    tools = plan_tools(
        "What's the weather like?",
        ctx,
        ["get_planning_context", "search_exercises"],
    )
    assert tools == []


def test_only_returns_available_tools(ctx):
    tools = plan_tools(
        "Create me a push pull legs routine",
        ctx,
        ["search_exercises"],  # propose_routine not available
    )
    assert "search_exercises" in tools
    assert "propose_routine" not in tools


def test_workout_creation_suggests_propose(ctx):
    tools = plan_tools(
        "Build me a chest workout",
        ctx,
        ["get_planning_context", "search_exercises", "propose_workout"],
    )
    assert "propose_workout" in tools


def test_swap_exercise_suggests_edit(ctx):
    tools = plan_tools(
        "Can you swap the bench press for something else?",
        ctx,
        ["get_planning_context", "get_template", "search_exercises", "propose_workout"],
    )
    assert len(tools) > 0
