# Comparative Eval Framework

Compares the Gemini agent service against Claude Sonnet via MCP tools
to identify where engineering adds value vs where raw model reasoning
is sufficient.

## Quick Start

```bash
# Set required env vars
export ANTHROPIC_API_KEY="..."
export EVAL_GEMINI_URL="https://agent-service-xxx.run.app"
export EVAL_GEMINI_TOKEN="..."  # Cloud Run IAM identity token (optional if service is public)
export EVAL_MCP_URL="https://mcp-server-xxx.run.app"
export EVAL_MCP_API_KEY="..."   # MCP API key for test user
export EVAL_USER_ID="..."       # Firestore user ID (must have premium + data)

# Run all 40 cases
cd adk_agent/agent_service
python -m tests.eval.comparative.runner

# Run single category
python -m tests.eval.comparative.runner --category ambiguity

# Run single case
python -m tests.eval.comparative.runner --id cur_001

# Run with optimistic sampling (2x)
python -m tests.eval.comparative.runner --samples 2

# Generate insights from existing results
python -m tests.eval.comparative.analyze results/YYYY-MM-DD-HH-MM/
```

## Architecture

See spec: `docs/superpowers/specs/2026-03-22-comparative-eval-framework-design.md`

```
Runner
  |
  +---> Gemini Backend (POST /stream, SSE parsing)
  +---> Claude Backend (Anthropic API + MCP JSON-RPC)
  |
  Both responses ---> Deterministic Checks (penalties)
                 ---> Judge (Opus, 6 dimensions, comparative verdict)
                 ---> Results (JSON + summary + insights + matrix)
```

## Files

- `runner.py` — CLI, orchestrates backends + judge + output
- `test_cases.py` — 40 cases (15 curated, 10 ambiguity, 10 multi-turn, 5 structure)
- `judge.py` — Opus-based 6-dimension scorer with comparative verdict
- `analyze.py` — Opus-based insights synthesizer
- `deterministic_checks.py` — Pre-judge penalty checks
- `models.py` — Pydantic data models
- `backends/gemini_backend.py` — SSE client for agent service
- `backends/claude_backend.py` — Anthropic API + MCP tool execution
- `backends/tool_definitions.py` — 17 MCP tools as JSON Schema
- `backends/base.py` — EvalBackend protocol

## Judge Dimensions

| Dimension | Weight | What it measures |
|-----------|--------|-----------------|
| Correctness | 25% | Right tools, right data, fully addressed |
| Safety | 20% | Factual honesty, privacy, injury/medical handling |
| Understanding | 20% | Grasped actual need, emotional subtext, scope |
| Helpfulness | 15% | Concrete next step, advances situation, teaches |
| Response Craft | 10% | Organized, right length, easy to scan |
| Persona | 10% | Right tone, answers only what was asked |

## Test User Requirements

- Premium subscription (or override)
- MCP API key provisioned
- Training data spanning 4+ weeks
- At least one active routine
- Variety of exercises across muscle groups
