install:
	python3 -m pip install -r agent_engine_requirements.txt

# GCP SA key for Vertex AI operations (agent deploy, Cloud Run)
# Resolves: explicit env var > named alias > hardcoded path
GCP_SA_KEY_PATH := $(or $(GOOGLE_APPLICATION_CREDENTIALS),$(GCP_SA_KEY),$(HOME)/.config/povver/myon-53d85-80792c186dcb.json)

deploy:
	@# Pre-flight: verify SA key exists
	@test -f "$(GCP_SA_KEY_PATH)" || \
		(echo "ERROR: GCP SA key not found at $(GCP_SA_KEY_PATH)"; \
		 echo "Set GOOGLE_APPLICATION_CREDENTIALS or GCP_SA_KEY, or place key at ~/.config/povver/myon-53d85-80792c186dcb.json"; \
		 exit 1)
	@echo "Using SA key: $(GCP_SA_KEY_PATH)"
	@# Copy shared package locally (Agent Engine tarball rejects .. paths)
	rm -rf ./shared && cp -r ../shared ./shared
	GOOGLE_APPLICATION_CREDENTIALS="$(GCP_SA_KEY_PATH)" \
	PYTHONPATH=.:.. python3 -m app.agent_engine_app \
		--project myon-53d85 \
		--location us-central1 \
		--agent-name canvas-orchestrator \
		--set-env-vars FIREBASE_API_KEY=$${FIREBASE_API_KEY:?Set FIREBASE_API_KEY env var},MYON_API_KEY=$${MYON_API_KEY:?Set MYON_API_KEY env var},MYON_FUNCTIONS_BASE_URL=$${MYON_FUNCTIONS_BASE_URL:-https://us-central1-myon-53d85.cloudfunctions.net},PIPELINE_USER_ID=$${PIPELINE_USER_ID:-canvas_orchestrator_engine},ENABLE_USAGE_TRACKING=true
	@# Clean up local copy
	rm -rf ./shared

bootstrap:
	@USER_ID=$${USER_ID:-canvas_orchestrator_engine}; \
	PURPOSE=$${PURPOSE:-workout}; \
	BASE=$${MYON_FUNCTIONS_BASE_URL:-https://us-central1-myon-53d85.cloudfunctions.net}; \
	KEY=$${FIREBASE_API_KEY:?Set FIREBASE_API_KEY env var}; \
	CANVAS_ID=$$(curl -s -X POST "$$BASE/bootstrapCanvas" -H "X-API-Key: $$KEY" -H "Content-Type: application/json" -d '{"userId":"'"$$USER_ID"'","purpose":"'"$$PURPOSE"'"}' | jq -r '.data.canvasId'); \
	echo "Bootstrapped canvas: $$CANVAS_ID"; \
	export TEST_CANVAS_ID=$$CANVAS_ID; \
	( [ -n "$$CANVAS_ID" ] && echo $$CANVAS_ID > .canvas_id ) || true

chat:
	python3 interactive_chat.py

inspect:
	python3 scripts/inspect_canvas.py --user-id $${USER_ID:-$${PIPELINE_USER_ID:-canvas_orchestrator_engine}} --canvas-id $${CANVAS_ID:-$${TEST_CANVAS_ID:-}} --limit $${LIMIT:-10}

# =============================================================================
# EVAL — Shell Agent quality evaluation
# =============================================================================

# Run full eval suite (55 cases via SSE → LLM judge scoring)
eval:
	GOOGLE_APPLICATION_CREDENTIALS="$(GCP_SA_KEY_PATH)" \
	PYTHONPATH=.:.. python3 tests/eval/runner.py

# Run eval for a specific category (easy, moderate, complex, edge, active_workout)
eval-category:
	@echo "Usage: make eval-category CAT=edge"
	GOOGLE_APPLICATION_CREDENTIALS="$(GCP_SA_KEY_PATH)" \
	PYTHONPATH=.:.. python3 tests/eval/runner.py --filter category=$${CAT:-easy}

# Run a single eval test case
eval-single:
	@echo "Usage: make eval-single ID=easy_001"
	GOOGLE_APPLICATION_CREDENTIALS="$(GCP_SA_KEY_PATH)" \
	PYTHONPATH=.:.. python3 tests/eval/runner.py --id $${ID:-easy_001}

# Analyze latest eval run
eval-analyze:
	PYTHONPATH=.:.. python3 tests/eval/analyze.py

# Compare two eval runs
eval-compare:
	@echo "Usage: make eval-compare B=eval_20240101_120000 N=eval_20240102_120000"
	PYTHONPATH=.:.. python3 tests/eval/analyze.py --compare \
		tests/eval/results/$${B}.jsonl tests/eval/results/$${N}.jsonl
