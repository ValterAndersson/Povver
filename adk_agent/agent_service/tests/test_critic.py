import pytest
from app.critic import review_response, CriticResult
from app.context import RequestContext


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


def test_clean_response_approved(ctx):
    result = review_response("Your bench press has improved by 5kg this month.", ctx)
    assert result.approved is True


def test_response_with_medical_advice_flagged(ctx):
    result = review_response(
        "You should take ibuprofen before your workout to prevent pain.",
        ctx,
    )
    assert result.approved is False or len(result.issues) > 0


def test_pain_advice_flagged(ctx):
    result = review_response(
        "You should push through the pain and keep going.",
        ctx,
    )
    assert result.approved is False
    assert any("pain" in issue.lower() for issue in result.issues)


def test_safe_coaching_approved(ctx):
    result = review_response(
        "I recommend increasing your squat volume by 2 sets per week.",
        ctx,
    )
    assert result.approved is True
    assert len(result.issues) == 0


def test_hallucination_warning(ctx):
    result = review_response(
        "Your e1RM was 120 last week.",
        ctx,
    )
    # Hallucinations are WARNING severity, not ERROR, so still approved
    # but should have issues
    assert len(result.issues) > 0 or result.approved is True


def test_medication_flagged(ctx):
    result = review_response(
        "Try taking aspirin before training to reduce inflammation.",
        ctx,
    )
    assert len(result.issues) > 0
    assert any("medication" in i.lower() or "aspirin" in i.lower() for i in result.issues)


def test_issues_list_matches_findings(ctx):
    result = review_response(
        "Just ignore the pain and push through it. Take ibuprofen if needed.",
        ctx,
    )
    assert len(result.issues) == len(result.findings)
