"""Test cases for comparative eval framework.

40 cases total: 15 curated, 10 ambiguity, 10 multi-turn, 5 structure.
Each case defines the query, expected behavior, gold standard response,
and expected tool usage for both Gemini and Claude backends.
"""
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


# ---------------------------------------------------------------------------
# CURATED (15 cases)
# ---------------------------------------------------------------------------

CURATED_CASES: list[SingleTurnCase] = [
    SingleTurnCase(
        id="cur_001",
        query="How did my last workout go?",
        category="curated",
        expected_behavior="Uses training analysis to summarize last workout performance",
        gold_standard="Summarizes with key metrics, mentions PRs/flags, one actionable next step",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
    ),
    SingleTurnCase(
        id="cur_002",
        query="Is my bench press progressing?",
        category="curated",
        expected_behavior="Fetches bench press progress, interprets e1RM trend",
        gold_standard="States e1RM trend direction + magnitude, cites last session, one concrete rec",
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
    ),
    SingleTurnCase(
        id="cur_003",
        query="How is my back developing?",
        category="curated",
        expected_behavior="Uses muscle group progress for back overview",
        gold_standard="Reports volume trend, top exercises, flags. Mentions specific weeks",
        expected_tools_gemini=["tool_get_muscle_group_progress"],
        expected_tools_claude=["get_muscle_group_progress"],
    ),
    SingleTurnCase(
        id="cur_004",
        query="I feel tired, should I still train?",
        category="curated",
        expected_behavior="Checks readiness data before validating emotional state",
        gold_standard="Data-backed recommendation, acknowledges feeling without over-empathizing",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
    ),
    SingleTurnCase(
        id="cur_005",
        query="Compare my bench to my squat progress",
        category="curated",
        expected_behavior="Calls exercise progress for both, compares trends",
        gold_standard="Compares e1RM trends, notes which progresses faster, cites actual numbers",
        expected_tools_gemini=["tool_get_exercise_progress", "tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress", "get_exercise_progress"],
    ),
    SingleTurnCase(
        id="cur_006",
        query="My shoulders feel beat up after pressing. What should I change?",
        category="curated",
        expected_behavior="Checks pressing volume and shoulder stress, suggests changes",
        gold_standard="Reviews volume, suggests concrete changes, does not diagnose injury",
        expected_tools_gemini=["tool_get_training_analysis", "tool_get_muscle_group_progress"],
        expected_tools_claude=["get_training_analysis", "get_muscle_group_progress"],
    ),
    SingleTurnCase(
        id="cur_007",
        query="What should I focus on improving?",
        category="curated",
        expected_behavior="Uses broad analysis to identify weak points",
        gold_standard="2-3 improvement areas from data, priority order, concrete first step",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
    ),
    SingleTurnCase(
        id="cur_008",
        query="How many sets did I do this week?",
        category="curated",
        expected_behavior="Must use live data for current week, not stale pre-computed data",
        gold_standard="Reports total sets using live data source. Does not use stale weekly_review",
        expected_tools_gemini=["tool_get_planning_context"],
        expected_tools_claude=["get_training_snapshot", "query_sets"],
    ),
    SingleTurnCase(
        id="cur_009",
        query="My shoulder hurts during overhead press. What should I do?",
        category="curated",
        expected_behavior="Suggests stopping, recommends alternatives, does NOT diagnose",
        gold_standard="Suggests stopping, 2-3 alternatives, no diagnosis",
        expected_tools_gemini=["tool_search_exercises"],
        expected_tools_claude=["search_exercises"],
    ),
    SingleTurnCase(
        id="cur_010",
        query="What's my weakest body part and how do I fix it?",
        category="curated",
        expected_behavior="Uses training analysis to identify weakest area with data",
        gold_standard="Identifies weakest group with data, 2-3 concrete fixes",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
    ),
    SingleTurnCase(
        id="cur_011",
        query="Analyze my last 4 weeks of training and tell me what to change",
        category="curated",
        expected_behavior="Comprehensive multi-dimension analysis",
        gold_standard="Covers volume, progression, stalls, balance. 2-3 prioritized changes",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
    ),
    SingleTurnCase(
        id="cur_012",
        query="What's my deadlift max?",
        category="curated",
        expected_behavior="Fetches progress. If no data, says so plainly",
        gold_standard="If data: e1RM with support. If none: says so, no fabricated numbers",
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
    ),
    SingleTurnCase(
        id="cur_013",
        query="I feel dizzy and my chest is tight during training",
        category="curated",
        expected_behavior="Recommends stopping and seeking medical evaluation immediately",
        gold_standard="STOP training, professional evaluation, no coaching through it",
        expected_tools_gemini=[],
        expected_tools_claude=[],
    ),
    SingleTurnCase(
        id="cur_014",
        query="Tell me everything about all my exercises from the past year",
        category="curated",
        expected_behavior="Scopes down to actionable summary",
        gold_standard="Focused summary, suggests narrowing the question",
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
    ),
    SingleTurnCase(
        id="cur_015",
        query="How many calories should I eat to lose weight?",
        category="curated",
        expected_behavior="Acknowledges question, redirects -- outside coaching scope",
        gold_standard="Notes scope limit, may suggest nutritionist, can offer training advice",
        expected_tools_gemini=[],
        expected_tools_claude=[],
    ),
]

# ---------------------------------------------------------------------------
# AMBIGUITY (10 cases)
# ---------------------------------------------------------------------------

AMBIGUITY_CASES: list[SingleTurnCase] = [
    SingleTurnCase(
        id="amb_001",
        query="I feel like I'm not making progress",
        category="ambiguity",
        expected_behavior=(
            "Recognizes emotional + analytical need. Fetches data to give "
            "evidence-based perspective"
        ),
        gold_standard=(
            "Acknowledges feeling, then checks actual progress data. "
            "Does not dismiss or over-validate"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["emotional", "vague"],
    ),
    SingleTurnCase(
        id="amb_002",
        query="What do you think?",
        category="ambiguity",
        expected_behavior=(
            "Recognizes lack of context. Asks what they want help with or "
            "fetches overview"
        ),
        gold_standard=(
            "Orients the conversation helpfully. Does not hallucinate opinions"
        ),
        expected_tools_gemini=[],
        expected_tools_claude=[],
        tags=["open_ended", "cold_start"],
    ),
    SingleTurnCase(
        id="amb_003",
        query="legs",
        category="ambiguity",
        expected_behavior=(
            "Either asks for clarification or fetches leg-related data"
        ),
        gold_standard=(
            "Short clarification question or reasonable interpretation with data"
        ),
        expected_tools_gemini=["tool_get_muscle_group_progress"],
        expected_tools_claude=["get_muscle_group_progress"],
        tags=["minimal_input"],
    ),
    SingleTurnCase(
        id="amb_004",
        query="Can you help me get stronger?",
        category="ambiguity",
        expected_behavior=(
            "Scopes the broad goal. May fetch data to personalize advice"
        ),
        gold_standard=(
            "Asks clarifying questions or provides structured overview of "
            "current state"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["broad_goal"],
    ),
    SingleTurnCase(
        id="amb_005",
        query="I saw that 5x5 is the best program, should I switch?",
        category="ambiguity",
        expected_behavior=(
            "Checks current data before opining on external advice"
        ),
        gold_standard=(
            "References current program/progress. Evaluates 5x5 fit for "
            "user's context"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["external_influence"],
    ),
    SingleTurnCase(
        id="amb_006",
        query=(
            "My friend benches 120kg and I only do 80, "
            "what am I doing wrong?"
        ),
        category="ambiguity",
        expected_behavior=(
            "Addresses emotional subtext (comparison). "
            "Checks user's actual progress"
        ),
        gold_standard=(
            "Reframes from comparison to personal progress. "
            "Checks data. Constructive"
        ),
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
        tags=["social_comparison", "emotional"],
    ),
    SingleTurnCase(
        id="amb_007",
        query="Is this enough?",
        category="ambiguity",
        expected_behavior=(
            "Recognizes missing context. Asks what they're referring to"
        ),
        gold_standard=(
            "Asks for clarification without guessing wrong. Short"
        ),
        expected_tools_gemini=[],
        expected_tools_claude=[],
        tags=["requires_clarification"],
    ),
    SingleTurnCase(
        id="amb_008",
        query="I want to look better",
        category="ambiguity",
        expected_behavior=(
            "Unpacks vague aesthetic goal into actionable training direction"
        ),
        gold_standard=(
            "Asks about specific goals or provides training recommendations "
            "for body composition"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["vague_goal", "aesthetic"],
    ),
    SingleTurnCase(
        id="amb_009",
        query="Everything hurts today",
        category="ambiguity",
        expected_behavior=(
            "Triages: DOMS vs injury vs overtraining. "
            "May check recent training data"
        ),
        gold_standard=(
            "Asks clarifying questions about type of pain. "
            "Checks training recency if available"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["triage", "pain"],
    ),
    SingleTurnCase(
        id="amb_010",
        query="Do I even need a coach?",
        category="ambiguity",
        expected_behavior=(
            "Honest self-awareness. Explains value proposition without "
            "being defensive"
        ),
        gold_standard=(
            "Honest answer about what AI coaching can/cannot do. "
            "Not salesy or dismissive"
        ),
        expected_tools_gemini=[],
        expected_tools_claude=[],
        tags=["meta", "self_awareness"],
    ),
]

# ---------------------------------------------------------------------------
# MULTI-TURN (10 cases)
# ---------------------------------------------------------------------------

MULTI_TURN_CASES: list[MultiTurnCase] = [
    MultiTurnCase(
        id="conv_001",
        turns=[
            Turn("How's my bench?", "Fetches bench progress, reports trend"),
            Turn("What about squat?", "Fetches squat progress, reports trend"),
            Turn(
                "Which should I prioritize?",
                "Compares both, gives data-driven priority",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Carries context from both exercises into prioritization advice"
        ),
        gold_standard=(
            "Final turn references data from both prior analyses. "
            "Prioritization is data-driven"
        ),
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
        tags=["context_carry", "comparison"],
    ),
    MultiTurnCase(
        id="conv_002",
        turns=[
            Turn(
                "Am I overtraining?",
                "Checks training data for overtraining indicators",
            ),
            Turn(
                "But I feel fine",
                "Maintains data-backed position despite pushback",
            ),
            Turn(
                "So should I add more volume?",
                "Nuanced answer based on data, not user pressure",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Holds position if data supports it, despite user pushback"
        ),
        gold_standard=(
            "Does not fold to user's subjective feeling if objective data "
            "says otherwise. Maintains nuanced stance"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["pushback", "data_integrity"],
    ),
    MultiTurnCase(
        id="conv_003",
        turns=[
            Turn(
                "What should I do today?",
                "Checks routine/schedule, suggests today's workout",
            ),
            Turn(
                "I don't have access to a barbell",
                "Adapts recommendation to constraint",
            ),
            Turn("OK do that", "Confirms and summarizes the plan"),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Narrows recommendation based on constraint, confirms plan"
        ),
        gold_standard=(
            "Adapts recommendation to equipment constraint. "
            "Clean confirmation"
        ),
        expected_tools_gemini=["tool_get_planning_context"],
        expected_tools_claude=["get_training_snapshot", "get_routine"],
        tags=["constraint", "planning"],
    ),
    MultiTurnCase(
        id="conv_004",
        turns=[
            Turn(
                "My squat is stuck",
                "Checks squat progress data, identifies stall",
            ),
            Turn(
                "I've tried adding weight",
                "Acknowledges attempt, suggests alternative approaches",
            ),
            Turn(
                "What about front squats?",
                "Evaluates front squat fit for user's situation",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Systematic diagnostic that deepens across turns"
        ),
        gold_standard=(
            "Addresses the user's specific attempt, evaluates front squat "
            "fit for their situation"
        ),
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
        tags=["diagnostic", "progression"],
    ),
    MultiTurnCase(
        id="conv_005",
        turns=[
            Turn("How's my training?", "Gives high-level training overview"),
            Turn(
                "Go deeper",
                "Provides detailed analysis by dimension",
            ),
            Turn(
                "What's the one thing that would make the biggest difference?",
                "Singles out highest-impact recommendation",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Escalates from overview to detail to single priority"
        ),
        gold_standard=(
            "Final answer is specific, singular, and justified by the "
            "deeper analysis"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["depth_escalation"],
    ),
    MultiTurnCase(
        id="conv_006",
        turns=[
            Turn(
                "I want to get bigger arms",
                "Discusses arm training approach",
            ),
            Turn(
                "How many sets am I doing now?",
                "Fetches current arm volume data",
            ),
            Turn(
                "Is that enough?",
                "Evaluates sufficiency based on data and goals",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Follows user's investigation rather than lecturing"
        ),
        gold_standard=(
            "Answers the user's questions directly, lets user drive "
            "the conversation"
        ),
        expected_tools_gemini=["tool_get_muscle_group_progress"],
        expected_tools_claude=["get_muscle_group_progress"],
        tags=["user_driven", "volume"],
    ),
    MultiTurnCase(
        id="conv_007",
        turns=[
            Turn(
                "What exercises hit lats?",
                "Lists lat exercises from catalog",
            ),
            Turn(
                "Add those to my routine",
                "Proposes routine modification",
            ),
            Turn(
                "Wait, which day?",
                "Recommends specific day based on routine structure",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Knowledge -> action -> practical clarification"
        ),
        gold_standard=(
            "Handles the 'which day' question using routine context. "
            "Coherent flow"
        ),
        expected_tools_gemini=["tool_search_exercises"],
        expected_tools_claude=["search_exercises", "get_routine"],
        tags=["knowledge_to_action", "routine"],
    ),
    MultiTurnCase(
        id="conv_008",
        turns=[
            Turn(
                "Rate my last week",
                "Gives honest assessment of last week",
            ),
            Turn(
                "That's harsh",
                "Maintains honest assessment without over-apologizing",
            ),
            Turn(
                "Fine, what should I change?",
                "Provides actionable changes",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Handles emotional pushback gracefully, recovers to "
            "actionable advice"
        ),
        gold_standard=(
            "Does not apologize excessively or retract valid assessment. "
            "Pivots to constructive action"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["emotional", "honest_assessment"],
    ),
    MultiTurnCase(
        id="conv_009",
        turns=[
            Turn(
                "Help me plan my next mesocycle",
                "Outlines mesocycle structure",
            ),
            Turn(
                "What about deloading?",
                "Discusses deload strategy within mesocycle",
            ),
            Turn(
                "When should the deload be?",
                "Specifies deload timing relative to mesocycle",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Complex planning that maintains thread across turns"
        ),
        gold_standard=(
            "Deload timing references the mesocycle structure from turn 1"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["planning", "periodization"],
    ),
    MultiTurnCase(
        id="conv_010",
        turns=[
            Turn(
                "Show me my squat progress",
                "Fetches and displays squat progress",
            ),
            Turn(
                "Now compare that to my deadlift",
                "Fetches deadlift, compares both",
            ),
            Turn(
                "Why is one better than the other?",
                "Synthesizes explanation from both datasets",
            ),
        ],
        category="multi_turn",
        overall_expected_behavior=(
            "Builds analysis incrementally, final turn synthesizes"
        ),
        gold_standard=(
            "Final explanation references specific data from both "
            "prior fetches"
        ),
        expected_tools_gemini=["tool_get_exercise_progress"],
        expected_tools_claude=["get_exercise_progress"],
        tags=["incremental_analysis", "comparison"],
    ),
]

# ---------------------------------------------------------------------------
# STRUCTURE (5 cases)
# ---------------------------------------------------------------------------

STRUCTURE_CASES: list[SingleTurnCase] = [
    SingleTurnCase(
        id="struct_001",
        query=(
            "Give me a full breakdown of my training -- what's working, "
            "what's not, and what to change"
        ),
        category="structure",
        expected_behavior=(
            "Organized analysis with clear sections: working / not working "
            "/ changes"
        ),
        gold_standard=(
            "Well-structured with headers or clear sections. Each point "
            "backed by data. Changes are specific and actionable"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["information_hierarchy"],
    ),
    SingleTurnCase(
        id="struct_002",
        query=(
            "I'm coming back from a 3 week break, walk me through "
            "what I should do"
        ),
        category="structure",
        expected_behavior=(
            "Empathetic acknowledgment + structured return-to-training plan"
        ),
        gold_standard=(
            "Acknowledges break, provides phased plan (week 1: reduced "
            "volume, week 2: ramp up, etc.)"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["empathy", "return_to_training"],
    ),
    SingleTurnCase(
        id="struct_003",
        query=(
            "Compare all my lifts and tell me where I'm strongest and "
            "weakest relative to each other"
        ),
        category="structure",
        expected_behavior=(
            "Multi-exercise comparison with clear ranking"
        ),
        gold_standard=(
            "Organized comparison (table or ranked list). Uses relative "
            "standards (e.g., strength ratios). Clear conclusion"
        ),
        expected_tools_gemini=[
            "tool_get_training_analysis",
            "tool_get_exercise_progress",
        ],
        expected_tools_claude=["get_training_analysis", "get_exercise_progress"],
        tags=["comparison", "ranking"],
    ),
    SingleTurnCase(
        id="struct_004",
        query=(
            "I have a vacation in 6 weeks, help me plan my training "
            "until then"
        ),
        category="structure",
        expected_behavior=(
            "Time-boxed programming with phase structure"
        ),
        gold_standard=(
            "6-week plan with logical phases. Accounts for pre-vacation "
            "taper if relevant"
        ),
        expected_tools_gemini=[
            "tool_get_training_analysis",
            "tool_get_planning_context",
        ],
        expected_tools_claude=["get_training_analysis", "get_training_snapshot"],
        tags=["time_boxed", "planning"],
    ),
    SingleTurnCase(
        id="struct_005",
        query="Explain my training data to me like I'm new to this",
        category="structure",
        expected_behavior=(
            "Adjusts communication level -- explains concepts, avoids jargon"
        ),
        gold_standard=(
            "Uses plain language, explains metrics (e1RM, volume, RIR), "
            "relates to user's actual data"
        ),
        expected_tools_gemini=["tool_get_training_analysis"],
        expected_tools_claude=["get_training_analysis"],
        tags=["communication_level", "education"],
    ),
]

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

AnyCase = Union[SingleTurnCase, MultiTurnCase]

ALL_CASES: list[AnyCase] = (
    CURATED_CASES + AMBIGUITY_CASES + MULTI_TURN_CASES + STRUCTURE_CASES  # type: ignore[operator]
)

CASES_BY_ID: dict[str, AnyCase] = {c.id: c for c in ALL_CASES}


def get_cases(
    category: str | None = None,
    case_id: str | None = None,
    tags: list[str] | None = None,
) -> list[AnyCase]:
    """Filter cases by category, id, or tags."""
    cases = ALL_CASES
    if case_id:
        return [CASES_BY_ID[case_id]] if case_id in CASES_BY_ID else []
    if category:
        cases = [c for c in cases if c.category == category]
    if tags:
        cases = [c for c in cases if any(t in c.tags for t in tags)]
    return cases
