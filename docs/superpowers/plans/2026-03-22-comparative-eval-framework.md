# Comparative Eval Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a comparative evaluation framework that runs the same 40 test cases against both the Gemini agent service and Claude Sonnet via MCP, judges responses side-by-side, and produces actionable insights about where engineering adds or subtracts value.

**Architecture:** Python eval runner with two pluggable backends (Gemini SSE client, Claude Anthropic API + MCP tool executor). A judge module uses Claude Opus for side-by-side scoring on 6 dimensions plus engineering attribution. An analyzer synthesizes raw results into an insights report.

**Tech Stack:** Python, httpx (async HTTP/SSE), anthropic SDK, pydantic, pytest. All code lives in `adk_agent/agent_service/tests/eval/comparative/`.

**Spec:** `docs/superpowers/specs/2026-03-22-comparative-eval-framework-design.md`

---

## File Structure

```
adk_agent/agent_service/tests/eval/
  __init__.py
  conftest.py                # Adds tests/eval/ to sys.path for imports
  comparative/
    __init__.py
    conftest.py              # Shared fixtures (mock backends, sample cases)
    runner.py                # CLI entry point, orchestrates full eval run
    test_cases.py            # 40 test cases (SingleTurnCase + MultiTurnCase)
    judge.py                 # LLM-as-Judge with 6 dimensions + comparative verdict
    analyze.py               # Synthesizes raw results into insights.md
    deterministic_checks.py  # Pre-judge penalty checks (tool leak, hallucination, etc.)
    models.py                # Pydantic models: JudgeResult, CaseResult, RunSummary
    backends/
      __init__.py
      base.py                # BackendResponse protocol + shared types
      gemini_backend.py      # SSE client for agent service /stream
      claude_backend.py      # Anthropic API + MCP tool executor
      tool_definitions.py    # 17 MCP tools as Anthropic API JSON Schema
```

---

## Task 1: Data Models (`models.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/__init__.py`
- Create: `adk_agent/agent_service/tests/eval/conftest.py`
- Create: `adk_agent/agent_service/tests/eval/comparative/__init__.py`
- Create: `adk_agent/agent_service/tests/eval/comparative/conftest.py`
- Create: `adk_agent/agent_service/tests/eval/comparative/models.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_models.py`

- [ ] **Step 0: Create conftest.py for import path setup**

```python
# tests/eval/conftest.py
import sys
from pathlib import Path

# Add tests/eval/ to sys.path so "comparative" is importable
sys.path.insert(0, str(Path(__file__).parent))
```

```python
# tests/eval/comparative/conftest.py
# Shared fixtures can go here. Empty for now.
```

- [ ] **Step 1: Write test for BackendResponse and DimensionScore**

```python
# test_models.py
from comparative.models import BackendResponse, DimensionScore, CaseResult

def test_backend_response_creation():
    r = BackendResponse(
        response_text="Your bench is progressing well.",
        tools_used=["get_exercise_progress"],
        duration_ms=1200,
        error=None,
        turn_responses=None,
    )
    assert r.response_text == "Your bench is progressing well."
    assert r.tools_used == ["get_exercise_progress"]
    assert r.duration_ms == 1200

def test_dimension_score_weighted():
    d = DimensionScore(score=80, weight=0.25, sub_scores={"tool_selection": 35, "data_accuracy": 25, "completeness": 20}, issues=[])
    assert d.weighted_score == 20.0

def test_case_result_overall_score():
    dims = {
        "correctness": DimensionScore(score=80, weight=0.25, sub_scores={}, issues=[]),
        "safety": DimensionScore(score=90, weight=0.20, sub_scores={}, issues=[]),
        "understanding": DimensionScore(score=70, weight=0.20, sub_scores={}, issues=[]),
        "helpfulness": DimensionScore(score=60, weight=0.15, sub_scores={}, issues=[]),
        "response_craft": DimensionScore(score=75, weight=0.10, sub_scores={}, issues=[]),
        "persona": DimensionScore(score=85, weight=0.10, sub_scores={}, issues=[]),
    }
    assert sum(d.score * d.weight for d in dims.values()) == 77.0
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_models.py -v --rootdir=tests/eval
```
Expected: FAIL (module not found)

- [ ] **Step 3: Implement models.py**

```python
# models.py
from __future__ import annotations
from pydantic import BaseModel, computed_field
from typing import Optional


class TurnResponse(BaseModel):
    """Single turn in a multi-turn conversation."""
    response_text: str
    tools_used: list[str]


class BackendResponse(BaseModel):
    """Response from either backend."""
    response_text: str
    tools_used: list[str]
    duration_ms: int
    error: Optional[str] = None
    # For multi-turn: list of per-turn responses
    turn_responses: Optional[list[TurnResponse]] = None


class DimensionScore(BaseModel):
    """Score for one dimension."""
    score: float  # 0-100
    weight: float
    sub_scores: dict[str, float]
    issues: list[str]

    @computed_field
    @property
    def weighted_score(self) -> float:
        return self.score * self.weight


class ComparisonVerdict(BaseModel):
    winner: str  # "gemini" | "claude" | "tie"
    margin: str  # "decisive" | "slight" | "negligible"
    engineering_attribution: dict[str, list[str]]  # helped, hurt, irrelevant
    raw_reasoning_advantage: Optional[str] = None
    key_insight: str


class SystemScores(BaseModel):
    dimensions: dict[str, DimensionScore]
    deterministic_penalty: float = 0.0
    deterministic_issues: list[str] = []

    @computed_field
    @property
    def overall(self) -> float:
        weighted = sum(d.weighted_score for d in self.dimensions.values())
        return max(0, weighted - min(self.deterministic_penalty, 30))


class CaseResult(BaseModel):
    """Full result for one test case."""
    case_id: str
    category: str
    query: str  # or first turn query for multi-turn
    gemini: SystemScores
    claude: SystemScores
    comparison: ComparisonVerdict
    coherence: Optional[dict[str, float]] = None  # system_a, system_b — multi-turn only
    gemini_response: BackendResponse
    claude_response: BackendResponse


class RunSummary(BaseModel):
    """Aggregate results for a full eval run."""
    run_id: str
    cases_total: int
    temperature: dict[str, float]
    samples_per_case: int
    gemini_overall: float
    claude_overall: float
    gemini_by_dimension: dict[str, float]
    claude_by_dimension: dict[str, float]
    gemini_by_category: dict[str, float]
    claude_by_category: dict[str, float]
    gemini_wins: int
    claude_wins: int
    ties: int
    decisive_gemini: int
    decisive_claude: int
    engineering_helped_count: int
    engineering_hurt_count: int
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_models.py -v --rootdir=tests/eval
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/
git commit -m "feat(eval): add data models for comparative eval framework"
```

---

## Task 2: Test Cases (`test_cases.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/test_cases.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_test_cases.py`

- [ ] **Step 1: Write test for test case registry**

```python
# test_test_cases.py
from comparative.test_cases import ALL_CASES, CASES_BY_ID, get_cases, SingleTurnCase, MultiTurnCase

def test_total_case_count():
    assert len(ALL_CASES) == 40

def test_category_counts():
    curated = get_cases(category="curated")
    ambiguity = get_cases(category="ambiguity")
    multi_turn = get_cases(category="multi_turn")
    structure = get_cases(category="structure")
    assert len(curated) == 15
    assert len(ambiguity) == 10
    assert len(multi_turn) == 10
    assert len(structure) == 5

def test_multi_turn_cases_have_turns():
    mt = get_cases(category="multi_turn")
    for case in mt:
        assert isinstance(case, MultiTurnCase)
        assert len(case.turns) == 3

def test_all_cases_have_gold_standard():
    for case in ALL_CASES:
        assert case.gold_standard, f"{case.id} missing gold_standard"

def test_case_lookup_by_id():
    case = CASES_BY_ID.get("cur_001")
    assert case is not None
    assert "workout" in case.query.lower()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_test_cases.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Implement test_cases.py**

Define all 40 cases from the spec. Use the `SingleTurnCase` and `MultiTurnCase` dataclasses:

```python
# test_cases.py
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, Union


@dataclass
class SingleTurnCase:
    id: str
    query: str
    category: str
    expected_behavior: str
    gold_standard: str
    expected_tools_gemini: list[str]
    expected_tools_claude: list[str]
    tags: list[str] = field(default_factory=list)


@dataclass
class Turn:
    query: str
    expected_behavior: str


@dataclass
class MultiTurnCase:
    id: str
    turns: list[Turn]
    category: str
    overall_expected_behavior: str
    gold_standard: str
    expected_tools_gemini: list[str]
    expected_tools_claude: list[str]
    tags: list[str] = field(default_factory=list)

    @property
    def query(self) -> str:
        """First turn query, for display/logging."""
        return self.turns[0].query


# --- CURATED (15) ---
CURATED_CASES = [
    SingleTurnCase(
        id="cur_001",
        query="How did my last workout go?",
        category="curated",
        expected_behavior="Uses training analysis to summarize last workout performance",
        gold_standard="Summarizes with key metrics, mentions PRs/flags, one actionable next step",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["summary", "single_tool"],
    ),
    # ... all 15 curated cases from spec ...
]

# --- AMBIGUITY (10) ---
AMBIGUITY_CASES = [
    SingleTurnCase(
        id="amb_001",
        query="I feel like I'm not making progress",
        category="ambiguity",
        expected_behavior="Recognizes emotional + analytical need. Fetches data to give evidence-based perspective",
        gold_standard="Acknowledges feeling, then checks actual progress data. Does not dismiss or over-validate",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["emotional", "vague"],
    ),
    # ... all 10 ambiguity cases from spec ...
]

# --- MULTI-TURN (10) ---
MULTI_TURN_CASES = [
    MultiTurnCase(
        id="conv_001",
        turns=[
            Turn("How's my bench?", "Fetches bench progress, reports trend"),
            Turn("What about squat?", "Fetches squat progress, reports trend"),
            Turn("Which should I prioritize?", "Compares both, gives data-driven priority"),
        ],
        category="multi_turn",
        overall_expected_behavior="Carries context from both exercises into prioritization",
        gold_standard="Final turn references data from both prior analyses. Prioritization is data-driven",
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
        tags=["context_carry", "comparison"],
    ),
    # ... all 10 multi-turn cases from spec ...
]

# --- STRUCTURE (5) ---
STRUCTURE_CASES = [
    SingleTurnCase(
        id="struct_001",
        query="Give me a full breakdown of my training -- what's working, what's not, and what to change",
        category="structure",
        expected_behavior="Organized analysis with clear sections",
        gold_standard="Well-structured with headers or clear sections. Each point backed by data. Changes are specific and actionable",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["information_hierarchy"],
    ),
    # ... all 5 structure cases from spec ...
]

# --- Registry ---
AnyCase = Union[SingleTurnCase, MultiTurnCase]
ALL_CASES: list[AnyCase] = CURATED_CASES + AMBIGUITY_CASES + MULTI_TURN_CASES + STRUCTURE_CASES
CASES_BY_ID: dict[str, AnyCase] = {c.id: c for c in ALL_CASES}

def get_cases(category: str | None = None, case_id: str | None = None, tags: list[str] | None = None) -> list[AnyCase]:
    cases = ALL_CASES
    if case_id:
        return [CASES_BY_ID[case_id]] if case_id in CASES_BY_ID else []
    if category:
        cases = [c for c in cases if c.category == category]
    if tags:
        cases = [c for c in cases if any(t in c.tags for t in tags)]
    return cases
```

Populate all 40 cases with full expected_behavior, gold_standard, expected_tools_gemini, and expected_tools_claude from the spec's test case tables.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_test_cases.py -v --rootdir=tests/eval
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/test_cases.py adk_agent/agent_service/tests/eval/comparative/test_test_cases.py
git commit -m "feat(eval): add 40 comparative eval test cases"
```

---

## Task 3: Tool Definitions (`tool_definitions.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/backends/__init__.py`
- Create: `adk_agent/agent_service/tests/eval/comparative/backends/tool_definitions.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_tool_definitions.py`

- [ ] **Step 1: Write test for tool definitions**

```python
# test_tool_definitions.py
from comparative.backends.tool_definitions import MCP_TOOLS

def test_tool_count():
    assert len(MCP_TOOLS) == 17

def test_all_tools_have_required_fields():
    for tool in MCP_TOOLS:
        assert "name" in tool
        assert "description" in tool
        assert "input_schema" in tool
        assert tool["input_schema"]["type"] == "object"

def test_get_exercise_progress_schema():
    tool = next(t for t in MCP_TOOLS if t["name"] == "get_exercise_progress")
    props = tool["input_schema"]["properties"]
    assert "exercise" in props
    assert "weeks" in props
    assert "exercise" in tool["input_schema"]["required"]

def test_create_template_nested_schema():
    tool = next(t for t in MCP_TOOLS if t["name"] == "create_template")
    props = tool["input_schema"]["properties"]
    assert "exercises" in props
    assert props["exercises"]["type"] == "array"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_tool_definitions.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Implement tool_definitions.py**

Static JSON Schema definitions for all 17 MCP tools, converted from Zod schemas in `mcp_server/src/tools.ts`:

```python
# tool_definitions.py
"""
17 MCP tools as Anthropic API tool definitions (JSON Schema).
Source of truth: mcp_server/src/tools.ts
"""

MCP_TOOLS: list[dict] = [
    {
        "name": "get_training_snapshot",
        "description": "Get compact overview: user profile, active routine, next workout, recent workouts (summary), strength records",
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "list_routines",
        "description": "List all routines",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_routine",
        "description": "Get a specific routine with template names and exercise summaries",
        "input_schema": {
            "type": "object",
            "properties": {
                "routine_id": {"type": "string", "description": "Routine ID"},
                "include_templates": {"type": "boolean", "description": "Include template exercise summaries", "default": True},
            },
            "required": ["routine_id"],
        },
    },
    {
        "name": "list_templates",
        "description": "List all workout templates (names + IDs, no exercises). Use get_template for full exercise list.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_template",
        "description": "Get a specific template with full exercise list",
        "input_schema": {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID"},
            },
            "required": ["template_id"],
        },
    },
    {
        "name": "list_workouts",
        "description": "List recent workouts (summaries: date, exercises, set counts). Use get_workout for full set data.",
        "input_schema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "description": "Max results (default 10)", "default": 10},
            },
            "required": [],
        },
    },
    {
        "name": "get_workout",
        "description": "Get a specific workout with full exercise and set data",
        "input_schema": {
            "type": "object",
            "properties": {
                "workout_id": {"type": "string", "description": "Workout ID"},
            },
            "required": ["workout_id"],
        },
    },
    {
        "name": "search_exercises",
        "description": "Search exercise catalog",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "limit": {"type": "integer", "description": "Max results", "default": 10},
            },
            "required": ["query"],
        },
    },
    {
        "name": "get_training_analysis",
        "description": "Get training analysis insights",
        "input_schema": {
            "type": "object",
            "properties": {
                "sections": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Sections: insights, weekly_review, recommendation_history",
                },
                "include_expired": {"type": "boolean", "description": "Include expired/applied recommendations", "default": False},
            },
            "required": [],
        },
    },
    {
        "name": "get_muscle_group_progress",
        "description": "Get muscle group progress over time",
        "input_schema": {
            "type": "object",
            "properties": {
                "group": {"type": "string", "description": "Muscle group name"},
                "weeks": {"type": "integer", "description": "Number of weeks", "default": 8},
            },
            "required": ["group"],
        },
    },
    {
        "name": "get_exercise_progress",
        "description": "Get exercise progress over time",
        "input_schema": {
            "type": "object",
            "properties": {
                "exercise": {"type": "string", "description": "Exercise name"},
                "weeks": {"type": "integer", "description": "Number of weeks", "default": 8},
            },
            "required": ["exercise"],
        },
    },
    {
        "name": "query_sets",
        "description": "Query raw set-level training data",
        "input_schema": {
            "type": "object",
            "properties": {
                "exercise_name": {"type": "string", "description": "Exercise name (fuzzy match)"},
                "muscle_group": {"type": "string", "description": "Muscle group (e.g., chest, back, shoulders)"},
                "muscle": {"type": "string", "description": "Specific muscle (e.g., posterior deltoid)"},
                "exercise_ids": {"type": "array", "items": {"type": "string"}, "description": "Exercise IDs (max 10)"},
                "limit": {"type": "integer", "description": "Max results", "default": 50},
            },
            "required": [],
        },
    },
    {
        "name": "create_routine",
        "description": "Create a new routine",
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Routine name"},
                "template_ids": {"type": "array", "items": {"type": "string"}, "description": "Template IDs"},
                "frequency": {"type": "integer", "description": "Days per week"},
            },
            "required": ["name", "template_ids"],
        },
    },
    {
        "name": "update_routine",
        "description": "Update an existing routine",
        "input_schema": {
            "type": "object",
            "properties": {
                "routine_id": {"type": "string", "description": "Routine ID"},
                "updates": {"type": "object", "description": "Fields to update"},
            },
            "required": ["routine_id", "updates"],
        },
    },
    {
        "name": "create_template",
        "description": "Create a new workout template",
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Template name"},
                "exercises": {
                    "type": "array",
                    "description": "Exercises with set prescriptions",
                    "items": {
                        "type": "object",
                        "properties": {
                            "exercise_id": {"type": "string", "description": "Exercise ID from search_exercises"},
                            "name": {"type": "string", "description": "Exercise name"},
                            "position": {"type": "integer", "description": "Order in template (0-based)"},
                            "sets": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "type": {"type": "string", "description": "Set type", "default": "Working Set"},
                                        "reps": {"type": "integer", "description": "Target reps"},
                                        "weight": {"type": ["number", "null"], "description": "Target weight (kg) or null for bodyweight"},
                                        "rir": {"type": "integer", "description": "Reps in reserve (0-5)"},
                                    },
                                    "required": ["reps", "weight", "rir"],
                                },
                            },
                        },
                        "required": ["exercise_id", "position", "sets"],
                    },
                },
            },
            "required": ["name", "exercises"],
        },
    },
    {
        "name": "update_template",
        "description": "Update an existing template",
        "input_schema": {
            "type": "object",
            "properties": {
                "template_id": {"type": "string", "description": "Template ID"},
                "updates": {
                    "type": "object",
                    "description": "Fields to update",
                    "properties": {
                        "name": {"type": "string"},
                        "description": {"type": "string"},
                        "exercises": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "exercise_id": {"type": "string"},
                                    "name": {"type": "string"},
                                    "position": {"type": "integer"},
                                    "sets": {
                                        "type": "array",
                                        "items": {
                                            "type": "object",
                                            "properties": {
                                                "type": {"type": "string", "default": "Working Set"},
                                                "reps": {"type": "integer"},
                                                "weight": {"type": ["number", "null"]},
                                                "rir": {"type": "integer"},
                                            },
                                            "required": ["reps", "weight", "rir"],
                                        },
                                    },
                                },
                                "required": ["exercise_id", "position", "sets"],
                            },
                        },
                    },
                },
            },
            "required": ["template_id", "updates"],
        },
    },
    {
        "name": "list_memories",
        "description": "List agent memories about the user",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_tool_definitions.py -v --rootdir=tests/eval
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/backends/
git commit -m "feat(eval): add 17 MCP tool definitions for Claude backend"
```

---

## Task 4: Backend Protocol (`backends/base.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/backends/base.py`

- [ ] **Step 1: Implement backend protocol**

```python
# base.py
from __future__ import annotations
from typing import Protocol, Union
from comparative.test_cases import SingleTurnCase, MultiTurnCase
from comparative.models import BackendResponse

AnyCase = Union[SingleTurnCase, MultiTurnCase]


class EvalBackend(Protocol):
    """Protocol for eval backends."""

    async def run_case(self, case: AnyCase, user_id: str) -> BackendResponse:
        """Run a test case and return the response."""
        ...

    @property
    def name(self) -> str:
        """Backend name for logging/results."""
        ...
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/backends/base.py
git commit -m "feat(eval): add backend protocol for eval runners"
```

---

## Task 5: Gemini Backend (`gemini_backend.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/backends/gemini_backend.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_gemini_backend.py`

- [ ] **Step 1: Write test for SSE parsing**

```python
# test_gemini_backend.py
import pytest
from comparative.backends.gemini_backend import parse_sse_events

def test_parse_message_events():
    lines = [
        'event: message',
        'data: {"type": "message", "text": "Your bench"}',
        '',
        'event: message',
        'data: {"type": "message", "text": " is progressing."}',
        '',
        'event: done',
        'data: {"type": "done"}',
        '',
    ]
    text, tools = parse_sse_events(lines)
    assert text == "Your bench is progressing."
    assert tools == []

def test_parse_tool_events():
    lines = [
        'event: tool_start',
        'data: {"type": "tool_start", "tool": "tool_get_exercise_progress", "call_id": "c1"}',
        '',
        'event: tool_end',
        'data: {"type": "tool_end", "tool": "tool_get_exercise_progress", "call_id": "c1", "elapsed_ms": 300}',
        '',
        'event: message',
        'data: {"type": "message", "text": "Bench is up 5%."}',
        '',
        'event: done',
        'data: {"type": "done"}',
        '',
    ]
    text, tools = parse_sse_events(lines)
    assert text == "Bench is up 5%."
    assert tools == ["tool_get_exercise_progress"]

def test_parse_error_event():
    lines = [
        'event: error',
        'data: {"type": "error", "code": "TIMEOUT", "message": "Request timed out"}',
        '',
    ]
    text, tools = parse_sse_events(lines)
    assert "timed out" in text.lower() or "error" in text.lower()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_gemini_backend.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Implement gemini_backend.py**

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_gemini_backend.py -v --rootdir=tests/eval
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/backends/gemini_backend.py adk_agent/agent_service/tests/eval/comparative/test_gemini_backend.py
git commit -m "feat(eval): add Gemini SSE backend for eval runner"
```

---

## Task 6: Claude Backend (`claude_backend.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/backends/claude_backend.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_claude_backend.py`

- [ ] **Step 1: Write test for MCP tool execution**

```python
# test_claude_backend.py
import json
import pytest
from unittest.mock import AsyncMock, patch
from comparative.backends.claude_backend import execute_mcp_tool

@pytest.mark.asyncio
async def test_execute_mcp_tool_formats_jsonrpc():
    mock_response = AsyncMock()
    mock_response.status_code = 200
    mock_response.json = lambda: {
        "jsonrpc": "2.0",
        "result": {"content": [{"type": "text", "text": '{"e1rm": 120}'}]},
        "id": 1,
    }

    with patch("httpx.AsyncClient.post", return_value=mock_response) as mock_post:
        result = await execute_mcp_tool(
            mcp_url="https://mcp.example.com",
            api_key="test-key",
            tool_name="get_exercise_progress",
            arguments={"exercise": "bench press", "weeks": 8},
        )
        call_body = mock_post.call_args[1]["json"]
        assert call_body["jsonrpc"] == "2.0"
        assert call_body["method"] == "tools/call"
        assert call_body["params"]["name"] == "get_exercise_progress"
        assert result == '{"e1rm": 120}'
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_claude_backend.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Implement claude_backend.py**

```python
# claude_backend.py
"""Claude backend — Anthropic Messages API + MCP tool execution."""
from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Union

import httpx
from anthropic import AsyncAnthropic

from comparative.backends.tool_definitions import MCP_TOOLS
from comparative.models import BackendResponse, TurnResponse
from comparative.test_cases import MultiTurnCase, SingleTurnCase

logger = logging.getLogger(__name__)

AnyCase = Union[SingleTurnCase, MultiTurnCase]
MAX_TOOL_ROUNDS = 12


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
            },
        )
        resp.raise_for_status()
        data = resp.json()

    if "error" in data:
        return json.dumps({"error": data["error"].get("message", "Tool error")})

    result = data.get("result", {})
    content = result.get("content", [])
    # MCP tool results are content blocks — extract text
    texts = [c.get("text", "") for c in content if c.get("type") == "text"]
    return "\n".join(texts) if texts else json.dumps(result)


class ClaudeBackend:
    """Eval backend for Claude Sonnet via Anthropic API + MCP tools."""

    def __init__(
        self,
        anthropic_api_key: str,
        mcp_url: str,
        mcp_api_key: str,
        model: str = "claude-sonnet-4-6-20250514",
        temperature: float = 0.3,
    ):
        self.client = AsyncAnthropic(api_key=anthropic_api_key)
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
```

Note: The `anthropic` package needs to be added to `requirements.txt` for the eval suite. Add it as a dev/eval dependency.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_claude_backend.py -v --rootdir=tests/eval
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/backends/claude_backend.py adk_agent/agent_service/tests/eval/comparative/test_claude_backend.py
git commit -m "feat(eval): add Claude backend with Anthropic API + MCP tool execution"
```

---

## Task 7: Deterministic Checks (`deterministic_checks.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/deterministic_checks.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_deterministic_checks.py`

- [ ] **Step 1: Write tests for deterministic checks**

```python
# test_deterministic_checks.py
from comparative.deterministic_checks import run_checks

def test_tool_name_leak():
    issues, penalty = run_checks(
        "I used tool_get_exercise_progress to check.", ["get_exercise_progress"]
    )
    assert any("tool name" in i.lower() for i in issues)
    assert penalty >= 20

def test_hallucinated_user_data_no_tools():
    issues, penalty = run_checks(
        "Your e1RM is 120kg, up from 115kg last week.", []
    )
    assert any("user-specific" in i.lower() for i in issues)
    assert penalty >= 30

def test_generic_advice_not_flagged():
    """Generic coaching advice with numbers should NOT trigger hallucination check."""
    issues, penalty = run_checks(
        "Aim for 3 sets of 8-12 reps at around 60-70kg to start.", []
    )
    assert not any("user-specific" in i.lower() for i in issues)

def test_clean_response():
    issues, penalty = run_checks(
        "Your bench is progressing well based on recent data.", ["get_exercise_progress"]
    )
    assert issues == []
    assert penalty == 0

def test_document_id_exposure():
    issues, penalty = run_checks(
        "Exercise K21gndDYgWE25mFmPamH is bench press.", ["search_exercises"]
    )
    assert any("id" in i.lower() for i in issues)
    assert penalty >= 25

def test_empty_response():
    issues, penalty = run_checks("", [])
    assert any("empty" in i.lower() for i in issues)
    assert penalty >= 30
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_deterministic_checks.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Implement deterministic_checks.py**

Adapted from `canvas_orchestrator/tests/eval/judge.py` deterministic checks, simplified for the comparative context (no category-specific length rules).

```python
# deterministic_checks.py
"""Deterministic quality checks — exact, no LLM needed."""
import re

TOOL_NAME_PATTERNS = [
    re.compile(r"tool_\w+", re.I),
    re.compile(r"function_call", re.I),
    re.compile(r"function_response", re.I),
]

RAW_ID_PATTERN = re.compile(r"\b[A-Za-z0-9]{20,}\b")

WEIGHT_PATTERN = re.compile(r"\d+(?:\.\d+)?\s*(?:kg|lbs?|kilos?|pounds?)", re.I)

# Patterns that indicate user-specific data claims (not generic advice)
USER_DATA_CLAIM_PATTERNS = [
    re.compile(r"your (?:e1rm|1rm|max|pr|record)\b", re.I),
    re.compile(r"you (?:lifted|benched|squatted|deadlifted|pressed|did)\s+\d", re.I),
    re.compile(r"your (?:last|previous|recent)\s+\w+\s+was\s+\d", re.I),
    re.compile(r"you(?:'ve|'re| are| have)\s+(?:doing|averaging|hitting)\s+\d", re.I),
]


def run_checks(response_text: str, tools_used: list[str]) -> tuple[list[str], float]:
    """Returns (issues, total_penalty). Penalty capped at 30."""
    issues: list[str] = []
    penalties: dict[str, float] = {}

    # Empty response
    if not response_text.strip():
        issues.append("Empty response")
        penalties["empty"] = 30
        return issues, min(sum(penalties.values()), 30)

    # Tool name leakage
    for pat in TOOL_NAME_PATTERNS:
        matches = pat.findall(response_text)
        if matches:
            issues.append(f"Leaked tool name in response: {matches[:3]}")
            penalties["tool_leak"] = 20
            break

    # Document ID exposure
    id_matches = RAW_ID_PATTERN.findall(response_text)
    suspicious = [
        m for m in id_matches
        if not m.isalpha() and len(m) >= 20 and not m.startswith("http")
    ]
    if suspicious:
        issues.append(f"Exposed raw document IDs: {suspicious[:3]}")
        penalties["raw_id"] = 25

    # Hallucinated user-specific data (claiming personal stats without tool data)
    # Only triggers when: (a) no tools were used, and (b) response makes
    # user-specific claims with numbers (not generic advice like "aim for 3 sets")
    if not tools_used:
        for pat in USER_DATA_CLAIM_PATTERNS:
            matches = pat.findall(response_text)
            if matches:
                issues.append(f"Claimed user-specific data without tool calls: {matches[:3]}")
                penalties["hallucination"] = 30
                break

    return issues, min(sum(penalties.values()), 30)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_deterministic_checks.py -v --rootdir=tests/eval
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/deterministic_checks.py adk_agent/agent_service/tests/eval/comparative/test_deterministic_checks.py
git commit -m "feat(eval): add deterministic pre-judge checks"
```

---

## Task 8: Judge (`judge.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/judge.py`
- Test: `adk_agent/agent_service/tests/eval/comparative/test_judge.py`

- [ ] **Step 1: Write test for judge prompt construction and result parsing**

```python
# test_judge.py
import json
from comparative.judge import build_judge_prompt, parse_judge_response
from comparative.test_cases import SingleTurnCase

def test_build_prompt_contains_both_responses():
    case = SingleTurnCase(
        id="test_001", query="How's my bench?", category="curated",
        expected_behavior="Fetches progress", gold_standard="Reports trend",
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
    )
    prompt = build_judge_prompt(
        case=case,
        gemini_response="Your bench is up 5%.",
        gemini_tools=["tool_get_exercise_progress"],
        claude_response="Based on your data, bench e1RM increased from 100 to 105.",
        claude_tools=["get_exercise_progress"],
    )
    assert "System A" in prompt
    assert "System B" in prompt
    assert "Your bench is up 5%." in prompt
    assert "100 to 105" in prompt

def test_parse_valid_judge_response():
    raw = json.dumps({
        "system_a": {
            "correctness": {"score": 80, "tool_selection": 35, "data_accuracy": 25, "completeness": 20, "issues": []},
            "safety": {"score": 90, "no_hallucination": 38, "no_id_leak": 28, "medical_appropriate": 24, "issues": []},
            "understanding": {"score": 75, "intent_detection": 30, "subtext_recognition": 25, "scope_judgment": 20, "issues": []},
            "helpfulness": {"score": 70, "actionability": 30, "moves_forward": 20, "user_empowerment": 20, "issues": []},
            "response_craft": {"score": 65, "structure": 20, "length_appropriate": 25, "readability": 20, "issues": []},
            "persona": {"score": 85, "tone_appropriate": 45, "no_over_coaching": 40, "issues": []},
        },
        "system_b": {
            "correctness": {"score": 85, "tool_selection": 38, "data_accuracy": 27, "completeness": 20, "issues": []},
            "safety": {"score": 95, "no_hallucination": 40, "no_id_leak": 30, "medical_appropriate": 25, "issues": []},
            "understanding": {"score": 80, "intent_detection": 32, "subtext_recognition": 28, "scope_judgment": 20, "issues": []},
            "helpfulness": {"score": 75, "actionability": 32, "moves_forward": 23, "user_empowerment": 20, "issues": []},
            "response_craft": {"score": 80, "structure": 30, "length_appropriate": 25, "readability": 25, "issues": []},
            "persona": {"score": 80, "tone_appropriate": 40, "no_over_coaching": 40, "issues": []},
        },
        "coherence": None,
        "comparison": {
            "winner": "claude",
            "margin": "slight",
            "engineering_attribution": {"helped": [], "hurt": [], "irrelevant": ["both fetched same tool"]},
            "raw_reasoning_advantage": "Claude structured the response better",
            "key_insight": "Raw reasoning produced clearer data presentation",
        },
    })
    gemini_scores, claude_scores, comparison, coherence = parse_judge_response(raw)
    assert gemini_scores["correctness"].score == 80
    assert claude_scores["correctness"].score == 85
    assert comparison.winner == "claude"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_judge.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Implement judge.py**

```python
# judge.py
"""LLM-as-Judge — 6-dimension comparative scorer using Claude Opus."""
from __future__ import annotations

import json
import logging
import re
from typing import Optional, Union

from anthropic import AsyncAnthropic

from comparative.models import ComparisonVerdict, DimensionScore
from comparative.test_cases import MultiTurnCase, SingleTurnCase

logger = logging.getLogger(__name__)

JUDGE_MODEL = "claude-opus-4-6"

DIMENSION_WEIGHTS = {
    "correctness": 0.25,
    "safety": 0.20,
    "understanding": 0.20,
    "helpfulness": 0.15,
    "response_craft": 0.10,
    "persona": 0.10,
}

# Full judge prompt template (from spec — see design doc for the complete text)
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

# Multi-turn variant appends conversation transcript instead of single responses.
# Build dynamically in build_judge_prompt().


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
    anthropic_api_key: str,
    gemini_turns: list | None = None,
    claude_turns: list | None = None,
) -> tuple[dict[str, DimensionScore], dict[str, DimensionScore], ComparisonVerdict, dict | None]:
    """Run the LLM judge on a single case."""
    prompt = build_judge_prompt(
        case, gemini_response, gemini_tools,
        claude_response, claude_tools,
        gemini_turns, claude_turns,
    )

    client = AsyncAnthropic(api_key=anthropic_api_key)
    resp = await client.messages.create(
        model=JUDGE_MODEL,
        max_tokens=4096,
        temperature=0.1,
        messages=[{"role": "user", "content": prompt}],
    )

    raw = resp.content[0].text
    return parse_judge_response(raw)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_judge.py -v --rootdir=tests/eval
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/judge.py adk_agent/agent_service/tests/eval/comparative/test_judge.py
git commit -m "feat(eval): add LLM-as-Judge with 6 dimensions + comparative verdict"
```

---

## Task 9: Runner (`runner.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/runner.py`

- [ ] **Step 1: Implement the runner CLI**

The runner orchestrates the full eval run: loads cases, runs both backends, judges results, saves output.

```python
# runner.py
"""Comparative eval runner — orchestrates Gemini vs Claude evaluation."""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import time
from datetime import datetime
from pathlib import Path

from comparative.analyze import generate_insights
from comparative.backends.claude_backend import ClaudeBackend
from comparative.backends.gemini_backend import GeminiBackend
from comparative.deterministic_checks import run_checks
from comparative.judge import judge_case
from comparative.models import (
    BackendResponse, CaseResult, ComparisonVerdict,
    RunSummary, SystemScores,
)
from comparative.test_cases import (
    ALL_CASES, MultiTurnCase, SingleTurnCase, get_cases,
)

logger = logging.getLogger(__name__)

RESULTS_DIR = Path(__file__).parent / "results"


async def run_single_case(
    case,
    gemini: GeminiBackend,
    claude: ClaudeBackend,
    user_id: str,
    anthropic_api_key: str,
) -> CaseResult:
    """Run one case against both backends and judge."""
    logger.info("Running case %s: %s", case.id, case.query[:50])

    # Run both backends (can be parallel for single-turn)
    if isinstance(case, SingleTurnCase):
        gemini_resp, claude_resp = await asyncio.gather(
            gemini.run_case(case, user_id),
            claude.run_case(case, user_id),
        )
    else:
        # Multi-turn: run sequentially to avoid conversation state conflicts
        gemini_resp = await gemini.run_case(case, user_id)
        claude_resp = await claude.run_case(case, user_id)

    # Deterministic checks
    g_issues, g_penalty = run_checks(gemini_resp.response_text, gemini_resp.tools_used)
    c_issues, c_penalty = run_checks(claude_resp.response_text, claude_resp.tools_used)

    # LLM Judge
    gemini_turns = [t for t in (gemini_resp.turn_responses or [])]
    claude_turns = [t for t in (claude_resp.turn_responses or [])]

    g_dims, c_dims, comparison, coherence = await judge_case(
        case=case,
        gemini_response=gemini_resp.response_text,
        gemini_tools=gemini_resp.tools_used,
        claude_response=claude_resp.response_text,
        claude_tools=claude_resp.tools_used,
        anthropic_api_key=anthropic_api_key,
        gemini_turns=gemini_turns or None,
        claude_turns=claude_turns or None,
    )

    return CaseResult(
        case_id=case.id,
        category=case.category,
        query=case.query,
        gemini=SystemScores(dimensions=g_dims, deterministic_penalty=g_penalty, deterministic_issues=g_issues),
        claude=SystemScores(dimensions=c_dims, deterministic_penalty=c_penalty, deterministic_issues=c_issues),
        comparison=comparison,
        coherence=coherence,
        gemini_response=gemini_resp,
        claude_response=claude_resp,
    )


def build_summary(results: list[CaseResult], run_id: str) -> RunSummary:
    """Aggregate case results into a run summary."""
    g_wins = sum(1 for r in results if r.comparison.winner == "gemini")
    c_wins = sum(1 for r in results if r.comparison.winner == "claude")
    ties = sum(1 for r in results if r.comparison.winner == "tie")

    dims = ["correctness", "safety", "understanding", "helpfulness", "response_craft", "persona"]
    cats = list({r.category for r in results})

    def avg_dim(results, system, dim):
        scores = [getattr(r, system).dimensions[dim].score for r in results if dim in getattr(r, system).dimensions]
        return round(sum(scores) / len(scores), 1) if scores else 0

    def avg_overall(results, system):
        scores = [getattr(r, system).overall for r in results]
        return round(sum(scores) / len(scores), 1) if scores else 0

    def avg_cat(results, system, cat):
        cat_results = [r for r in results if r.category == cat]
        return avg_overall(cat_results, system)

    eng_helped = sum(1 for r in results if r.comparison.engineering_attribution.get("helped"))
    eng_hurt = sum(1 for r in results if r.comparison.engineering_attribution.get("hurt"))

    return RunSummary(
        run_id=run_id,
        cases_total=len(results),
        temperature={"gemini": 0.3, "claude": 0.3, "judge": 0.1},
        samples_per_case=1,
        gemini_overall=avg_overall(results, "gemini"),
        claude_overall=avg_overall(results, "claude"),
        gemini_by_dimension={d: avg_dim(results, "gemini", d) for d in dims},
        claude_by_dimension={d: avg_dim(results, "claude", d) for d in dims},
        gemini_by_category={c: avg_cat(results, "gemini", c) for c in cats},
        claude_by_category={c: avg_cat(results, "claude", c) for c in cats},
        gemini_wins=g_wins,
        claude_wins=c_wins,
        ties=ties,
        decisive_gemini=sum(1 for r in results if r.comparison.winner == "gemini" and r.comparison.margin == "decisive"),
        decisive_claude=sum(1 for r in results if r.comparison.winner == "claude" and r.comparison.margin == "decisive"),
        engineering_helped_count=eng_helped,
        engineering_hurt_count=eng_hurt,
    )


def build_matrix(results: list[CaseResult]) -> str:
    """Generate markdown comparison matrix."""
    lines = ["| Case | Category | Winner | Margin | Gemini | Claude | Key Insight |", "|------|----------|--------|--------|--------|--------|-------------|"]
    for r in results:
        lines.append(
            f"| {r.case_id} | {r.category} | {r.comparison.winner} | {r.comparison.margin} "
            f"| {r.gemini.overall:.0f} | {r.claude.overall:.0f} | {r.comparison.key_insight} |"
        )
    return "\n".join(lines)


async def run_with_retry(coro_fn, max_retries=3):
    """Retry with exponential backoff on rate limit (429) errors."""
    for attempt in range(max_retries):
        try:
            return await coro_fn()
        except Exception as e:
            if "429" in str(e) and attempt < max_retries - 1:
                wait = min(2 ** attempt, 30)
                logger.warning("Rate limited, retrying in %ds...", wait)
                await asyncio.sleep(wait)
            else:
                raise


async def run_case_with_samples(
    case, gemini, claude, user_id, anthropic_key, samples: int
) -> CaseResult:
    """Run a case N times and keep the best result (optimistic sampling)."""
    best: CaseResult | None = None
    for s in range(samples):
        result = await run_with_retry(
            lambda: run_single_case(case, gemini, claude, user_id, anthropic_key)
        )
        if best is None or (result.gemini.overall + result.claude.overall) > (best.gemini.overall + best.claude.overall):
            best = result
    return best


async def main():
    parser = argparse.ArgumentParser(description="Comparative eval runner")
    parser.add_argument("--category", help="Filter by category")
    parser.add_argument("--id", help="Run a single case by ID")
    parser.add_argument("--parallel", type=int, default=3, help="Max parallel cases (capped at 5)")
    parser.add_argument("--samples", type=int, default=1, help="Samples per case (2 for optimistic sampling)")
    parser.add_argument("--no-insights", action="store_true", help="Skip Opus insights generation")
    parser.add_argument("--gemini-url", default=os.getenv("EVAL_GEMINI_URL"), help="Agent service URL")
    parser.add_argument("--mcp-url", default=os.getenv("EVAL_MCP_URL"), help="MCP server URL")
    parser.add_argument("--user-id", default=os.getenv("EVAL_USER_ID"), help="Test user ID")
    args = parser.parse_args()
    args.parallel = min(args.parallel, 5)  # Cap per spec

    # Load config from env
    anthropic_key = os.environ["ANTHROPIC_API_KEY"]
    gemini_token = os.getenv("EVAL_GEMINI_TOKEN")  # Optional for non-IAM
    mcp_api_key = os.environ["EVAL_MCP_API_KEY"]

    gemini = GeminiBackend(args.gemini_url, gemini_token)
    claude = ClaudeBackend(anthropic_key, args.mcp_url, mcp_api_key)

    cases = get_cases(category=args.category, case_id=args.id)
    logger.info("Running %d cases (%d samples each)", len(cases), args.samples)

    # Run cases with concurrency limit
    sem = asyncio.Semaphore(args.parallel)

    async def run_with_limit(case):
        async with sem:
            return await run_case_with_samples(
                case, gemini, claude, args.user_id, anthropic_key, args.samples
            )

    results = await asyncio.gather(*[run_with_limit(c) for c in cases])

    # Save results
    run_id = datetime.now().strftime("%Y-%m-%d-%H-%M")
    run_dir = RESULTS_DIR / run_id
    raw_dir = run_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    for r in results:
        (raw_dir / f"{r.case_id}.json").write_text(r.model_dump_json(indent=2))

    summary = build_summary(results, run_id)
    summary.samples_per_case = args.samples
    (run_dir / "summary.json").write_text(summary.model_dump_json(indent=2))
    (run_dir / "matrix.md").write_text(build_matrix(results))

    # Generate insights (optional — costs an Opus call)
    if not args.no_insights:
        logger.info("Generating insights with Opus...")
        insights = await generate_insights(run_dir, anthropic_key)
        (run_dir / "insights.md").write_text(insights)

    # Print summary
    print(f"\n{'='*60}")
    print(f"Run: {run_id} | Cases: {len(results)} | Samples: {args.samples}")
    print(f"Gemini overall: {summary.gemini_overall} | Claude overall: {summary.claude_overall}")
    print(f"Wins: Gemini {summary.gemini_wins} | Claude {summary.claude_wins} | Ties {summary.ties}")
    print(f"Results: {run_dir}")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/runner.py
git commit -m "feat(eval): add comparative eval runner with parallel execution"
```

---

## Task 10: Analyzer (`analyze.py`)

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/analyze.py`

- [ ] **Step 1: Implement analyze.py**

```python
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
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/analyze.py
git commit -m "feat(eval): add Opus-based insights analyzer"
```

---

## Task 11: Dependencies & Gitignore

**Files:**
- Modify: `adk_agent/agent_service/requirements.txt` — add `anthropic` package
- Create: `adk_agent/agent_service/tests/eval/comparative/results/.gitkeep`
- Modify: `.gitignore` — add eval results directory

- [ ] **Step 1: Add anthropic dependency**

Add to the end of `requirements.txt`:
```
# Eval dependencies
anthropic>=0.40.0
```

- [ ] **Step 2: Create results directory with .gitkeep**

```bash
mkdir -p adk_agent/agent_service/tests/eval/comparative/results
touch adk_agent/agent_service/tests/eval/comparative/results/.gitkeep
```

- [ ] **Step 3: Add gitignore entry for eval results**

Append to `.gitignore`:
```
# Eval results (contain API responses, potentially sensitive)
adk_agent/agent_service/tests/eval/comparative/results/*/
```

- [ ] **Step 4: Commit**

```bash
git add adk_agent/agent_service/requirements.txt adk_agent/agent_service/tests/eval/comparative/results/.gitkeep .gitignore
git commit -m "chore(eval): add anthropic dependency and gitignore eval results"
```

---

## Task 12: Integration Test & First Run

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/test_smoke.py`

- [ ] **Step 1: Write smoke test that validates the full pipeline with mocked backends**

```python
# test_smoke.py
"""Smoke test — validates the full eval pipeline with mocked responses."""
import asyncio
import json
import pytest
from unittest.mock import AsyncMock, patch

from comparative.models import BackendResponse
from comparative.runner import run_single_case, build_summary
from comparative.test_cases import CASES_BY_ID


@pytest.mark.asyncio
async def test_full_pipeline_mocked():
    """Run one case through the full pipeline with mocked backends and judge."""
    case = CASES_BY_ID["cur_001"]

    mock_gemini = AsyncMock()
    mock_gemini.run_case.return_value = BackendResponse(
        response_text="Your last push day went well. You completed 17 sets with 2 bench press PRs.",
        tools_used=["tool_get_training_analysis"],
        duration_ms=2000,
    )

    mock_claude = AsyncMock()
    mock_claude.run_case.return_value = BackendResponse(
        response_text="Based on your training analysis, your last workout was a push day with 17 sets. Your bench press showed improvement with higher e1RM estimates.",
        tools_used=["get_training_analysis"],
        duration_ms=3000,
    )

    mock_judge_response = json.dumps({
        "system_a": {
            "correctness": {"score": 80, "tool_selection": 40, "data_accuracy": 20, "completeness": 20, "issues": []},
            "safety": {"score": 95, "no_hallucination": 40, "no_id_leak": 30, "medical_appropriate": 25, "issues": []},
            "understanding": {"score": 75, "intent_detection": 30, "subtext_recognition": 25, "scope_judgment": 20, "issues": []},
            "helpfulness": {"score": 70, "actionability": 30, "moves_forward": 20, "user_empowerment": 20, "issues": []},
            "response_craft": {"score": 65, "structure": 20, "length_appropriate": 25, "readability": 20, "issues": []},
            "persona": {"score": 85, "tone_appropriate": 45, "no_over_coaching": 40, "issues": []},
        },
        "system_b": {
            "correctness": {"score": 85, "tool_selection": 40, "data_accuracy": 25, "completeness": 20, "issues": []},
            "safety": {"score": 95, "no_hallucination": 40, "no_id_leak": 30, "medical_appropriate": 25, "issues": []},
            "understanding": {"score": 80, "intent_detection": 32, "subtext_recognition": 28, "scope_judgment": 20, "issues": []},
            "helpfulness": {"score": 75, "actionability": 35, "moves_forward": 20, "user_empowerment": 20, "issues": []},
            "response_craft": {"score": 80, "structure": 30, "length_appropriate": 25, "readability": 25, "issues": []},
            "persona": {"score": 80, "tone_appropriate": 40, "no_over_coaching": 40, "issues": []},
        },
        "coherence": None,
        "comparison": {
            "winner": "claude",
            "margin": "slight",
            "engineering_attribution": {"helped": ["context loading provided training snapshot"], "hurt": [], "irrelevant": []},
            "raw_reasoning_advantage": "Claude structured response better",
            "key_insight": "Both selected correct tool; Claude's presentation was clearer",
        },
    })

    with patch("comparative.judge.AsyncAnthropic") as mock_anthropic:
        mock_msg = AsyncMock()
        mock_msg.content = [AsyncMock(text=mock_judge_response)]
        mock_anthropic.return_value.messages.create = AsyncMock(return_value=mock_msg)

        result = await run_single_case(
            case, mock_gemini, mock_claude, "test-user", "fake-key"
        )

    assert result.case_id == "cur_001"
    assert result.comparison.winner == "claude"
    assert result.gemini.overall > 0
    assert result.claude.overall > 0

    # Test summary generation
    summary = build_summary([result], "test-run")
    assert summary.cases_total == 1
    assert summary.claude_wins == 1
```

- [ ] **Step 2: Run smoke test**

```bash
cd adk_agent/agent_service && python -m pytest tests/eval/comparative/test_smoke.py -v --rootdir=tests/eval
```

- [ ] **Step 3: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/test_smoke.py
git commit -m "feat(eval): add smoke test for full eval pipeline"
```

---

## Task 13: Documentation

**Files:**
- Create: `adk_agent/agent_service/tests/eval/comparative/ARCHITECTURE.md`

- [ ] **Step 1: Write architecture doc**

```markdown
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

# Generate insights from results
python -m tests.eval.comparative.analyze results/YYYY-MM-DD-HH-MM/
```

## Architecture

See spec: `docs/superpowers/specs/2026-03-22-comparative-eval-framework-design.md`

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
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/tests/eval/comparative/ARCHITECTURE.md
git commit -m "docs(eval): add architecture doc for comparative eval framework"
```
