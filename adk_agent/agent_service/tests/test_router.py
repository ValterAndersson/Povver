# tests/test_router.py
import pytest
from app.router import route_request, Lane


def test_fast_lane_log_set():
    assert route_request("log 8 reps at 100kg") == Lane.FAST


def test_fast_lane_shorthand():
    assert route_request("8@100") == Lane.FAST


def test_fast_lane_done():
    assert route_request("done") == Lane.FAST


def test_fast_lane_next_set():
    assert route_request("next set") == Lane.FAST


def test_fast_lane_rest():
    assert route_request("rest") == Lane.FAST


def test_slow_lane_general():
    assert route_request("How's my training going?") == Lane.SLOW


def test_slow_lane_routine_creation():
    assert route_request("Create me a push pull legs routine") == Lane.SLOW


def test_functional_lane_json():
    assert route_request({"intent": "SWAP_EXERCISE"}) == Lane.FUNCTIONAL


def test_functional_lane_autofill():
    assert route_request({"intent": "AUTOFILL_SET"}) == Lane.FUNCTIONAL


def test_unknown_dict_goes_slow():
    assert route_request({"intent": "UNKNOWN_THING"}) == Lane.SLOW


def test_dict_with_message_routes_as_text():
    assert route_request({"message": "done"}) == Lane.FAST
