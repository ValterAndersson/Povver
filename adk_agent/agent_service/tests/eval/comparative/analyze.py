# analyze.py
"""Synthesizes raw eval results into insights.md using Opus."""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
from pathlib import Path

from anthropic import AsyncAnthropic

logger = logging.getLogger(__name__)

SYNTHESIS_PROMPT = """You are analyzing the results of a comparative evaluation between two AI fitness coaching systems:

- **Gemini Agent**: Fully engineered with 733-line coaching prompt, pre-loaded context, 31 tools, planner, safety gate
- **Claude MCP**: Raw Sonnet 4.6 with no system prompt, 17 MCP tools, no pre-loaded context

Your job: identify patterns across all test cases to answer what justifies (or doesn't justify) the engineering investment in the Gemini agent.

## Run Summary
```json
{summary}
```

## All Case Results
{case_details}

## Instructions

Produce a markdown report with these exact sections:

1. **Engineering Wins** - Where the Gemini agent's engineering added clear value. Group by engineering component (prompt rules, context loading, planner, safety gate, persona). Include case IDs as evidence.

2. **Engineering Losses** - Where engineering made things worse. Be specific about which constraints hurt quality. Include recommendations for what to change.

3. **Model Reasoning Wins** - Where raw model quality determined the outcome regardless of engineering. What does this imply for agent design?

4. **Parity** - Where both performed similarly and why.

5. **Top 3 Actions to Improve the In-Platform Agent** - Specific, actionable recommendations ranked by expected impact.

Be honest and direct. The goal is to make the in-platform agent clearly better than raw Claude + MCP. If the data shows the engineering isn't helping, say so.
"""


async def generate_insights(run_dir: Path, anthropic_api_key: str) -> str:
    """Generate insights.md from raw results."""
    summary = json.loads((run_dir / "summary.json").read_text())

    raw_dir = run_dir / "raw"
    case_details = ""
    for f in sorted(raw_dir.glob("*.json")):
        data = json.loads(f.read_text())
        case_details += f"\n### {data['case_id']} ({data['category']})\n"
        case_details += f"Query: {data['query']}\n"
        case_details += f"Winner: {data['comparison']['winner']} ({data['comparison']['margin']})\n"
        case_details += f"Gemini score: {data['gemini']['overall']:.0f} | Claude score: {data['claude']['overall']:.0f}\n"
        case_details += f"Key insight: {data['comparison']['key_insight']}\n"
        eng = data['comparison']['engineering_attribution']
        if eng.get('helped'):
            case_details += f"Engineering helped: {'; '.join(eng['helped'])}\n"
        if eng.get('hurt'):
            case_details += f"Engineering hurt: {'; '.join(eng['hurt'])}\n"
        if data['comparison'].get('raw_reasoning_advantage'):
            case_details += f"Model advantage: {data['comparison']['raw_reasoning_advantage']}\n"

    prompt = SYNTHESIS_PROMPT.format(
        summary=json.dumps(summary, indent=2),
        case_details=case_details,
    )

    client = AsyncAnthropic(api_key=anthropic_api_key)
    resp = await client.messages.create(
        model="claude-opus-4-6",
        max_tokens=4096,
        temperature=0.2,
        messages=[{"role": "user", "content": prompt}],
    )

    return resp.content[0].text


async def main():
    parser = argparse.ArgumentParser(description="Analyze eval results")
    parser.add_argument("run_dir", help="Path to eval run directory")
    args = parser.parse_args()

    import os
    api_key = os.environ["ANTHROPIC_API_KEY"]
    run_dir = Path(args.run_dir)

    insights = await generate_insights(run_dir, api_key)
    output = run_dir / "insights.md"
    output.write_text(insights)
    print(f"Insights written to {output}")
    print(insights)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
