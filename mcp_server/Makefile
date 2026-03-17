.PHONY: help install build test dev deploy

PROJECT_ID ?= myon-53d85
REGION ?= us-central1
SERVICE_NAME ?= mcp-server

help:
	@echo "MCP Server"
	@echo "=========="
	@echo "  make install  - Install dependencies"
	@echo "  make build    - Build TypeScript"
	@echo "  make test     - Run tests"
	@echo "  make dev      - Run locally"
	@echo "  make deploy   - Build + deploy to Cloud Run"

install:
	npm install

build:
	npm run build

test:
	npm run build && npm test

dev:
	npm run dev

deploy: build
	cp -r ../firebase_functions/functions/shared shared/
	gcloud run deploy $(SERVICE_NAME) \
		--source . \
		--region $(REGION) \
		--platform managed \
		--allow-unauthenticated \
		--service-account ai-agents@$(PROJECT_ID).iam.gserviceaccount.com \
		--set-env-vars "GOOGLE_CLOUD_PROJECT=$(PROJECT_ID)" \
		--memory 256Mi \
		--cpu 1 \
		--min-instances 0 \
		--max-instances 5 \
		--timeout 60
	rm -rf shared/
