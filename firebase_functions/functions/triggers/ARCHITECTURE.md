# Triggers — Module Architecture

Firestore triggers and Cloud Tasks handlers that react to document lifecycle events. Triggers are v2 functions using `onDocumentCreated`, `onDocumentUpdated`, or `onDocumentDeleted`. Cloud Tasks handlers are HTTP endpoints invoked by task queues.

## File Inventory

| File | Trigger Events | Purpose |
|------|---------------|---------|
| `workout-completion-task.js` | HTTP (Cloud Tasks queue: `workout-completion`) | Receives `{userId, workoutId}` from Cloud Tasks, delegates to `training/process-workout-completion.js` for the unified workout completion pipeline (weekly stats, analytics series, routine cursor, training analysis enqueue). Idempotent via watermark check. |
| `workout-completion-watchdog.js` | Scheduled (daily) | Scans 48h window for workouts missing `completion_watermark`, re-enqueues them to Cloud Tasks for reprocessing. Safety net for missed enqueues. |
| `weekly-analytics.js` | `onDocumentDeleted('users/{userId}/workouts/{workoutId}')`, scheduled | Handles workout deletion (decrements stats) and scheduled `weeklyStatsRecalculation` / `manualWeeklyStatsRecalculation`. Workout creation/completion logic moved to `training/process-workout-completion.js`. |
| `muscle-volume-calculations.js` | `onTemplateCreated`, `onTemplateUpdated`, `onWorkoutCreated` | Computes template analytics (estimated duration, total sets, muscles) and workout analytics on document creation/update. |
| `process-recommendations.js` | `onDocumentCreated('users/{userId}/analysis_insights/{insightId}')`, `onDocumentCreated('users/{userId}/weekly_reviews/{reviewId}')` | Translates training analysis outputs into actionable recommendations. Three paths: **template-scoped** (user has active routine — matches exercises to template sets, supports auto-pilot), **exercise-scoped** (no routine — derives baseline weight from workout data, always pending_review), and **non-exercise-scoped** (muscle-group/routine-level recommendations — written directly, always pending_review). Swap recommendations are always pending_review (never auto-applied). Auto-applied recommendations include `user_notification` + `notification_read` for iOS banners. Also exports `expireStaleRecommendations` daily scheduled sweep. |

## Trigger → Collection Mapping

| Trigger | Reads From | Writes To |
|---------|-----------|-----------|
| `workout-completion-task` | `workouts/{id}`, `routines/{id}`, `users/{uid}` | `weekly_stats/{weekId}`, `analytics_series_*`, `routines/{id}` (cursor), `workouts/{id}` (watermark) |
| `workout-completion-watchdog` | `workouts` (48h scan) | Cloud Tasks queue (enqueue) |
| `onWorkoutDeleted` | (deleted doc) | `weekly_stats/{weekId}`, `analytics_series_*` (decrements) |
| `onTemplateCreated/Updated` | `templates/{id}` | `templates/{id}` (analytics field) |
| `onWorkoutCreated` | `workouts/{id}` | `workouts/{id}` (analytics field) |
| `onAnalysisInsightCreated` | `analysis_insights/{id}`, `users/{uid}`, `routines/{id}`, `templates/{id}`, `series_exercises/{id}`, `set_facts`, `workouts/{id}`, `agent_recommendations` | `agent_recommendations/{id}`, `templates/{id}` (if auto-pilot, template-scoped only) |
| `onWeeklyReviewCreated` | `weekly_reviews/{id}`, `users/{uid}`, `routines/{id}`, `templates/{id}`, `series_exercises/{id}`, `set_facts`, `workouts` (recent, exercise-scoped only), `agent_recommendations` | `agent_recommendations/{id}`, `templates/{id}` (if auto-pilot, template-scoped only) |
| `expireStaleRecommendations` | `agent_recommendations` (collectionGroup) | `agent_recommendations/{id}` (state → expired) |

## Key Behaviors

- **Cloud Tasks reliability**: Workout completion uses Cloud Tasks (not Firestore triggers) for at-least-once delivery, retries with backoff, and observability via Cloud Console
- **Idempotent**: `process-workout-completion.js` uses `completion_watermark` to skip already-processed workouts; `enqueue-workout-task.js` uses named tasks for deduplication
- **Watchdog safety net**: Daily scheduled function scans for workouts that slipped through without processing
- **Separated error handling**: `weekly-analytics.js` splits rollup writes (CRITICAL — breaks ACWR) from per-muscle series writes (non-fatal) into separate try/catch blocks
- **Exercise name resolution**: Template exercises store `exercise_id` (catalog reference) but no `name`. `process-recommendations.js` resolves names via `series_exercises` (batch `getAll`, 1 doc per ID) with `set_facts` fallback for gaps. Stale `series_exercises` entries (where `exercise_name === doc.id`) are skipped.
- **Non-exercise deduplication**: `writeNonExerciseRecommendations` queries existing `pending_review` recs and deduplicates on `scope:type:target_key` to prevent duplicate volume_adjust/muscle_balance recommendations across insights.
- **No auth on triggers/tasks**: Firestore triggers fire from trusted events. Cloud Tasks handlers verify the request comes from the task queue (Cloud Run IAM).

## Cross-References

- Workout completion enqueued by: `workouts/upsert-workout.js`, `active_workout/complete-active-workout.js`
- Completion pipeline: `training/process-workout-completion.js`
- Task enqueue utility: `utils/enqueue-workout-task.js`
- Routine cursor consumed by: `routines/get-next-workout.js`
- Workouts created by: `active_workout/complete-active-workout.js`
- Analytics series read by: `analytics/get-features.js`, `training/series-endpoints.js`
- Recommendations reviewed by: `recommendations/review-recommendation.js`
- Shared mutation utilities: `agents/apply-progression.js` (`applyChangesToTarget`, `resolvePathValue`)
- Premium gate: `utils/subscription-gate.js` (`isPremiumUser`)
- Analysis insights written by: `adk_agent/training_analyst/app/analyzers/post_workout.py`
- Weekly reviews written by: `adk_agent/training_analyst/app/analyzers/weekly_review.py`
