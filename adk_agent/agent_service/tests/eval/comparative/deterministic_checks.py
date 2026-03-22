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
