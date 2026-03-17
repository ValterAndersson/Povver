# app/llm/protocol.py
"""LLM client abstraction — model-agnostic interface."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Protocol, runtime_checkable


@dataclass
class ToolCallChunk:
    call_id: str
    tool_name: str
    args: dict[str, Any]


@dataclass
class LLMChunk:
    text: str | None = None
    tool_call: ToolCallChunk | None = None
    usage: dict | None = None  # {"input_tokens": N, "output_tokens": N} — set on final chunk

    @property
    def is_text(self) -> bool:
        return self.text is not None

    @property
    def is_tool_call(self) -> bool:
        return self.tool_call is not None


@dataclass
class ModelConfig:
    temperature: float = 0.3
    max_output_tokens: int = 8192
    max_context_tokens: int = 1_000_000
    json_mode: bool = False


@dataclass
class ToolDef:
    """Tool definition for the LLM."""
    name: str
    description: str
    parameters: dict[str, Any]  # JSON Schema


@runtime_checkable
class LLMClient(Protocol):
    async def stream(
        self,
        model: str,
        messages: list[dict],
        tools: list[ToolDef] | None = None,
        config: ModelConfig | None = None,
    ) -> AsyncIterator[LLMChunk]: ...
