# Triggers — Module Architecture

Firestore triggers that react to document lifecycle events. All triggers are v2 functions using `onDocumentCreated`, `onDocumentUpdated`, or `onDocumentDeleted`.

## File Inventory

| File | Trigger Events | Purpose |
|------|---------------|---------|
| `workout-routine-cursor.js` | `onDocumentCreated('users/{userId}/workouts/{workoutId}')` | Updates routine cursor (`last_completed_template_id`, `last_completed_at`) when a workout with `source_routine_id` is archived. Enables O(1) next-workout selection. |
| `weekly-analytics.js` | Multiple triggers on `users/{userId}/workouts/{workoutId}` | Maintains `weekly_stats`, `analytics_series_exercise`, `analytics_series_muscle` collections. Handles workout created, completed, deleted events. Also exports scheduled `weeklyStatsRecalculation`. |
| `muscle-volume-calculations.js` | `onTemplateCreated`, `onTemplateUpdated`, `onWorkoutCreated` | Computes template analytics (estimated duration, total sets, muscles) and workout analytics on document creation/update. |
| `process-recommendations.js` | `onDocumentCreated('users/{userId}/analysis_insights/{insightId}')`, `onDocumentCreated('users/{userId}/weekly_reviews/{reviewId}')` | Translates training analysis outputs into actionable recommendations. Three paths: **template-scoped** (user has active routine — matches exercises to template sets, supports auto-pilot), **exercise-scoped** (no routine — derives baseline weight from workout data, always pending_review), and **non-exercise-scoped** (muscle-group/routine-level recommendations — written directly, always pending_review). Swap recommendations are always pending_review (never auto-applied). Auto-applied recommendations include `user_notification` + `notification_read` for iOS banners. Also exports `expireStaleRecommendations` daily scheduled sweep. |

## Trigger → Collection Mapping

| Trigger | Reads From | Writes To |
|---------|-----------|-----------|
| `onWorkoutCreatedUpdateRoutineCursor` | `workouts/{id}`, `routines/{id}` | `routines/{id}` (cursor fields) |
| `onWorkoutCompleted` / `onWorkoutCreatedWeekly` | `workouts/{id}` | `weekly_stats/{weekId}`, `analytics_series_*` |
| `onWorkoutDeleted` | (deleted doc) | `weekly_stats/{weekId}`, `analytics_series_*` (decrements) |
| `onTemplateCreated/Updated` | `templates/{id}` | `templates/{id}` (analytics field) |
| `onWorkoutCreated` | `workouts/{id}` | `workouts/{id}` (analytics field) |
| `onAnalysisInsightCreated` | `analysis_insights/{id}`, `users/{uid}`, `routines/{id}`, `templates/{id}`, `series_exercises/{id}`, `set_facts`, `workouts/{id}`, `agent_recommendations` | `agent_recommendations/{id}`, `templates/{id}` (if auto-pilot, template-scoped only) |
| `onWeeklyReviewCreated` | `weekly_reviews/{id}`, `users/{uid}`, `routines/{id}`, `templates/{id}`, `series_exercises/{id}`, `set_facts`, `workouts` (recent, exercise-scoped only), `agent_recommendations` | `agent_recommendations/{id}`, `templates/{id}` (if auto-pilot, template-scoped only) |
| `expireStaleRecommendations` | `agent_recommendations` (collectionGroup) | `agent_recommendations/{id}` (state → expired) |

## Key Behaviors

- **Best-effort**: `workout-routine-cursor.js` catches errors and logs rather than failing the trigger
- **Idempotent**: `weekly-analytics.js` uses deterministic set IDs for upserts
- **Separated error handling**: `weekly-analytics.js` splits rollup writes (CRITICAL — breaks ACWR) from per-muscle series writes (non-fatal) into separate try/catch blocks
- **Exercise name resolution**: Template exercises store `exercise_id` (catalog reference) but no `name`. `process-recommendations.js` resolves names via `series_exercises` (batch `getAll`, 1 doc per ID) with `set_facts` fallback for gaps. Stale `series_exercises` entries (where `exercise_name === doc.id`) are skipped.
- **Non-exercise deduplication**: `writeNonExerciseRecommendations` queries existing `pending_review` recs and deduplicates on `scope:type:target_key` to prevent duplicate volume_adjust/muscle_balance recommendations across insights.
- **No auth**: Triggers don't need authentication middleware — they fire from trusted Firestore events

## Cross-References

- Routine cursor consumed by: `routines/get-next-workout.js`
- Workouts created by: `active_workout/complete-active-workout.js`
- Analytics series read by: `analytics/get-features.js`, `training/series-endpoints.js`
- Recommendations reviewed by: `recommendations/review-recommendation.js`
- Shared mutation utilities: `agents/apply-progression.js` (`applyChangesToTarget`, `resolvePathValue`)
- Premium gate: `utils/subscription-gate.js` (`isPremiumUser`)
- Analysis insights written by: `adk_agent/training_analyst/app/analyzers/post_workout.py`
- Weekly reviews written by: `adk_agent/training_analyst/app/analyzers/weekly_review.py`
