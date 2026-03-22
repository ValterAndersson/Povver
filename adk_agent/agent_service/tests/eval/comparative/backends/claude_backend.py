# claude_backend.py
"""Claude backend — Anthropic Messages API + MCP tool execution."""
from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Union

import httpx
from anthropic import AsyncAnthropicVertex

from comparative.backends.tool_definitions import MCP_TOOLS
from comparative.models import BackendResponse, TurnResponse
from comparative.test_cases import MultiTurnCase, SingleTurnCase

logger = logging.getLogger(__name__)

AnyCase = Union[SingleTurnCase, MultiTurnCase]
MAX_TOOL_ROUNDS = 12

# Vertex AI config — uses ADC for auth (no API key needed)
VERTEX_PROJECT_ID = "sm-team-engineering"
VERTEX_REGION = "us-east5"


async def execute_mcp_tool(
    mcp_url: str,
    api_key: str,
    tool_name: str,
    arguments: dict,
) -> str:
    """Execute a tool against the MCP server via JSON-RPC over HTTP."""
    payload = {
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments},
        "id": 1,
    }
    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            mcp_url,
            json=payload,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
        )
        resp.raise_for_status()

        # MCP StreamableHTTP returns SSE — parse "data:" lines for JSON-RPC response
        raw = resp.text
        data = None
        for line in raw.splitlines():
            if line.startswith("data: "):
                try:
                    data = json.loads(line[6:])
                    break
                except json.JSONDecodeError:
                    continue
        if data is None:
            # Fallback: try parsing entire response as JSON
            data = resp.json()

    if "error" in data:
        return json.dumps({"error": data["error"].get("message", "Tool error")})

    result = data.get("result", {})
    content = result.get("content", [])
    # MCP tool results are content blocks — extract text
    texts = [c.get("text", "") for c in content if c.get("type") == "text"]
    return "\n".join(texts) if texts else json.dumps(result)


class ClaudeBackend:
    """Eval backend for Claude Sonnet via Vertex AI + MCP tools."""

    def __init__(
        self,
        mcp_url: str,
        mcp_api_key: str,
        model: str = "claude-sonnet-4-6",
        temperature: float = 0.3,
    ):
        self.client = AsyncAnthropicVertex(
            project_id=VERTEX_PROJECT_ID,
            region=VERTEX_REGION,
        )
        self.mcp_url = mcp_url
        self.mcp_api_key = mcp_api_key
        self.model = model
        self.temperature = temperature

    @property
    def name(self) -> str:
        return "claude"

    async def run_case(self, case: AnyCase, user_id: str) -> BackendResponse:
        if isinstance(case, MultiTurnCase):
            return await self._run_multi_turn(case, user_id)
        resp, _ = await self._run_single_query(case.query, user_id)
        return resp

    async def _run_single_query(
        self,
        query: str,
        user_id: str,
        messages: list[dict] | None = None,
    ) -> tuple[BackendResponse, list[dict]]:
        """Run a single query. Returns (response, updated_messages).

        The caller owns the messages list for multi-turn. This method
        appends the user message, all tool-use rounds, and the final
        assistant response to the list, then returns it.
        """
        if messages is None:
            messages = []
        messages.append({"role": "user", "content": query})

        tools_used: list[str] = []
        total_input_tokens = 0
        total_output_tokens = 0
        start = time.monotonic()
        final_text = ""

        for _ in range(MAX_TOOL_ROUNDS):
            resp = await self.client.messages.create(
                model=self.model,
                max_tokens=4096,
                temperature=self.temperature,
                tools=MCP_TOOLS,
                messages=messages,
            )

            # Track token usage
            if resp.usage:
                total_input_tokens += resp.usage.input_tokens
                total_output_tokens += resp.usage.output_tokens

            # Collect text and tool_use blocks
            text_parts = []
            tool_calls = []
            for block in resp.content:
                if block.type == "text":
                    text_parts.append(block.text)
                elif block.type == "tool_use":
                    tool_calls.append(block)
                    if block.name not in tools_used:
                        tools_used.append(block.name)

            final_text = "".join(text_parts)

            if resp.stop_reason != "tool_use" or not tool_calls:
                # Done — append final assistant message and break
                messages.append({"role": "assistant", "content": resp.content})
                break

            # Execute tool calls and continue the agentic loop
            messages.append({"role": "assistant", "content": resp.content})
            tool_results = []
            for tc in tool_calls:
                try:
                    result = await execute_mcp_tool(
                        self.mcp_url, self.mcp_api_key, tc.name, tc.input,
                    )
                except Exception as e:
                    result = json.dumps({"error": str(e)})
                    logger.warning("Tool %s failed: %s", tc.name, e)

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tc.id,
                    "content": result,
                })
            messages.append({"role": "user", "content": tool_results})

        duration = int((time.monotonic() - start) * 1000)
        return BackendResponse(
            response_text=final_text,
            tools_used=tools_used,
            duration_ms=duration,
            input_tokens=total_input_tokens,
            output_tokens=total_output_tokens,
        ), messages

    async def _run_multi_turn(self, case: MultiTurnCase, user_id: str) -> BackendResponse:
        messages: list[dict] = []
        turn_responses: list[TurnResponse] = []
        all_tools: list[str] = []
        start = time.monotonic()

        for turn in case.turns:
            resp, messages = await self._run_single_query(turn.query, user_id, messages)
            turn_responses.append(TurnResponse(
                response_text=resp.response_text,
                tools_used=resp.tools_used,
            ))
            all_tools.extend(t for t in resp.tools_used if t not in all_tools)
            # messages already contains the full conversation history
            # including user message, tool rounds, and final assistant response

        duration = int((time.monotonic() - start) * 1000)
        return BackendResponse(
            response_text=turn_responses[-1].response_text,
            tools_used=all_tools,
            duration_ms=duration,
            turn_responses=turn_responses,
        )
