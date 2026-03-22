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
