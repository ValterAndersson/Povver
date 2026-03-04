# Shared Agent Utilities

Cross-agent utilities shared by `canvas_orchestrator`, `catalog_orchestrator`, and `training_analyst`.

## Files

- `usage_tracker.py` — LLM usage tracking. Captures token counts from Vertex AI responses and writes to Firestore `llm_usage` collection. All writes are fire-and-forget (failures logged, never crash the caller). Gated by `ENABLE_USAGE_TRACKING` env var. Logs tracking status at import time for Cloud Logging visibility. Shell agent tracking uses `after_model_callback` which calls `track_usage()` directly per LLM turn (ContextVar doesn't work across ADK's thread boundary — `Runner.run()` spawns a separate thread). Training analyst and functional lane use direct `extract_usage_from_*_response()` helpers on non-streaming responses.
- `llm_pricing.py` — Vertex AI Gemini pricing rates (EUR per 1M tokens). Used by the query script (`scripts/query_llm_usage.js`) and available for Python-based cost estimation. Update when Google publishes new rates.

## Import Path

Each agent system makes `shared/` importable differently:

| System | Mechanism |
|--------|-----------|
| Canvas Orchestrator | `PYTHONPATH=.:..` (Makefile) + `cp -r ../shared ./shared` before deploy (tarball rejects `..` paths) + `extra_packages=["./app", "./shared"]` |
| Catalog Orchestrator | `cp -r ../shared shared/` before Docker build (Makefile `cloud-build`) |
| Training Analyst | Same as Catalog |

Import as: `from shared.usage_tracker import track_usage`
