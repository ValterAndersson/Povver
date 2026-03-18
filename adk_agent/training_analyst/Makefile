# Training Analyst Makefile
# =========================

.PHONY: help install test analyst-local worker-local watchdog-local scheduler-local \
        docker-push deploy-worker deploy-watchdog deploy-scheduler \
        trigger-worker trigger-watchdog trigger-scheduler deploy deploy-schedulers \
        eval eval-category eval-single eval-analyze eval-compare

# Configuration
PROJECT_ID ?= myon-53d85
REGION ?= europe-west1
IMAGE_TAG ?= latest

help:
	@echo "Training Analyst"
	@echo "================"
	@echo ""
	@echo "Development:"
	@echo "  make install         - Install dependencies"
	@echo "  make test            - Run tests"
	@echo ""
	@echo "Local Testing:"
	@echo "  make analyst-local   - Run post-workout analyst locally (needs USER_ID, WORKOUT_ID)"
	@echo "  make worker-local    - Run worker locally"
	@echo "  make watchdog-local  - Run watchdog locally"
	@echo "  make scheduler-local - Run scheduler locally"
	@echo ""
	@echo "Eval Suite:"
	@echo "  make eval            - Run all eval tests"
	@echo "  make eval-category CAT=<category> - Run specific category"
	@echo "  make eval-single ID=<id> - Run single test case"
	@echo "  make eval-analyze    - Analyze eval results"
	@echo "  make eval-compare -B <baseline> -N <new> - Compare two runs"
	@echo ""
	@echo "Docker:"
	@echo "  make docker-push     - Build and push to GCR (via Cloud Build)"
	@echo ""
	@echo "Cloud Run Jobs:"
	@echo "  make deploy          - Deploy all jobs"
	@echo "  make deploy-worker   - Deploy worker job"
	@echo "  make deploy-watchdog - Deploy watchdog job"
	@echo "  make deploy-scheduler - Deploy scheduler job"
	@echo "  make deploy-schedulers - Create Cloud Scheduler triggers (run after deploy)"
	@echo "  make trigger-worker  - Trigger worker execution"
	@echo "  make trigger-watchdog - Trigger watchdog execution"
	@echo "  make trigger-scheduler - Trigger scheduler execution"

# Install dependencies
install:
	pip install -r worker_requirements.txt

# Run tests
test:
	python -m pytest tests/ -v

# Eval suite
eval:
	python -m tests.eval.runner

eval-category:
	python -m tests.eval.runner --filter category=$(CAT)

eval-single:
	python -m tests.eval.runner --id $(ID)

eval-analyze:
	python -m tests.eval.analyze

eval-compare:
	python -m tests.eval.analyze --compare -B $(B) -N $(N)

# Run post-workout analyst locally
analyst-local:
	python workers/post_workout_analyst.py --user-id $(USER_ID) --workout-id $(WORKOUT_ID) --dry-run

# Run worker locally
worker-local:
	python workers/analyst_worker.py

# Run watchdog locally
watchdog-local:
	WATCHDOG_DRY_RUN=true python workers/analyst_worker.py watchdog

# Run scheduler locally
scheduler-local:
	python workers/scheduler.py

# Build and push via Cloud Build (builds natively on amd64, avoids arm64 issues on Apple Silicon)
# Copies shared/ into build context (Docker can't COPY from parent dirs)
docker-push:
	cp -r ../shared shared/
	gcloud builds submit --tag gcr.io/$(PROJECT_ID)/training-analyst-worker:$(IMAGE_TAG) --project=$(PROJECT_ID); \
	rm -rf shared/

# Deploy worker job
deploy-worker:
	@echo "Deploying training-analyst-worker to Cloud Run Jobs..."
	gcloud run jobs replace cloud-run-worker.yaml --region=$(REGION) --project=$(PROJECT_ID)

# Deploy watchdog job
deploy-watchdog:
	@echo "Deploying training-analyst-watchdog to Cloud Run Jobs..."
	gcloud run jobs replace cloud-run-watchdog.yaml --region=$(REGION) --project=$(PROJECT_ID)

# Deploy scheduler job
deploy-scheduler:
	@echo "Deploying training-analyst-scheduler to Cloud Run Jobs..."
	gcloud run jobs replace cloud-run-scheduler.yaml --region=$(REGION) --project=$(PROJECT_ID)

# Trigger worker execution
trigger-worker:
	gcloud run jobs execute training-analyst-worker --region=$(REGION) --project=$(PROJECT_ID) --wait

# Trigger watchdog execution
trigger-watchdog:
	gcloud run jobs execute training-analyst-watchdog --region=$(REGION) --project=$(PROJECT_ID) --wait

# Trigger scheduler execution
trigger-scheduler:
	gcloud run jobs execute training-analyst-scheduler --region=$(REGION) --project=$(PROJECT_ID) --wait

# Deploy all jobs
deploy: docker-push deploy-worker deploy-watchdog deploy-scheduler
	@echo "All Cloud Run Jobs deployed"

# Deploy Cloud Scheduler triggers (run AFTER deploy)
deploy-schedulers:
	@echo "Creating Cloud Scheduler triggers..."
	bash deploy-schedulers.sh
