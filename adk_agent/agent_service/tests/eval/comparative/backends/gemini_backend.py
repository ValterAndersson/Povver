# gemini_backend.py
"""Gemini agent service backend — sends requests to /stream, parses SSE."""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from typing import Union

import httpx

from comparative.models import BackendResponse, TurnResponse
from comparative.test_cases import MultiTurnCase, SingleTurnCase

logger = logging.getLogger(__name__)

AnyCase = Union[SingleTurnCase, MultiTurnCase]


def parse_sse_events(lines: list[str]) -> tuple[str, list[str], dict]:
    """Parse SSE lines into (response_text, tools_used, usage)."""
    text_parts: list[str] = []
    tools: list[str] = []
    error_msg: str | None = None
    usage: dict = {"input_tokens": 0, "output_tokens": 0, "thinking_tokens": 0}

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
            done_usage = evt.get("usage")
            if done_usage:
                usage = done_usage
            break

    text = "".join(text_parts) if text_parts else (error_msg or "")
    return text, tools, usage


def _get_identity_token(target_audience: str) -> str:
    """Get a Cloud Run IAM identity token using GCP SA key."""
    from google.oauth2 import service_account
    import google.auth.transport.requests

    sa_key_path = os.environ.get("GCP_SA_KEY")
    if not sa_key_path:
        raise RuntimeError("GCP_SA_KEY env var must point to the GCP service account key file")
    creds = service_account.IDTokenCredentials.from_service_account_file(
        sa_key_path,
        target_audience=target_audience,
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


class GeminiBackend:
    """Eval backend for the Gemini agent service.

    Authenticates to Cloud Run using a GCP service account identity token
    derived from the $GCP_SA_KEY environment variable.
    """

    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self._token: str | None = None

    def _get_token(self) -> str:
        if self._token is None:
            self._token = _get_identity_token(self.base_url)
        return self._token

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
                headers={"Authorization": f"Bearer {self._get_token()}"},
            ) as resp:
                resp.raise_for_status()
                lines = []
                async for line in resp.aiter_lines():
                    lines.append(line)

        text, tools, usage = parse_sse_events(lines)
        duration = int((time.monotonic() - start) * 1000)
        return BackendResponse(
            response_text=text,
            tools_used=tools,
            duration_ms=duration,
            input_tokens=usage.get("input_tokens", 0),
            output_tokens=usage.get("output_tokens", 0),
            thinking_tokens=usage.get("thinking_tokens", 0),
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
