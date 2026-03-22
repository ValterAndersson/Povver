# test_smoke.py
"""Smoke test — validates the full eval pipeline with mocked responses."""
import asyncio
import json
import pytest
from unittest.mock import AsyncMock, patch, MagicMock

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

    with patch("comparative.judge.AsyncAnthropicVertex") as mock_anthropic:
        mock_msg = MagicMock()
        mock_msg.content = [MagicMock(text=mock_judge_response)]
        mock_anthropic.return_value.messages.create = AsyncMock(return_value=mock_msg)

        result = await run_single_case(
            case, mock_gemini, mock_claude, "test-user"
        )

    assert result.case_id == "cur_001"
    assert result.comparison.winner == "claude"
    assert result.gemini.overall > 0
    assert result.claude.overall > 0

    # Test summary generation
    summary = build_summary([result], "test-run")
    assert summary.cases_total == 1
    assert summary.claude_wins == 1
