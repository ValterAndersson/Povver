# app/llm/gemini.py
"""Gemini LLM client using google-genai SDK."""

from __future__ import annotations

import logging
import os
from typing import Any, AsyncIterator

from google import genai
from google.genai import types

from app.llm.protocol import LLMChunk, LLMClient, ModelConfig, ToolCallChunk, ToolDef

logger = logging.getLogger(__name__)


class GeminiClient:
    """Gemini client implementing LLMClient protocol."""

    def __init__(self):
        self.client = genai.Client(
            vertexai=True,
            project=os.getenv("GOOGLE_CLOUD_PROJECT", "myon-53d85"),
            location=os.getenv("GOOGLE_CLOUD_LOCATION", "us-central1"),
        )

    async def stream(
        self,
        model: str,
        messages: list[dict],
        tools: list[ToolDef] | None = None,
        config: ModelConfig | None = None,
    ) -> AsyncIterator[LLMChunk]:
        config = config or ModelConfig()

        gemini_contents = self._to_gemini_contents(messages)
        gemini_tools = self._to_gemini_tools(tools) if tools else None
        system_instruction = self._extract_system_instruction(messages)

        gen_config = types.GenerateContentConfig(
            temperature=config.temperature,
            max_output_tokens=config.max_output_tokens,
            system_instruction=system_instruction,
            tools=gemini_tools,
            automatic_function_calling=types.AutomaticFunctionCallingConfig(
                disable=True,
            ),
        )

        async for response in await self.client.aio.models.generate_content_stream(
            model=model,
            contents=gemini_contents,
            config=gen_config,
        ):
            usage = None
            if hasattr(response, "usage_metadata") and response.usage_metadata:
                meta = response.usage_metadata
                usage = {
                    "input_tokens": getattr(meta, "prompt_token_count", 0) or 0,
                    "output_tokens": getattr(meta, "candidates_token_count", 0) or 0,
                    "thinking_tokens": getattr(meta, "thoughts_token_count", 0) or 0,
                }

            if not response.candidates or not response.candidates[0].content:
                continue
            for part in response.candidates[0].content.parts:
                if part.text:
                    yield LLMChunk(text=part.text, usage=usage)
                elif part.function_call:
                    yield LLMChunk(tool_call=ToolCallChunk(
                        call_id=part.function_call.id or part.function_call.name,
                        tool_name=part.function_call.name,
                        args=dict(part.function_call.args) if part.function_call.args else {},
                    ), usage=usage)

    def _extract_system_instruction(self, messages: list[dict]) -> str | None:
        for msg in messages:
            if msg["role"] == "system":
                return msg["content"]
        return None

    def _to_gemini_contents(self, messages: list[dict]) -> list:
        contents = []
        for msg in messages:
            role = msg["role"]
            if role == "system":
                continue
            gemini_role = "user" if role == "user" else "model"
            if "tool_result" in msg:
                contents.append(types.Content(
                    role="user",
                    parts=[types.Part(function_response=types.FunctionResponse(
                        name=msg["tool_name"],
                        response=msg["tool_result"],
                    ))],
                ))
            elif "tool_calls" in msg:
                # Model's function call response — reconstruct from history
                parts = []
                for tc in msg["tool_calls"]:
                    parts.append(types.Part(function_call=types.FunctionCall(
                        name=tc["name"],
                        args=tc.get("args", {}),
                    )))
                contents.append(types.Content(role="model", parts=parts))
            else:
                contents.append(types.Content(
                    role=gemini_role,
                    parts=[types.Part(text=msg["content"])],
                ))
        return contents

    def _to_gemini_tools(self, tools: list[ToolDef]) -> list:
        declarations = []
        for tool in tools:
            # Convert JSON Schema dict to Gemini Schema format
            schema = self._json_schema_to_gemini(tool.parameters) if tool.parameters else None
            declarations.append(types.FunctionDeclaration(
                name=tool.name,
                description=tool.description,
                parameters=schema,
            ))
        return [types.Tool(function_declarations=declarations)]

    def _json_schema_to_gemini(self, schema: dict) -> types.Schema:
        """Convert a JSON Schema dict to a Gemini types.Schema.

        The google-genai SDK requires types.Schema objects, not raw dicts.
        Supports: object with properties, string, integer, number, boolean, array.
        """
        schema_type = schema.get("type", "object").upper()
        type_map = {
            "STRING": types.Type.STRING,
            "INTEGER": types.Type.INTEGER,
            "NUMBER": types.Type.NUMBER,
            "BOOLEAN": types.Type.BOOLEAN,
            "ARRAY": types.Type.ARRAY,
            "OBJECT": types.Type.OBJECT,
        }
        gemini_type = type_map.get(schema_type, types.Type.OBJECT)

        properties = {}
        if "properties" in schema:
            for prop_name, prop_schema in schema["properties"].items():
                properties[prop_name] = self._json_schema_to_gemini(prop_schema)

        items = None
        if "items" in schema:
            items = self._json_schema_to_gemini(schema["items"])

        enum = schema.get("enum")

        return types.Schema(
            type=gemini_type,
            description=schema.get("description"),
            properties=properties or None,
            required=schema.get("required") or None,
            items=items,
            enum=enum,
        )
