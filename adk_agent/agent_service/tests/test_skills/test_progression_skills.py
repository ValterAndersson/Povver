# tests/test_skills/test_progression_skills.py
"""Tests for progression_skills — background progression writes."""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from app.context import RequestContext
from app.skills.progression_skills import (
    apply_progression,
    suggest_deload,
    suggest_weight_increase,
)


def _run(coro):
    return asyncio.run(coro)


def _ctx(**overrides):
    defaults = {
        "user_id": "u1",
        "conversation_id": "c1",
        "correlation_id": "r1",
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

    mock_cls = MagicMock()
    mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
    return mock_cls, mock_client


def test_apply_progression_posts_correct_payload():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={
                "recommendationId": "rec1",
                "state": "applied",
                "applied": True,
            }
        )
        with patch("app.skills.progression_skills.httpx.AsyncClient", mock_cls):
            result = await apply_progression(
                ctx=_ctx(),
                target_type="template",
                target_id="t1",
                changes=[{"path": "exercises[0].sets[0].weight", "from": 80, "to": 85}],
                summary="Increase weight",
                rationale="Good form at RIR 0",
                trigger="post_workout",
            )
            assert result["recommendationId"] == "rec1"
            assert result["applied"] is True

            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            assert payload["userId"] == "u1"
            assert payload["targetType"] == "template"
            assert payload["targetId"] == "t1"
            assert len(payload["changes"]) == 1
            assert payload["autoApply"] is True

    _run(_test())


def test_apply_progression_uses_myon_api_key():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client()
        with patch("app.skills.progression_skills.httpx.AsyncClient", mock_cls):
            with patch("app.skills.progression_skills.MYON_API_KEY", "test-myon-key"):
                await apply_progression(
                    ctx=_ctx(),
                    target_type="template",
                    target_id="t1",
                    changes=[{"path": "x", "from": 1, "to": 2}],
                    summary="Test",
                    rationale="Test",
                )
                headers = mock_client.post.call_args.kwargs.get("headers") or mock_client.post.call_args[1].get("headers")
                assert headers["x-api-key"] == "test-myon-key"

    _run(_test())


def test_suggest_weight_increase_builds_changes():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"recommendationId": "rec2", "applied": True}
        )
        with patch("app.skills.progression_skills.httpx.AsyncClient", mock_cls):
            result = await suggest_weight_increase(
                ctx=_ctx(),
                template_id="t1",
                exercise_index=0,
                new_weight=85.0,
                rationale="All sets at RIR 0",
            )
            assert result["applied"] is True

            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            # Should generate changes for up to 4 sets
            assert len(payload["changes"]) == 4
            assert payload["changes"][0]["to"] == 85.0
            assert "Increase weight to 85.0kg" in payload["summary"]

    _run(_test())


def test_suggest_deload_calculates_60_percent():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"recommendationId": "rec3", "applied": True}
        )
        with patch("app.skills.progression_skills.httpx.AsyncClient", mock_cls):
            result = await suggest_deload(
                ctx=_ctx(),
                template_id="t1",
                exercise_index=1,
                current_weight=100.0,
                rationale="Plateau detected",
            )
            assert result["applied"] is True

            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            # 60% of 100 = 60.0
            assert payload["changes"][0]["to"] == 60.0
            assert payload["changes"][0]["from"] == 100.0
            assert "Deload to 60.0kg" in payload["summary"]

    _run(_test())


def test_apply_progression_auto_apply_false():
    async def _test():
        mock_cls, mock_client = _mock_httpx_client(
            response_json={"recommendationId": "rec4", "state": "pending_review", "applied": False}
        )
        with patch("app.skills.progression_skills.httpx.AsyncClient", mock_cls):
            result = await apply_progression(
                ctx=_ctx(),
                target_type="routine",
                target_id="r1",
                changes=[{"path": "x", "from": 1, "to": 2}],
                summary="Test",
                rationale="Test",
                auto_apply=False,
            )
            assert result["applied"] is False
            payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1].get("json")
            assert payload["autoApply"] is False

    _run(_test())
