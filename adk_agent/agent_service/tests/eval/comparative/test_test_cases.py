"""Tests for the test case registry."""
from comparative.test_cases import (
    ALL_CASES,
    CASES_BY_ID,
    get_cases,
    SingleTurnCase,
    MultiTurnCase,
)


def test_total_case_count():
    assert len(ALL_CASES) == 40


def test_category_counts():
    curated = get_cases(category="curated")
    ambiguity = get_cases(category="ambiguity")
    multi_turn = get_cases(category="multi_turn")
    structure = get_cases(category="structure")
    assert len(curated) == 15
    assert len(ambiguity) == 10
    assert len(multi_turn) == 10
    assert len(structure) == 5


def test_multi_turn_cases_have_turns():
    mt = get_cases(category="multi_turn")
    for case in mt:
        assert isinstance(case, MultiTurnCase)
        assert len(case.turns) == 3


def test_all_cases_have_gold_standard():
    for case in ALL_CASES:
        assert case.gold_standard, f"{case.id} missing gold_standard"


def test_case_lookup_by_id():
    case = CASES_BY_ID.get("cur_001")
    assert case is not None
    assert "workout" in case.query.lower()


def test_curated_cases_are_single_turn():
    curated = get_cases(category="curated")
    for case in curated:
        assert isinstance(case, SingleTurnCase)


def test_ambiguity_cases_are_single_turn():
    ambiguity = get_cases(category="ambiguity")
    for case in ambiguity:
        assert isinstance(case, SingleTurnCase)


def test_structure_cases_are_single_turn():
    structure = get_cases(category="structure")
    for case in structure:
        assert isinstance(case, SingleTurnCase)


def test_all_ids_unique():
    ids = [c.id for c in ALL_CASES]
    assert len(ids) == len(set(ids)), "Duplicate case IDs found"


def test_get_cases_by_id():
    result = get_cases(case_id="amb_003")
    assert len(result) == 1
    assert result[0].id == "amb_003"


def test_get_cases_by_id_missing():
    result = get_cases(case_id="nonexistent")
    assert result == []


def test_get_cases_by_tags():
    emotional = get_cases(tags=["emotional"])
    assert len(emotional) >= 2  # amb_001, amb_006, conv_008 at least
    for case in emotional:
        assert "emotional" in case.tags


def test_multi_turn_query_property():
    """MultiTurnCase.query returns the first turn's query."""
    mt = get_cases(category="multi_turn")
    for case in mt:
        assert case.query == case.turns[0].query
