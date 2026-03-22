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

# Deployed service URLs
AGENT_SERVICE_URL = "https://agent-service-jt35xlatqq-uc.a.run.app"
MCP_SERVER_URL = "https://mcp-server-jt35xlatqq-uc.a.run.app"
DEFAULT_USER_ID = "xLRyVOI0XKSFsTXSFbGSvui8FJf2"


async def run_single_case(
    case,
    gemini: GeminiBackend,
    claude: ClaudeBackend,
    user_id: str,
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
    case, gemini, claude, user_id, samples: int
) -> CaseResult:
    """Run a case N times and keep the best result (optimistic sampling)."""
    best: CaseResult | None = None
    for s in range(samples):
        result = await run_with_retry(
            lambda: run_single_case(case, gemini, claude, user_id)
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
    parser.add_argument("--gemini-url", default=os.getenv("EVAL_GEMINI_URL", AGENT_SERVICE_URL), help="Agent service URL")
    parser.add_argument("--mcp-url", default=os.getenv("EVAL_MCP_URL", MCP_SERVER_URL), help="MCP server URL")
    parser.add_argument("--user-id", default=os.getenv("EVAL_USER_ID", DEFAULT_USER_ID), help="Test user ID")
    args = parser.parse_args()
    args.parallel = min(args.parallel, 5)  # Cap per spec

    # MCP API key for tool execution (test user's key)
    mcp_api_key = os.environ["EVAL_MCP_API_KEY"]

    # GCP_SA_KEY is required for Cloud Run IAM auth (Gemini backend)
    if not os.environ.get("GCP_SA_KEY"):
        raise RuntimeError("GCP_SA_KEY env var must point to the GCP service account key file")

    gemini = GeminiBackend(args.gemini_url)
    claude = ClaudeBackend(args.mcp_url, mcp_api_key)

    cases = get_cases(category=args.category, case_id=args.id)
    logger.info("Running %d cases (%d samples each)", len(cases), args.samples)

    # Run cases with concurrency limit
    sem = asyncio.Semaphore(args.parallel)

    async def run_with_limit(case):
        async with sem:
            return await run_case_with_samples(
                case, gemini, claude, args.user_id, args.samples
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
        insights = await generate_insights(run_dir)
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
