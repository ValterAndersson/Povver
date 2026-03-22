"""Data models for comparative eval framework."""
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
