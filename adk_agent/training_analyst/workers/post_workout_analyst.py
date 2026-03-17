#!/usr/bin/env python3
"""
Post-Workout Analyst - Background worker for workout analysis.

Lane 4: Worker Lane
- Trigger: PubSub event when workout completes
- Model: gemini-2.5-pro (for deep analysis)
- Output: Insight Card written to Firestore

Moved from canvas_orchestrator to training_analyst (Task 39b).
All skill imports replaced with direct httpx calls to Firebase Functions,
so this worker is self-contained and does not depend on canvas_orchestrator.

Usage:
    # Triggered by PubSub
    python post_workout_analyst.py --user-id USER_ID --workout-id WORKOUT_ID

    # Or via Cloud Run Job with environment variables
    USER_ID=xxx WORKOUT_ID=yyy python post_workout_analyst.py

Environment:
    GOOGLE_PROJECT: GCP project ID
    MYON_FUNCTIONS_BASE_URL: Firebase functions base URL
    MYON_API_KEY: Server-to-server API key
    GEMINI_API_KEY: Optional - for local development only

Note: When running on GCP (Cloud Run, Vertex), uses Application Default
Credentials (ADC). For local dev, can use GEMINI_API_KEY fallback.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional

import httpx

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger("post_workout_analyst")

# Firebase Functions base URL and API key
FUNCTIONS_URL = os.getenv(
    "MYON_FUNCTIONS_BASE_URL",
    "https://us-central1-myon-53d85.cloudfunctions.net",
)
MYON_API_KEY = os.getenv("MYON_API_KEY", "")


# =============================================================================
# INSIGHT CARD DATA STRUCTURE
# =============================================================================

@dataclass
class InsightCard:
    """Insight generated from workout analysis."""

    card_type: str = "insight"
    title: str = ""
    body: str = ""
    severity: str = "info"  # info, warning, action
    insight_type: str = ""  # stall, volume_imbalance, overreach, recovery
    data: Dict[str, Any] = None
    created_at: str = None

    def __post_init__(self):
        if self.data is None:
            self.data = {}
        if self.created_at is None:
            self.created_at = datetime.utcnow().isoformat() + "Z"

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


# =============================================================================
# HTTP SKILL WRAPPERS
# These call Firebase Functions directly via httpx, replacing the
# canvas_orchestrator skill imports.
# =============================================================================

async def _api_call(endpoint: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """Call a Firebase Function endpoint with the server API key."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/{endpoint}",
            json=payload,
            headers={"x-api-key": MYON_API_KEY},
        )
        resp.raise_for_status()
        return resp.json()


async def get_training_analysis(user_id: str) -> Dict[str, Any]:
    """Fetch pre-computed training analysis (weekly review + insights)."""
    return await _api_call("getTrainingAnalysis", {"userId": user_id})


async def get_training_context(user_id: str) -> Dict[str, Any]:
    """Fetch training context (routine structure, current program)."""
    return await _api_call("getTrainingContext", {"userId": user_id})


async def apply_progression(
    user_id: str, changes: list, **kwargs: Any
) -> Dict[str, Any]:
    """Apply progression changes to a user's program."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/applyProgression",
            json={
                "userId": user_id,
                "changes": changes,
                **kwargs,
            },
            headers={"x-api-key": MYON_API_KEY},
        )
        return resp.json()


# =============================================================================
# ANALYSIS LOGIC
# =============================================================================

async def fetch_user_data(user_id: str, workout_id: str) -> Dict[str, Any]:
    """
    Fetch all data needed for analysis via Firebase Functions.
    """
    logger.info("Fetching data via httpx for user %s", user_id)

    try:
        coaching = await get_training_analysis(user_id)
    except Exception as e:
        logger.error("Failed to fetch training analysis: %s", e)
        coaching = None

    try:
        context = await get_training_context(user_id)
    except Exception as e:
        logger.error("Failed to fetch training context: %s", e)
        context = None

    return {
        "coaching": coaching,
        "context": context,
    }


def analyze_workout(user_id: str, workout_id: str) -> Optional[InsightCard]:
    """
    Analyze completed workout for actionable insights.

    Uses gemini-2.5-pro for deep analysis of training patterns.

    Looks for:
    - Stalled exercises (e1RM slope < 0 for 4+ weeks)
    - Volume imbalances (significant deviation from plan)
    - Overreach signals (excessive RIR accumulation)
    - Recovery needs (form degradation patterns)

    Returns:
        InsightCard if intervention needed, None otherwise
    """
    logger.info("Analyzing workout %s for user %s", workout_id, user_id)

    # 1. Fetch data via httpx
    data = asyncio.run(fetch_user_data(user_id, workout_id))

    if not data.get("coaching") or not data.get("context"):
        logger.warning("Insufficient data for analysis")
        return None

    # 2. Build analysis prompt
    prompt = f"""Analyze this user's recent training data. Look for patterns that require coaching intervention.

USER DATA:
Coaching Context (12 weeks): {json.dumps(data.get("coaching", {}), indent=2)}

Training Context: {json.dumps(data.get("context", {}), indent=2)}

ANALYSIS CRITERIA:

1. STALL DETECTION
   - Exercise where e1RM slope < 0 for 4+ consecutive weeks
   - Significant reduction in working weight without intentional deload

2. VOLUME IMBALANCE
   - Sets completed significantly below planned (adherence < 80%)
   - Muscle group receiving < 50% of target volume

3. OVERREACH SIGNALS
   - RIR consistently 2+ higher than planned
   - Performance declining across multiple exercises

4. RECOVERY NEEDS
   - Session RPE increasing while performance decreasing
   - Form degradation signals (weight drops mid-session)

OUTPUT RULES:
- If ANY intervention is needed, output a JSON InsightCard
- If NO intervention needed, output: {{"insight": null}}

InsightCard format:
{{
    "insight": {{
        "title": "Brief, actionable title",
        "body": "2-3 sentence explanation with specific data",
        "severity": "info|warning|action",
        "insight_type": "stall|volume_imbalance|overreach|recovery",
        "data": {{
            "exercise": "affected exercise name",
            "weeks_affected": 4,
            "recommendation": "specific action to take"
        }}
    }}
}}
"""

    # 3. Call Gemini Pro for analysis
    # Use Vertex AI for GCP deployments (ADC), fallback to genai for local dev
    try:
        # Try Vertex AI first (for Cloud Run / GCP environment)
        try:
            import vertexai
            from vertexai.generative_models import GenerativeModel, GenerationConfig

            # Initialize with ADC (Application Default Credentials)
            project = os.getenv("GOOGLE_PROJECT") or os.getenv("GCP_PROJECT")
            location = os.getenv("GOOGLE_LOCATION", "us-central1")
            if project:
                vertexai.init(project=project, location=location)
            else:
                vertexai.init()  # Uses default project from ADC

            model = GenerativeModel("gemini-2.5-pro")
            response = model.generate_content(
                prompt,
                generation_config=GenerationConfig(
                    temperature=0.2,  # Low temp for analytical precision
                    response_mime_type="application/json",
                ),
            )
            logger.info("Using Vertex AI (ADC)")

        except Exception as vertex_err:
            # Fallback to google-generativeai for local development
            logger.warning("Vertex AI init failed (%s), falling back to genai", vertex_err)
            import google.generativeai as genai

            api_key = os.getenv("GEMINI_API_KEY")
            if api_key:
                genai.configure(api_key=api_key)

            model = genai.GenerativeModel(
                "gemini-2.5-pro",
                generation_config={
                    "temperature": 0.2,
                    "response_mime_type": "application/json",
                },
            )
            response = model.generate_content(prompt)
            logger.info("Using google-generativeai (API key)")
        result = json.loads(response.text)

        insight_data = result.get("insight")

        if insight_data is None:
            logger.info("No insight needed for workout %s", workout_id)
            return None

        # Build InsightCard from response
        return InsightCard(
            title=insight_data.get("title", "Training Insight"),
            body=insight_data.get("body", ""),
            severity=insight_data.get("severity", "info"),
            insight_type=insight_data.get("insight_type", "general"),
            data=insight_data.get("data", {}),
        )

    except Exception as e:
        logger.error("Analysis failed: %s", e)
        return None


def write_insight_card(user_id: str, card: InsightCard) -> bool:
    """
    Write InsightCard to Firestore.

    Target collection: users/{user_id}/insights/{auto_id}

    TODO: Implement actual Firestore write.
    For now, this is a mock that logs the card.
    """
    logger.info("=" * 60)
    logger.info("INSIGHT CARD GENERATED")
    logger.info("=" * 60)
    logger.info("User: %s", user_id)
    logger.info("Title: %s", card.title)
    logger.info("Severity: %s", card.severity)
    logger.info("Type: %s", card.insight_type)
    logger.info("Body: %s", card.body)
    logger.info("Data: %s", json.dumps(card.data, indent=2))
    logger.info("=" * 60)

    # TODO: Actual Firestore write
    # from google.cloud import firestore
    # db = firestore.Client()
    # db.collection("users").document(user_id).collection("insights").add(card.to_dict())

    return True


# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

def main():
    """
    Main entry point for the post-workout analyst.

    Can be triggered by:
    - Command line arguments
    - Environment variables (for Cloud Run Job)
    - PubSub message parsing (for Cloud Functions trigger)
    """
    parser = argparse.ArgumentParser(
        description="Post-Workout Analyst - Generate insights from workout data"
    )
    parser.add_argument(
        "--user-id",
        help="User ID to analyze",
        default=os.getenv("USER_ID"),
    )
    parser.add_argument(
        "--workout-id",
        help="Workout ID that triggered analysis",
        default=os.getenv("WORKOUT_ID"),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run analysis but don't write to Firestore",
    )

    args = parser.parse_args()

    if not args.user_id or not args.workout_id:
        logger.error("user-id and workout-id are required")
        sys.exit(1)

    logger.info("Starting post-workout analysis")
    logger.info("User: %s, Workout: %s", args.user_id, args.workout_id)

    # Run analysis
    insight = analyze_workout(args.user_id, args.workout_id)

    if insight:
        if args.dry_run:
            logger.info("DRY RUN - Would write insight: %s", insight.title)
            print(json.dumps(insight.to_dict(), indent=2))
        else:
            success = write_insight_card(args.user_id, insight)
            if success:
                logger.info("Insight card written successfully")
            else:
                logger.error("Failed to write insight card")
                sys.exit(1)
    else:
        logger.info("No insight generated - training is on track")

    logger.info("Analysis complete")


if __name__ == "__main__":
    main()
