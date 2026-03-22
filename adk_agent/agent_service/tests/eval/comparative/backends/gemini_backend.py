# gemini_backend.py
"""Gemini agent service backend — sends requests to /stream, parses SSE."""
from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Union

import httpx

from comparative.models import BackendResponse, TurnResponse
from comparative.test_cases import MultiTurnCase, SingleTurnCase

logger = logging.getLogger(__name__)

AnyCase = Union[SingleTurnCase, MultiTurnCase]


def parse_sse_events(lines: list[str]) -> tuple[str, list[str]]:
    """Parse SSE lines into (response_text, tools_used)."""
    text_parts: list[str] = []
    tools: list[str] = []
    error_msg: str | None = None

    for line in lines:
        if not line.startswith("data: "):
            continue
        try:
            evt = json.loads(line[6:])
        except json.JSONDecodeError:
            continue

        evt_type = evt.get("type")
        if evt_type == "message":
            text_parts.append(evt.get("text", ""))
        elif evt_type == "tool_start":
            tool = evt.get("tool", "")
            if tool and tool not in tools:
                tools.append(tool)
        elif evt_type == "error":
            error_msg = evt.get("message", "Unknown error")
        elif evt_type == "done":
            break

    text = "".join(text_parts) if text_parts else (error_msg or "")
    return text, tools


class GeminiBackend:
    """Eval backend for the Gemini agent service.

    auth_token: Cloud Run IAM identity token (from gcloud auth print-identity-token).
    Only needed if the service requires IAM auth. Pass None for unauthenticated.
    """

    def __init__(self, base_url: str, auth_token: str | None = None):
        self.base_url = base_url.rstrip("/")
        self.auth_token = auth_token

    @property
    def name(self) -> str:
        return "gemini"

    async def run_case(self, case: AnyCase, user_id: str) -> BackendResponse:
        if isinstance(case, MultiTurnCase):
            return await self._run_multi_turn(case, user_id)
        return await self._run_single(case.query, user_id)

    async def _run_single(
        self, query: str, user_id: str, conversation_id: str | None = None
    ) -> BackendResponse:
        conv_id = conversation_id or str(uuid.uuid4())
        start = time.monotonic()

        async with httpx.AsyncClient(timeout=180) as client:
            async with client.stream(
                "POST",
                f"{self.base_url}/stream",
                json={
                    "user_id": user_id,
                    "conversation_id": conv_id,
                    "message": query,
                },
                headers={"Authorization": f"Bearer {self.auth_token}"} if self.auth_token else {},
            ) as resp:
                resp.raise_for_status()
                lines = []
                async for line in resp.aiter_lines():
                    lines.append(line)

        text, tools = parse_sse_events(lines)
        duration = int((time.monotonic() - start) * 1000)
        return BackendResponse(
            response_text=text,
            tools_used=tools,
            duration_ms=duration,
        )

    async def _run_multi_turn(self, case: MultiTurnCase, user_id: str) -> BackendResponse:
        conv_id = str(uuid.uuid4())
        turn_responses: list[TurnResponse] = []
        all_tools: list[str] = []
        start = time.monotonic()

        for turn in case.turns:
            resp = await self._run_single(turn.query, user_id, conv_id)
            turn_responses.append(TurnResponse(
                response_text=resp.response_text,
                tools_used=resp.tools_used,
            ))
            all_tools.extend(t for t in resp.tools_used if t not in all_tools)

        duration = int((time.monotonic() - start) * 1000)
        return BackendResponse(
            response_text=turn_responses[-1].response_text,
            tools_used=all_tools,
            duration_ms=duration,
            turn_responses=turn_responses,
        )
