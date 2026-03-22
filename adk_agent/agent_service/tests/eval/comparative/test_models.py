"""Tests for comparative eval data models."""
from comparative.models import BackendResponse, DimensionScore, CaseResult, SystemScores


def test_backend_response_creation():
    r = BackendResponse(
        response_text="Your bench is progressing well.",
        tools_used=["get_exercise_progress"],
        duration_ms=1200,
        error=None,
        turn_responses=None,
    )
    assert r.response_text == "Your bench is progressing well."
    assert r.tools_used == ["get_exercise_progress"]
    assert r.duration_ms == 1200


def test_dimension_score_weighted():
    d = DimensionScore(
        score=80,
        weight=0.25,
        sub_scores={"tool_selection": 35, "data_accuracy": 25, "completeness": 20},
        issues=[]
    )
    assert d.weighted_score == 20.0


def test_case_result_overall_score():
    dims = {
        "correctness": DimensionScore(score=80, weight=0.25, sub_scores={}, issues=[]),
        "safety": DimensionScore(score=90, weight=0.20, sub_scores={}, issues=[]),
        "understanding": DimensionScore(score=70, weight=0.20, sub_scores={}, issues=[]),
        "helpfulness": DimensionScore(score=60, weight=0.15, sub_scores={}, issues=[]),
        "response_craft": DimensionScore(score=75, weight=0.10, sub_scores={}, issues=[]),
        "persona": DimensionScore(score=85, weight=0.10, sub_scores={}, issues=[]),
    }
    system_scores = SystemScores(dimensions=dims)
    assert system_scores.overall == 77.0
