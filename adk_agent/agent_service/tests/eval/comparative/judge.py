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

Both systems have access to tools for reading and writing training data.
They may differ in architecture, prompting, and tool availability, but you
should evaluate them PURELY on output quality — not on how they achieved it.

Your job is to score each system's response on 6 dimensions and determine
which response better serves the user.

## Test Case
- Query: {query}
- Category: {category}
- Expected behavior: {expected_behavior}
- Gold standard: {gold_standard}
- Expected tools (System A): {expected_tools_a}
- Expected tools (System B): {expected_tools_b}

## System A Response
Tools used: {system_a_tools}
```
{system_a_response}
```

## System B Response
Tools used: {system_b_tools}
```
{system_b_response}
```

## Instructions

1. Score EACH system on 6 dimensions (0-100) with sub-scores and issues.
2. Determine the winner and margin based on response quality.
3. Identify what each system did well or poorly — focus on the output,
   not assumptions about the system's architecture.
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
    "winner": "system_a | system_b | tie",
    "margin": "decisive | slight | negligible",
    "quality_drivers": {{
      "system_a_advantages": ["specific observation"],
      "system_b_advantages": ["specific observation"]
    }},
    "key_insight": "one sentence"
  }}
}}"""


def build_judge_prompt(
    case: Union[SingleTurnCase, MultiTurnCase],
    system_a_response: str,
    system_a_tools: list[str],
    system_b_response: str,
    system_b_tools: list[str],
    expected_tools_a: list[str],
    expected_tools_b: list[str],
    system_a_turns: list | None = None,
    system_b_turns: list | None = None,
) -> str:
    """Build the judge prompt for a single case."""
    if isinstance(case, MultiTurnCase) and system_a_turns and system_b_turns:
        return _build_multi_turn_prompt(
            case, system_a_turns, system_b_turns,
            expected_tools_a, expected_tools_b,
        )

    return SINGLE_TURN_PROMPT.format(
        query=case.query,
        category=case.category,
        expected_behavior=case.expected_behavior if isinstance(case, SingleTurnCase) else case.overall_expected_behavior,
        gold_standard=case.gold_standard,
        expected_tools_a=", ".join(expected_tools_a) or "(none)",
        expected_tools_b=", ".join(expected_tools_b) or "(none)",
        system_a_tools=", ".join(system_a_tools) or "(none)",
        system_a_response=system_a_response,
        system_b_tools=", ".join(system_b_tools) or "(none)",
        system_b_response=system_b_response,
    )


def _build_multi_turn_prompt(
    case: MultiTurnCase,
    system_a_turns: list,
    system_b_turns: list,
    expected_tools_a: list[str],
    expected_tools_b: list[str],
) -> str:
    """Build judge prompt for multi-turn case with conversation transcript."""
    transcript = ""
    for i, turn in enumerate(case.turns):
        at = system_a_turns[i] if i < len(system_a_turns) else None
        bt = system_b_turns[i] if i < len(system_b_turns) else None
        transcript += f"\n### Turn {i + 1}\n"
        transcript += f"User: {turn.query}\n"
        transcript += f"Expected: {turn.expected_behavior}\n"
        if at:
            transcript += f"System A: {at.response_text} (tools: {', '.join(at.tools_used) or 'none'})\n"
        if bt:
            transcript += f"System B: {bt.response_text} (tools: {', '.join(bt.tools_used) or 'none'})\n"

    # Reuse the single-turn prompt structure but replace the response section
    # with the transcript and add coherence scoring instruction
    prompt = SINGLE_TURN_PROMPT.format(
        query=case.query + " (multi-turn — see transcript below)",
        category=case.category,
        expected_behavior=case.overall_expected_behavior,
        gold_standard=case.gold_standard,
        expected_tools_a=", ".join(expected_tools_a) or "(none)",
        expected_tools_b=", ".join(expected_tools_b) or "(none)",
        system_a_tools="(see transcript)",
        system_a_response="(see transcript below)",
        system_b_tools="(see transcript)",
        system_b_response="(see transcript below)",
    )
    prompt += f"\n\n## Conversation Transcript\n{transcript}"
    prompt += '\n\nIMPORTANT: Populate the "coherence" field with {{"system_a": N, "system_b": N}} (0-100 each). Evaluate context carry, no repetition, and building on prior turns.'
    # Replace the null coherence in the schema hint
    prompt = prompt.replace('"coherence": null', '"coherence": {"system_a": N, "system_b": N}')
    return prompt


def parse_judge_response(
    raw_text: str,
    swapped: bool = False,
) -> tuple[dict[str, DimensionScore], dict[str, DimensionScore], ComparisonVerdict, dict | None]:
    """Parse judge JSON into structured scores.

    If swapped=True, the judge saw Gemini as System B and Claude as System A,
    so we swap the results back to canonical order (gemini=A, claude=B).
    """
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

    a_dims = extract_dimensions(data.get("system_a", {}))
    b_dims = extract_dimensions(data.get("system_b", {}))

    comp_data = data.get("comparison", {})
    raw_winner = comp_data.get("winner", "tie")

    # Map system_a/system_b back to gemini/claude
    if raw_winner == "system_a":
        winner = "claude" if swapped else "gemini"
    elif raw_winner == "system_b":
        winner = "gemini" if swapped else "claude"
    else:
        winner = "tie"

    # Normalize quality_drivers to engineering_attribution shape for backwards compat
    qd = comp_data.get("quality_drivers", {})
    a_adv = qd.get("system_a_advantages", [])
    b_adv = qd.get("system_b_advantages", [])
    if swapped:
        a_adv, b_adv = b_adv, a_adv

    comparison = ComparisonVerdict(
        winner=winner,
        margin=comp_data.get("margin", "negligible"),
        engineering_attribution={"helped": a_adv, "hurt": b_adv, "irrelevant": []},
        raw_reasoning_advantage=comp_data.get("raw_reasoning_advantage"),
        key_insight=comp_data.get("key_insight", ""),
    )

    coherence = data.get("coherence")

    # Swap dimensions back to canonical order
    if swapped:
        return b_dims, a_dims, comparison, coherence
    return a_dims, b_dims, comparison, coherence


async def judge_case(
    case: Union[SingleTurnCase, MultiTurnCase],
    gemini_response: str,
    gemini_tools: list[str],
    claude_response: str,
    claude_tools: list[str],
    gemini_turns: list | None = None,
    claude_turns: list | None = None,
) -> tuple[dict[str, DimensionScore], dict[str, DimensionScore], ComparisonVerdict, dict | None]:
    """Run the LLM judge on a single case with position randomization."""
    import random
    swapped = random.random() < 0.5

    if swapped:
        a_resp, b_resp = claude_response, gemini_response
        a_tools, b_tools = claude_tools, gemini_tools
        a_turns, b_turns = claude_turns, gemini_turns
        exp_a, exp_b = case.expected_tools_claude, case.expected_tools_gemini
    else:
        a_resp, b_resp = gemini_response, claude_response
        a_tools, b_tools = gemini_tools, claude_tools
        a_turns, b_turns = gemini_turns, claude_turns
        exp_a, exp_b = case.expected_tools_gemini, case.expected_tools_claude

    prompt = build_judge_prompt(
        case, a_resp, a_tools, b_resp, b_tools,
        exp_a, exp_b, a_turns, b_turns,
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
    return parse_judge_response(raw, swapped=swapped)
