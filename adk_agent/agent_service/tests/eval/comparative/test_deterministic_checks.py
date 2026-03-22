# test_deterministic_checks.py
from comparative.deterministic_checks import run_checks

def test_tool_name_leak():
    issues, penalty = run_checks(
        "I used tool_get_exercise_progress to check.", ["get_exercise_progress"]
    )
    assert any("tool name" in i.lower() for i in issues)
    assert penalty >= 20

def test_hallucinated_user_data_no_tools():
    issues, penalty = run_checks(
        "Your e1RM is 120kg, up from 115kg last week.", []
    )
    assert any("user-specific" in i.lower() for i in issues)
    assert penalty >= 30

def test_generic_advice_not_flagged():
    """Generic coaching advice with numbers should NOT trigger hallucination check."""
    issues, penalty = run_checks(
        "Aim for 3 sets of 8-12 reps at around 60-70kg to start.", []
    )
    assert not any("user-specific" in i.lower() for i in issues)

def test_clean_response():
    issues, penalty = run_checks(
        "Your bench is progressing well based on recent data.", ["get_exercise_progress"]
    )
    assert issues == []
    assert penalty == 0

def test_document_id_exposure():
    issues, penalty = run_checks(
        "Exercise K21gndDYgWE25mFmPamH is bench press.", ["search_exercises"]
    )
    assert any("id" in i.lower() for i in issues)
    assert penalty >= 25

def test_empty_response():
    issues, penalty = run_checks("", [])
    assert any("empty" in i.lower() for i in issues)
    assert penalty >= 30
