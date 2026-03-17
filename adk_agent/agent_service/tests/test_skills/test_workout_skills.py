# tests/test_skills/test_workout_skills.py
"""Tests for workout_skills — LLM-directed workout operations."""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from app.context import RequestContext
from app.skills.workout_skills import (
    add_exercise,
    complete_workout,
    get_workout_state,
    prescribe_set,
    swap_exercise,
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


def test_get_workout_state():
    async def _test():
        workout = {"success": True, "workout": {"exercises": []}}
        mock_cls, mock_client = _mock_httpx_client(response_json=workout)
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            result = await get_workout_state(ctx=_ctx())
            assert result["success"] is True
            call_args = mock_client.get.call_args
            url = call_args.args[0] if call_args.args else call_args[0][0]
            assert "getActiveWorkout" in url

    _run(_test())


def test_swap_exercise():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"event_id": "ev1"}
        )
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            result = await swap_exercise(
                ctx=_ctx(),
                exercise_instance_id="ex1",
                new_exercise_id="ex2",
                new_exercise_name="Incline Press",
            )
            assert result["event_id"] == "ev1"
            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            assert payload["workout_id"] == "w1"
            assert payload["new_exercise_id"] == "ex2"

    _run(_test())


def test_add_exercise():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"success": True, "event_id": "ev2"}
        )
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            result = await add_exercise(
                ctx=_ctx(),
                exercise_id="lateral_raise",
                name="Lateral Raise",
                sets=4,
                reps=12,
                weight_kg=10.0,
            )
            assert result["success"] is True
            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            assert payload["name"] == "Lateral Raise"
            assert payload["sets"] == 4

    _run(_test())


def test_prescribe_set_weight_only():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"success": True}
        )
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            result = await prescribe_set(
                ctx=_ctx(),
                exercise_instance_id="ex1",
                set_id="s2",
                weight_kg=85.0,
            )
            assert result["success"] is True
            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            assert payload["weight_kg"] == 85.0
            assert "reps" not in payload

    _run(_test())


def test_prescribe_set_reps_only():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"success": True}
        )
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            result = await prescribe_set(
                ctx=_ctx(),
                exercise_instance_id="ex1",
                set_id="s2",
                reps=6,
            )
            assert result["success"] is True
            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            assert payload["reps"] == 6
            assert "weight_kg" not in payload

    _run(_test())


def test_complete_workout():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"workout_id": "w1", "archived": True}
        )
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            result = await complete_workout(ctx=_ctx())
            assert result["archived"] is True
            url = mock_client.post.call_args.args[0] if mock_client.post.call_args.args else mock_client.post.call_args[0][0]
            assert "completeActiveWorkout" in url

    _run(_test())


def test_headers_include_user_id():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client()
        with patch("app.skills.workout_skills.httpx.AsyncClient", mock_cls):
            await get_workout_state(ctx=_ctx(user_id="user42"))
            headers = mock_client.get.call_args.kwargs.get("headers") or mock_client.get.call_args[1].get("headers")
            assert headers["x-user-id"] == "user42"

    _run(_test())
