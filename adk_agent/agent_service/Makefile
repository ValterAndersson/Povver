.PHONY: help install test dev deploy lint format check smoke

PROJECT_ID ?= myon-53d85
REGION ?= us-central1
IMAGE_TAG ?= latest
SERVICE_NAME ?= agent-service

help:
	@echo "Agent Service"
	@echo "============="
	@echo ""
	@echo "Development:"
	@echo "  make install    - Install dependencies"
	@echo "  make test       - Run tests"
	@echo "  make dev        - Run locally"
	@echo "  make lint       - Run linter"
	@echo "  make format     - Format code"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy     - Build + deploy to Cloud Run"

install:
	pip install -r requirements.txt

test:
	python -m pytest tests/ -v --ignore=tests/test_smoke.py

smoke:
	@echo "Running smoke tests against $${SMOKE_URL:?Set SMOKE_URL (e.g. http://localhost:8080)}"
	SMOKE_URL=$${SMOKE_URL} SMOKE_USER_ID=$${SMOKE_USER_ID:-} MYON_API_KEY=$${MYON_API_KEY:-} \
		python -m pytest tests/test_smoke.py -v --tb=short

dev:
	uvicorn app.main:app --reload --port 8080

lint:
	python -m ruff check app/ tests/

format:
	python -m ruff format app/ tests/

deploy:
	cp -r ../shared shared/
	gcloud builds submit --tag gcr.io/$(PROJECT_ID)/$(SERVICE_NAME):$(IMAGE_TAG) --project=$(PROJECT_ID); \
	rm -rf shared/
	gcloud run deploy $(SERVICE_NAME) \
		--project $(PROJECT_ID) \
		--image gcr.io/$(PROJECT_ID)/$(SERVICE_NAME):$(IMAGE_TAG) \
		--region $(REGION) \
		--platform managed \
		--no-allow-unauthenticated \
		--memory 512Mi \
		--cpu 1 \
		--min-instances 0 \
		--max-instances 10 \
		--timeout 300 \
		--concurrency 1 \
		--service-account ai-agents@$(PROJECT_ID).iam.gserviceaccount.com \
		--set-env-vars "PROJECT_ID=$(PROJECT_ID),GOOGLE_CLOUD_PROJECT=$(PROJECT_ID),GOOGLE_CLOUD_LOCATION=$${GOOGLE_CLOUD_LOCATION:-global},ENABLE_USAGE_TRACKING=true,CONVERSATION_COLLECTION=conversations,AGENT_MODEL=$${AGENT_MODEL:-gemini-3-flash-preview},MYON_API_KEY=$${MYON_API_KEY:?Set MYON_API_KEY env var},MYON_FUNCTIONS_BASE_URL=$${MYON_FUNCTIONS_BASE_URL:-https://us-central1-myon-53d85.cloudfunctions.net}"
