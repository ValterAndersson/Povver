"""LLM-as-Judge — 6-dimension comparative scorer using Claude Opus."""
from __future__ import annotations

import json
import logging
import re
from typing import Optional, Union

from anthropic import AsyncAnthropicVertex

from comparative.models import ComparisonVerdict, DimensionScore
from comparative.test_cases import MultiTurnCase, SingleTurnCase

logger = logging.getLogger(__name__)

# Vertex AI config — uses ADC for auth (no API key needed)
VERTEX_PROJECT_ID = "sm-team-engineering"
VERTEX_REGION = "us-east5"

JUDGE_MODEL = "claude-opus-4-6"

DIMENSION_WEIGHTS = {
    "correctness": 0.25,
    "safety": 0.20,
    "understanding": 0.20,
    "helpfulness": 0.15,
    "response_craft": 0.10,
    "persona": 0.10,
}

# Full judge prompt template (from spec)
SINGLE_TURN_PROMPT = """You are evaluating two AI fitness coaching systems on the same user query.

System A ("Gemini Agent"): A fully engineered coaching agent with a 733-line
system prompt defining a hypertrophy coaching persona, pre-loaded context
(user memories, conversation history, training snapshot, active alerts),
keyword-based tool planning, and 31 tools including workout mutation.

System B ("Claude MCP"): A raw language model (Sonnet 4.6) with no system
prompt, no pre-loaded context, and 17 MCP tools for reading/writing training
data. It must discover context by calling tools itself.

Your job is NOT to pick a winner. Your job is to understand WHAT CAUSED
the difference in quality, so the engineering team knows where to invest.

## Context Attribution Guidance

When one system outperforms the other, determine the root cause:
- If System A references data that System B did not fetch, check whether
  System B had tools available to fetch that data but chose not to. If so,
  this is a model reasoning difference, not an engineering advantage.
- If System A references data from pre-loaded context (memories, alerts,
  conversation history) that System B could NOT access via its tools,
  this is an engineering advantage (context loading).
- If System A's response follows a specific format or constraint from its
  coaching prompt, evaluate whether that constraint helped or hurt quality.
- If System B produces a better response despite having no instructions,
  this indicates the engineering is actively constraining quality.

## Test Case
- Query: {query}
- Category: {category}
- Expected behavior: {expected_behavior}
- Gold standard: {gold_standard}
- Expected tools (System A): {expected_tools_gemini}
- Expected tools (System B): {expected_tools_claude}

## System A Response (Gemini Agent)
Tools used: {gemini_tools}
```
{gemini_response}
```

## System B Response (Claude MCP)
Tools used: {claude_tools}
```
{claude_response}
```

## Instructions

1. Score EACH system on 6 dimensions (0-100) with sub-scores and issues.
2. Determine the winner, margin, and engineering attribution.
3. Be specific in attribution — name the engineering component
   (prompt rule, context loading, planner, safety gate, persona constraint,
   tool guidance, conciseness rule) and explain how it helped or hurt.
4. For tool_selection scoring: score based on "Tools Actually Used" matching
   "Expected Tools" for each system. Different tool names are expected.

Respond with ONLY valid JSON matching this schema:
{{
  "system_a": {{
    "correctness": {{"score": N, "tool_selection": N, "data_accuracy": N, "completeness": N, "issues": []}},
    "safety": {{"score": N, "no_hallucination": N, "no_id_leak": N, "medical_appropriate": N, "issues": []}},
    "understanding": {{"score": N, "intent_detection": N, "subtext_recognition": N, "scope_judgment": N, "issues": []}},
    "helpfulness": {{"score": N, "actionability": N, "moves_forward": N, "user_empowerment": N, "issues": []}},
    "response_craft": {{"score": N, "structure": N, "length_appropriate": N, "readability": N, "issues": []}},
    "persona": {{"score": N, "tone_appropriate": N, "no_over_coaching": N, "issues": []}}
  }},
  "system_b": {{...same structure...}},
  "coherence": null,
  "comparison": {{
    "winner": "gemini | claude | tie",
    "margin": "decisive | slight | negligible",
    "engineering_attribution": {{
      "helped": ["specific observation"],
      "hurt": ["specific observation"],
      "irrelevant": ["specific observation"]
    }},
    "raw_reasoning_advantage": "observation or null",
    "key_insight": "one sentence"
  }}
}}"""


def build_judge_prompt(
    case: Union[SingleTurnCase, MultiTurnCase],
    gemini_response: str,
    gemini_tools: list[str],
    claude_response: str,
    claude_tools: list[str],
    gemini_turns: list | None = None,
    claude_turns: list | None = None,
) -> str:
    """Build the judge prompt for a single case."""
    if isinstance(case, MultiTurnCase) and gemini_turns and claude_turns:
        return _build_multi_turn_prompt(case, gemini_turns, claude_turns)

    return SINGLE_TURN_PROMPT.format(
        query=case.query,
        category=case.category,
        expected_behavior=case.expected_behavior if isinstance(case, SingleTurnCase) else case.overall_expected_behavior,
        gold_standard=case.gold_standard,
        expected_tools_gemini=", ".join(case.expected_tools_gemini) or "(none)",
        expected_tools_claude=", ".join(case.expected_tools_claude) or "(none)",
        gemini_tools=", ".join(gemini_tools) or "(none)",
        gemini_response=gemini_response,
        claude_tools=", ".join(claude_tools) or "(none)",
        claude_response=claude_response,
    )


def _build_multi_turn_prompt(
    case: MultiTurnCase,
    gemini_turns: list,
    claude_turns: list,
) -> str:
    """Build judge prompt for multi-turn case with conversation transcript."""
    transcript = ""
    for i, turn in enumerate(case.turns):
        gt = gemini_turns[i] if i < len(gemini_turns) else None
        ct = claude_turns[i] if i < len(claude_turns) else None
        transcript += f"\n### Turn {i + 1}\n"
        transcript += f"User: {turn.query}\n"
        transcript += f"Expected: {turn.expected_behavior}\n"
        if gt:
            transcript += f"System A: {gt.response_text} (tools: {', '.join(gt.tools_used) or 'none'})\n"
        if ct:
            transcript += f"System B: {ct.response_text} (tools: {', '.join(ct.tools_used) or 'none'})\n"

    # Reuse the single-turn prompt structure but replace the response section
    # with the transcript and add coherence scoring instruction
    prompt = SINGLE_TURN_PROMPT.format(
        query=case.query + " (multi-turn — see transcript below)",
        category=case.category,
        expected_behavior=case.overall_expected_behavior,
        gold_standard=case.gold_standard,
        expected_tools_gemini=", ".join(case.expected_tools_gemini) or "(none)",
        expected_tools_claude=", ".join(case.expected_tools_claude) or "(none)",
        gemini_tools="(see transcript)",
        gemini_response="(see transcript below)",
        claude_tools="(see transcript)",
        claude_response="(see transcript below)",
    )
    prompt += f"\n\n## Conversation Transcript\n{transcript}"
    prompt += '\n\nIMPORTANT: Populate the "coherence" field with {{"system_a": N, "system_b": N}} (0-100 each). Evaluate context carry, no repetition, and building on prior turns.'
    # Replace the null coherence in the schema hint
    prompt = prompt.replace('"coherence": null', '"coherence": {"system_a": N, "system_b": N}')
    return prompt


def parse_judge_response(
    raw_text: str,
) -> tuple[dict[str, DimensionScore], dict[str, DimensionScore], ComparisonVerdict, dict | None]:
    """Parse judge JSON into structured scores."""
    # Strip markdown fences
    text = raw_text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)

    # Strip trailing commas before } or ] (common LLM JSON error)
    text = re.sub(r",\s*([}\]])", r"\1", text)

    # Try direct parse, then extract JSON object
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", text)
        if not match:
            raise ValueError(f"Could not parse judge response: {text[:200]}")
        data = json.loads(match.group())

    def extract_dimensions(system_data: dict) -> dict[str, DimensionScore]:
        dims = {}
        for dim_name, weight in DIMENSION_WEIGHTS.items():
            d = system_data.get(dim_name, {})
            score = d.get("score", 50)
            issues = d.get("issues", [])
            sub_scores = {k: v for k, v in d.items() if k not in ("score", "issues") and isinstance(v, (int, float))}
            dims[dim_name] = DimensionScore(score=score, weight=weight, sub_scores=sub_scores, issues=issues)
        return dims

    gemini_dims = extract_dimensions(data.get("system_a", {}))
    claude_dims = extract_dimensions(data.get("system_b", {}))

    comp_data = data.get("comparison", {})
    comparison = ComparisonVerdict(
        winner=comp_data.get("winner", "tie"),
        margin=comp_data.get("margin", "negligible"),
        engineering_attribution=comp_data.get("engineering_attribution", {"helped": [], "hurt": [], "irrelevant": []}),
        raw_reasoning_advantage=comp_data.get("raw_reasoning_advantage"),
        key_insight=comp_data.get("key_insight", ""),
    )

    coherence = data.get("coherence")

    return gemini_dims, claude_dims, comparison, coherence


async def judge_case(
    case: Union[SingleTurnCase, MultiTurnCase],
    gemini_response: str,
    gemini_tools: list[str],
    claude_response: str,
    claude_tools: list[str],
    gemini_turns: list | None = None,
    claude_turns: list | None = None,
) -> tuple[dict[str, DimensionScore], dict[str, DimensionScore], ComparisonVerdict, dict | None]:
    """Run the LLM judge on a single case."""
    prompt = build_judge_prompt(
        case, gemini_response, gemini_tools,
        claude_response, claude_tools,
        gemini_turns, claude_turns,
    )

    client = AsyncAnthropicVertex(
        project_id=VERTEX_PROJECT_ID,
        region=VERTEX_REGION,
    )
    resp = await client.messages.create(
        model=JUDGE_MODEL,
        max_tokens=4096,
        temperature=0.1,
        messages=[{"role": "user", "content": prompt}],
    )

    raw = resp.content[0].text
    return parse_judge_response(raw)
