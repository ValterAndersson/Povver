"""Base analyzer with shared LLM call pattern.

Uses google-genai SDK (not google-generativeai) for GCP service account auth.
"""

import json
import logging
import re
import time
from typing import Any, Dict, List, Optional

from google import genai
from google.genai.types import GenerateContentConfig

from app.config import PROJECT_ID

logger = logging.getLogger(__name__)

# Log tracking status at import time so Cloud Logging shows whether it's active
try:
    from shared.usage_tracker import TRACKING_ENABLED as _TRACKING_ENABLED
    logger.info("Training analyst usage tracking: %s",
                "ENABLED" if _TRACKING_ENABLED else "DISABLED")
except ImportError:
    logger.warning("Training analyst: shared.usage_tracker not available")

# Matches dot-path keys like "weeks.2025-01-06.sets" or "weeks.2025-01-06.reps_bucket.6-10"
_WEEKS_DOT_RE = re.compile(r"^weeks\.(\d{4}-\d{2}-\d{2})\.(.+)$")

# Singleton GenAI client (reused across analyzers)
_client: Optional[genai.Client] = None


def _get_genai_client() -> genai.Client:
    """Get or create the GenAI client with GCP project auth."""
    global _client
    if _client is None:
        _client = genai.Client(
            vertexai=True,
            project=PROJECT_ID,
            location="europe-west1",
        )
    return _client


class BaseAnalyzer:
    """Base class for training analyzers.

    Provides shared LLM call pattern with JSON response mode.
    Subclasses implement analyze() with domain-specific logic.
    """

    def __init__(self, model_name: str):
        self.model_name = model_name

    def call_llm(
        self,
        system_prompt: str,
        user_prompt: str,
        temperature: float = 0.2,
        required_keys: Optional[list] = None,
        user_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Call LLM and parse JSON response.

        No max_output_tokens cap — response_mime_type="application/json" ensures
        the model produces well-formed JSON and stops when the object closes.
        Actual outputs are small (300-2000 tokens). A hard cap risks truncation
        which produces invalid JSON or cut-off sentences.

        Args:
            system_prompt: System instructions
            user_prompt: User input with data
            temperature: Generation temperature (default 0.2 for consistency)
            required_keys: Optional list of top-level keys to validate in the
                response. If any are missing, raises ValueError.

        Returns:
            Parsed JSON response dict

        Raises:
            ValueError: If response is empty, truncated, or missing required keys
            json.JSONDecodeError: If response is not valid JSON
        """
        client = _get_genai_client()
        max_retries = 5
        base_delay = 5.0  # seconds

        for attempt in range(max_retries + 1):
            try:
                response = client.models.generate_content(
                    model=self.model_name,
                    contents=[
                        system_prompt.strip(),
                        user_prompt.strip(),
                    ],
                    config=GenerateContentConfig(
                        temperature=temperature,
                        response_mime_type="application/json",
                    ),
                )

                # Check for truncation before parsing
                finish_reason = None
                if response.candidates:
                    finish_reason = response.candidates[0].finish_reason
                if finish_reason and str(finish_reason) == "MAX_TOKENS":
                    logger.error(
                        "LLM response truncated (MAX_TOKENS), model=%s",
                        self.model_name,
                    )
                    raise ValueError(
                        "LLM response was truncated (MAX_TOKENS). "
                        "Output exceeded model limit."
                    )

                text = response.text.strip()
                if not text:
                    raise ValueError("LLM response contained no text")

                data = json.loads(text)

                # Validate required top-level keys
                if required_keys:
                    missing = [k for k in required_keys if k not in data]
                    if missing:
                        logger.error(
                            "LLM response missing required keys %s, model=%s",
                            missing, self.model_name,
                        )
                        raise ValueError(
                            f"LLM response missing required keys: {missing}"
                        )

                # Track LLM usage for cost attribution (fire-and-forget)
                try:
                    from shared.usage_tracker import (
                        extract_usage_from_genai_response,
                        track_usage,
                    )
                    usage = extract_usage_from_genai_response(response)
                    if usage.get("total_tokens"):
                        feature = (
                            self.__class__.__name__
                            .lower()
                            .replace("analyzer", "")
                        )
                        track_usage(
                            user_id=user_id,
                            category="user_scoped",
                            system="training_analyst",
                            feature=feature,
                            model=self.model_name,
                            **usage,
                        )
                except Exception as track_err:
                    logger.debug("Usage tracking error (non-fatal): %s", track_err)

                logger.info("LLM call succeeded, model=%s", self.model_name)
                return data

            except Exception as e:
                error_str = str(e)
                is_rate_limit = "429" in error_str or "RESOURCE_EXHAUSTED" in error_str
                if is_rate_limit and attempt < max_retries:
                    delay = base_delay * (2 ** attempt)
                    logger.warning(
                        "Rate limited (attempt %d/%d), retrying in %.0fs: %s",
                        attempt + 1, max_retries, delay, e,
                    )
                    time.sleep(delay)
                    continue
                logger.error("LLM call failed (model=%s): %s", self.model_name, e)
                raise

    @staticmethod
    def extract_weeks_map(data: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
        """Extract weeks map from a series document, handling both formats.

        Series docs can store weekly data in two ways:
        1. Nested map: data["weeks"]["2025-01-06"]["sets"] = 5
        2. Dot-path keys: data["weeks.2025-01-06.sets"] = 5

        Some docs have both (older docs migrated). This merges them,
        preferring nested map values when both exist for the same field.
        """
        weeks_map = {}

        # Source 1: nested map (if present and populated)
        nested = data.get("weeks")
        if isinstance(nested, dict) and nested:
            for week_id, week_data in nested.items():
                if isinstance(week_data, dict):
                    weeks_map[week_id] = dict(week_data)

        # Source 2: dot-path top-level keys
        for key, value in data.items():
            m = _WEEKS_DOT_RE.match(key)
            if not m:
                continue
            week_id = m.group(1)
            field_path = m.group(2)

            if week_id not in weeks_map:
                weeks_map[week_id] = {}

            # Handle nested dot-paths like "reps_bucket.6-10"
            parts = field_path.split(".")
            if len(parts) == 1:
                # Only set if not already present from nested map
                if parts[0] not in weeks_map[week_id]:
                    weeks_map[week_id][parts[0]] = value
            else:
                # Nested field (e.g., reps_bucket.6-10)
                parent = parts[0]
                child = ".".join(parts[1:])
                if parent not in weeks_map[week_id]:
                    weeks_map[week_id][parent] = {}
                if isinstance(weeks_map[week_id][parent], dict):
                    if child not in weeks_map[week_id][parent]:
                        weeks_map[week_id][parent][child] = value

        return weeks_map

    def _compute_fatigue_metrics(
        self, rollups_map: Dict[str, Dict[str, Any]]
    ) -> Optional[Dict[str, Any]]:
        """Compute fatigue metrics (ACWR) from rollups.

        Mirrors JS get-features.js:attachFatigueMetrics() logic.
        Uses load_per_muscle (falls back to hard_sets_per_muscle if absent).

        Args:
            rollups_map: Dict of rollups keyed by week_id (YYYY-MM-DD)

        Returns:
            Structured fatigue metrics dict with systemic + per_muscle ACWR,
            or None if fewer than 2 weeks of data
        """
        if len(rollups_map) < 2:
            return None

        # Sort weeks chronologically
        sorted_weeks = sorted(rollups_map.keys())

        # Extract load_per_muscle (or fallback to hard_sets_per_muscle)
        # These fields are at the top level of rollup docs, not nested under "intensity"
        all_muscles = set()
        for wk_data in rollups_map.values():
            load_map = wk_data.get("load_per_muscle") or wk_data.get("hard_sets_per_muscle", {})
            all_muscles.update(load_map.keys())

        if not all_muscles:
            return None

        # Most recent week = acute
        acute_week = sorted_weeks[-1]
        acute_data = rollups_map[acute_week]
        acute_load = acute_data.get("load_per_muscle") or acute_data.get("hard_sets_per_muscle", {})

        # Previous 4 weeks (or all available) = chronic
        chronic_weeks = sorted_weeks[:-1][-4:]
        chronic_loads = {}
        for muscle in all_muscles:
            loads = []
            for wk in chronic_weeks:
                wk_rollup = rollups_map[wk]
                wk_load = wk_rollup.get("load_per_muscle") or wk_rollup.get("hard_sets_per_muscle", {})
                loads.append(wk_load.get(muscle, 0))
            chronic_loads[muscle] = sum(loads) / len(loads) if loads else 0

        # Compute per-muscle ACWR
        per_muscle = []
        systemic_acute = 0
        systemic_chronic = 0

        for muscle in sorted(all_muscles):
            acute_val = acute_load.get(muscle, 0)
            chronic_val = chronic_loads[muscle]

            acwr = None
            if chronic_val > 0:
                acwr = round(acute_val / chronic_val, 2)

            per_muscle.append({
                "muscle": muscle,
                "acute": acute_val,
                "chronic": round(chronic_val, 1),
                "acwr": acwr,
            })

            systemic_acute += acute_val
            systemic_chronic += chronic_val

        # Systemic ACWR
        systemic_acwr = None
        if systemic_chronic > 0:
            systemic_acwr = round(systemic_acute / systemic_chronic, 2)

        return {
            "systemic": {
                "acute": systemic_acute,
                "chronic": round(systemic_chronic, 1),
                "acwr": systemic_acwr,
            },
            "per_muscle": per_muscle,
        }

    def _extract_rep_range(self, sets: List[Dict[str, Any]]) -> str:
        """Extract rep range string from sets (e.g., '6-10' or '8')."""
        reps_list = []
        for s in sets:
            r = s.get("target_reps") if s.get("target_reps") is not None else s.get("reps")
            if isinstance(r, (int, float)) and r > 0:
                reps_list.append(int(r))
        if not reps_list:
            return ""
        mn, mx = min(reps_list), max(reps_list)
        return str(mn) if mn == mx else f"{mn}-{mx}"

    def _extract_weight_range(self, sets: List[Dict[str, Any]]) -> str:
        """Extract weight range string from sets (e.g., '60-80kg' or '60kg')."""
        weights = []
        for s in sets:
            w = s.get("weight_kg") if s.get("weight_kg") is not None else s.get("weight")
            if isinstance(w, (int, float)) and w > 0:
                weights.append(w)
        if not weights:
            return ""
        mn, mx = min(weights), max(weights)
        if mn == mx:
            return f"{round(mn)}kg"
        return f"{round(mn)}-{round(mx)}kg"

    def log_event(self, event: str, **kwargs):
        """Log structured event for Cloud Logging."""
        record = {
            "event": event,
            "analyzer": self.__class__.__name__,
        }
        record.update(kwargs)
        logger.info(json.dumps(record))
