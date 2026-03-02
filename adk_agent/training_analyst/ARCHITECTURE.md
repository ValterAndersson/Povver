# Training Analyst Service Architecture

## Overview

The Training Analyst Service provides automated AI-powered analysis of user training data. It runs as a set of Cloud Run Jobs that process analysis jobs from a Firestore queue.

## Components

### Job Queue (`app/jobs/`)

Firestore-backed job queue with lease-based concurrency control.

**Collection**: `training_analysis_jobs`

**Job Types**:
- `POST_WORKOUT`: Immediate post-workout analysis
- `WEEKLY_REVIEW`: Weekly comprehensive review

**Key Files**:
- `models.py`: Job, JobPayload, JobStatus, JobType
- `queue.py`: Job creation, polling, leasing, completion
- `watchdog.py`: Stuck job recovery

**Job Lifecycle**:
1. `QUEUED` → Created, ready to process
2. `LEASED` → Claimed by worker
3. `RUNNING` → Actively processing
4. `SUCCEEDED` or `FAILED` → Terminal states

**No Family Locks**: Unlike catalog_orchestrator, training analysis jobs are user-scoped and don't require family locks (no conflicts).

### Analyzers (`app/analyzers/`)

Two specialized analyzers with distinct data budgets and LLM models.

**Base Analyzer** (`base.py`):
- Shared LLM client (`google.genai` SDK with Vertex AI backend)
- Structured logging
- JSON response parsing (response_mime_type="application/json")

**Post-Workout Analyzer** (`post_workout.py`):
- Model: `gemini-2.5-pro` (temperature=0.2)
- Budget: ~18KB total
- Reads: trimmed workout (~1.5KB) + 8 weeks rollups (~4KB) + 8 weeks exercise series (~10KB) + routine summary with full exercise lists (~4KB) + exercise catalog (~1KB) + fatigue metrics (deterministic ACWR)
- Writes: `users/{uid}/analysis_insights/{autoId}` (TTL 7 days)
- Output: summary, typed highlights, severity-flagged issues, confidence-scored recommendations
- Recommendation types: `progression`, `deload`, `swap`, `volume_adjust`, `rep_progression`
- Uses double progression model: reps increase before weight increase when user hasn't hit target reps
- RIR is diagnostic only — high RIR triggers weight progression, not a standalone RIR adjustment
- Optional output fields: `suggested_weight`, `target_reps`, `sets_delta`
- Evidence-based training principles: Rep ranges and progression guidance aligned with Schoenfeld et al. research

**Weekly Review Analyzer** (`weekly_review.py`):
- Model: `gemini-2.5-pro` (temperature=0.2)
- Budget: ~51KB total
- Reads: 12 weeks rollups (~6KB) + 15 exercise series (~18KB) + 8 muscle group series (~14KB) + full templates (~5KB) + recent insights (~2KB) + fatigue metrics (deterministic ACWR) + exercise catalog (~1KB)
- Writes: `users/{uid}/weekly_reviews/{YYYY-WNN}` (TTL 30 days)
- Output: training load delta, muscle balance, exercise trends, progression candidates, stalled exercises, periodization, routine_recommendations, fatigue_status
- `progression_candidates` includes `target_reps` (for rep progression) and `suggested_weight` (for weight progression)
- `stalled_exercises` includes `target_reps` and `suggested_weight` fields mapped to `suggested_action`
- All stalled exercise actions now processed: `increase_weight`, `deload`, `swap`, `vary_rep_range`
- `muscle_balance` data used for routine-scoped recommendations and readiness derivation
- New `periodization` field: current_phase, weeks_in_phase, suggestion, reasoning
- New `routine_recommendations` array: type, target, suggestion, reasoning
- New `fatigue_status` field: overall_acwr, interpretation, flags array, recommendation
- ACWR calculation uses load_per_muscle with fallback to hard_sets_per_muscle for deterministic fatigue tracking
- Evidence-based training principles: Periodization guidance aligned with Schoenfeld et al. research

**Data Budget Strategy**: NEVER pass raw workout docs, set_facts, or full history to LLM. Only use pre-aggregated data (analytics_rollups, series_*).

### Workers (`workers/`)

Three Cloud Run Jobs for bounded execution.

**Analyst Worker** (`analyst_worker.py`):
- Polls for jobs (exits if none)
- Routes to appropriate analyzer
- Heartbeat for lease renewal
- Graceful shutdown on signals
- Bounded execution (MAX_JOBS_PER_RUN, MAX_SECONDS_PER_RUN)

**Scheduler** (`scheduler.py`):
- Runs daily at 6 AM
- Creates WEEKLY_REVIEW jobs on Sundays
- Filters users with recent workouts

**Watchdog** (`watchdog.py`):
- Recovers stuck jobs (expired leases)
- Re-queues with exponential backoff
- Marks as failed after max_attempts (3)

## Cloud Run Jobs

Three jobs deployed to `europe-west1`:

1. **training-analyst-worker**
   - Triggered by Cloud Scheduler every 15 minutes
   - Processes analysis jobs
   - 1 hour timeout, 2Gi memory

2. **training-analyst-scheduler**
   - Triggered daily at 6 AM
   - Creates weekly jobs
   - 30 minute timeout, 512Mi memory

3. **training-analyst-watchdog**
   - Triggered hourly
   - Recovers stuck jobs
   - 30 minute timeout, 512Mi memory

## Deployment

```bash
# Build and push Docker image
make docker-push

# Deploy all jobs
make deploy

# Deploy Cloud Scheduler triggers (run AFTER deploy)
make deploy-schedulers

# Trigger manually
make trigger-worker
make trigger-scheduler
make trigger-watchdog
```

## Local Testing

```bash
# Install dependencies
make install

# Run worker locally
make worker-local

# Run scheduler locally
make scheduler-local

# Run watchdog locally
make watchdog-local
```

## Backfill

For generating historical analysis (e.g., after onboarding a user or importing workout history), use the two-step backfill process:

**Step 1 — Rebuild analytics foundation:**
```bash
FIREBASE_SERVICE_ACCOUNT_PATH=$FIREBASE_SA_KEY \
  node scripts/backfill_set_facts.js --user <userId> --rebuild-series
```

This populates `set_facts`, `series_exercises`, `series_muscle_groups`, `series_muscles`, and `analytics_rollups` from raw workout data.

**Step 2 — Enqueue analysis jobs:**
```bash
FIREBASE_SERVICE_ACCOUNT_PATH=$FIREBASE_SA_KEY \
  node scripts/backfill_analysis_jobs.js --user <userId> --months 3
```

Creates idempotent jobs with deterministic IDs (`bf-pw-{hash}`, `bf-wr-{hash}`). Safe to re-run — overwrites rather than duplicates.

**Step 3 — Process jobs:**
```bash
GOOGLE_APPLICATION_CREDENTIALS=$GCP_SA_KEY \
  PYTHONPATH=adk_agent/training_analyst \
  python3 adk_agent/training_analyst/workers/analyst_worker.py
```

Or trigger the Cloud Run Job: `make trigger-worker`

**Backfill script options:**
- `--user <userId>` or `--all-users`: Target scope
- `--months <n>`: Window (default: 3)
- `--skip-workouts`, `--skip-weekly`: Skip specific job types
- `--dry-run`: Preview without writing

**Required Firestore indexes**:

1. `training_analysis_jobs` composite index on `status` (ASC) + `created_at` (ASC):
```bash
gcloud firestore indexes composite create \
  --collection-group=training_analysis_jobs \
  --field-config field-path=status,order=ASCENDING \
  --field-config field-path=created_at,order=ASCENDING \
  --project=myon-53d85
```

2. **Potential requirement**: `analysis_insights` composite index on `created_at` (ASC). The Weekly Review analyzer queries recent insights ordered by creation time. If the query fails with `FailedPrecondition`, create this index.

## Key Differences from Catalog Orchestrator

1. **No family locks**: User-scoped jobs don't conflict
2. **Simpler status enum**: No dry_run/needs_review/deadletter
3. **Max attempts = 3**: Lower retry count
4. **Different LLM SDK**: google.genai with Vertex AI backend (not ADK Agent SDK)
5. **Data budget focus**: All reads are from aggregated collections

## Security

- All reads/writes scoped to `user_id` from job payload
- No client-provided userId (jobs created server-side)
- Output documents have TTL for automatic cleanup
- All LLM calls use JSON response mode

## Recommendation History Integration

Both analyzers read from `users/{uid}/agent_recommendations` to provide context-aware recommendations:

- **Post-workout** (`_read_recommendation_history`): 4-week window, limit 20. Deep format includes full `changes` array, `rationale`, `signals`, `confidence`, and `state`. Used for:
  - Deduplication: skip if identical rec is pending or recently applied
  - Rejection persistence: re-recommend with escalated context if signal persists
  - Self-progression awareness: acknowledge user-applied changes
  - Confidence adjustment: lower by 0.1 for re-recommendations of rejected types

- **Weekly review** (`_read_recommendation_history`): 8-week window, limit 25. Compact format for broader lifecycle tracking:
  - Acceptance rate patterns: track applied vs. rejected ratio
  - Progression velocity: gauge speed from frequency of applied progressions
  - Rejection patterns: adjust recommendation types if user consistently rejects a category

Both methods wrap Firestore reads in try/except, returning `[]` on failure to avoid blocking the analysis pipeline.

## Monitoring

Structured JSON logs for:
- `worker_started` / `worker_stopped`
- `job_started` / `job_completed` / `job_failed`
- `heartbeat_started` / `heartbeat_stopped`
- `analyzer_*` events

All logs include:
- `worker_id`, `job_id`, `job_type`, `user_id`
- `duration_ms` for timing
- `attempt` for retry tracking
