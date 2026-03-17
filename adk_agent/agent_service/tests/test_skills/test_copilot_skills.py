# tests/test_skills/test_copilot_skills.py
"""Tests for copilot_skills — Fast Lane HTTP skills."""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from app.context import RequestContext
from app.skills.copilot_skills import (
    get_next_set,
    log_set,
    log_set_shorthand,
    parse_shorthand,
)


def _run(coro):
    return asyncio.run(coro)


def _ctx(**overrides):
    defaults = {
        "user_id": "u1",
        "conversation_id": "c1",
        "correlation_id": "r1",
        "workout_id": "w1",
        "workout_mode": True,
    }
    defaults.update(overrides)
    return RequestContext(**defaults)


def _mock_httpx_client(*, response_json=None, status_code=200):
    """Build a mock httpx.AsyncClient context manager."""
    mock_resp = MagicMock()
    mock_resp.json.return_value = response_json or {"ok": True}
    mock_resp.status_code = status_code
    mock_resp.raise_for_status = MagicMock()

    mock_client = AsyncMock()
    mock_client.post.return_value = mock_resp
    mock_client.get.return_value = mock_resp

    mock_cls = MagicMock()
    mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
    return mock_cls, mock_client


def test_log_set_posts_correct_payload():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"success": True, "totals": {"sets": 3}}
        )
        with patch("app.skills.copilot_skills.httpx.AsyncClient", mock_cls):
            result = await log_set(
                ctx=_ctx(),
                exercise_instance_id="ex1",
                set_id="s1",
                reps=8,
                weight_kg=100.0,
                rir=1,
            )
            assert result["success"] is True

            # Verify the POST payload
            call_args = mock_client.post.call_args
            payload = call_args.kwargs.get("json") or call_args[1].get("json")
            assert payload["workout_id"] == "w1"
            assert payload["exercise_instance_id"] == "ex1"
            assert payload["set_id"] == "s1"
            assert payload["values"]["reps"] == 8
            assert payload["values"]["weight"] == 100.0
            assert payload["values"]["rir"] == 1
            assert "idempotency_key" in payload

    _run(_test())


def test_log_set_shorthand_calls_complete_current_set():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"success": True, "data": {"reps": 8, "weight": 100}}
        )
        with patch("app.skills.copilot_skills.httpx.AsyncClient", mock_cls):
            result = await log_set_shorthand(ctx=_ctx(), reps=8, weight_kg=100.0)
            assert result["success"] is True

            call_args = mock_client.post.call_args
            url = call_args.args[0] if call_args.args else call_args[0][0]
            assert "completeCurrentSet" in url

    _run(_test())


def test_get_next_set_calls_get_active_workout():
    async def _test():
        workout_data = {
            "success": True,
            "workout": {
                "exercises": [
                    {
                        "name": "Bench Press",
                        "exercise_id": "bp1",
                        "sets": [
                            {"id": "s1", "status": "done", "weight": 100, "reps": 8},
                            {"id": "s2", "status": "planned", "weight": 100},
                        ],
                    }
                ]
            },
        }
        mock_cls, mock_client = _mock_httpx_client(response_json=workout_data)
        with patch("app.skills.copilot_skills.httpx.AsyncClient", mock_cls):
            result = await get_next_set(ctx=_ctx())
            assert result["success"] is True

            call_args = mock_client.get.call_args
            url = call_args.args[0] if call_args.args else call_args[0][0]
            assert "getActiveWorkout" in url

    _run(_test())


def test_get_next_set_passes_user_headers():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(response_json={"success": True})
        with patch("app.skills.copilot_skills.httpx.AsyncClient", mock_cls):
            await get_next_set(ctx=_ctx())
            call_args = mock_client.get.call_args
            headers = call_args.kwargs.get("headers") or call_args[1].get("headers")
            assert headers["x-user-id"] == "u1"

    _run(_test())


def test_parse_shorthand_kg():
    result = parse_shorthand("8@100")
    assert result == {"reps": 8, "weight": 100.0, "unit": "kg"}


def test_parse_shorthand_lbs():
    result = parse_shorthand("5 @ 225lbs")
    assert result == {"reps": 5, "weight": 225.0, "unit": "lbs"}


def test_parse_shorthand_no_match():
    assert parse_shorthand("hello world") is None
