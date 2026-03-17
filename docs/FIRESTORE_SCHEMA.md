# Firestore Schema

> Firestore data model, collections, indexes, security rules, and automatic mutations.
> For API endpoints and SSE streaming, see `docs/API_REFERENCE.md`.

---

## Table of Contents

1. [Firestore Data Model](#firestore-data-model-current-state)
2. [Security Rules](#security-rules-firestorerules)
3. [Automatic Mutations](#automatic-data-mutations-and-background-processes)
4. [Self-Healing Validation](#self-healing-validation-responses-for-agents)

---

## Firestore Data Model (Current State)

### Conventions
- Timestamps: `created_at`, `updated_at` are generally set by backend using serverTimestamp().
- IDs: Many documents embed their document ID in-field as `id` after creation; some rely only on the Firestore document ID.
- User-scoped data lives under `users/{uid}/...`.
- Admin/service writes are performed via HTTPS Functions; direct client writes are limited per rules.

---

## Root Collections

### users/{uid}
Top-level user profile and owner of most subcollections.

- Example fields
  - `uid: string` (mirrors auth uid)
  - `email: string`
  - `name?: string`
  - `provider: string` — Auth provider used at account creation. Values: `"email"`, `"google.com"`, `"apple.com"`. Written by `AuthService.createUserDocument()` via `AuthProvider.firestoreValue`.
  - `created_at: Timestamp`
  - `week_starts_on_monday: boolean` (default true)
  - `timezone?: string`
  - `activeRoutineId?: string` (points to a routine doc under `users/{uid}/routines`)
  - `apple_authorization_code?: string` — Stored on first Apple Sign-In and refreshed on subsequent sign-ins. Required for Apple token revocation on account deletion (App Store requirement 5.1.1(v)). Written by `AuthService.signInWithApple()` (existing user) and `AuthService.confirmSSOAccountCreation()` (new user). Read by `AuthService.deleteAccount()` before calling `Auth.auth().revokeToken()`.
  - (Historic mirrors) `weightFormat?`, `heightFormat?`, `locale?` (canonical values live in `user_attributes`)

- Subscription fields
  - `subscription_status?: string` — Current subscription state. Values: `"trial"`, `"active"`, `"expired"`, `"grace_period"`, `"free"`. Set by webhook (authoritative for downgrades) and iOS client (initial purchase/positive entitlements).
  - `subscription_tier?: string` — Denormalized subscription tier for fast gate checks. Values: `"free"`, `"premium"`. Premium when status is `trial`, `active`, or `grace_period`; free otherwise.
  - `subscription_product_id?: string` — App Store product identifier (e.g., `"com.povver.premium.monthly"`).
  - `subscription_original_transaction_id?: string` — App Store original transaction ID, stable across renewals. Used as the unique subscription identifier.
  - `subscription_app_account_token?: string` — UUID linking App Store purchase to Firebase user. Generated on iOS, sent to App Store at purchase, received in webhook for user matching.
  - `subscription_expires_at?: Timestamp` — When the current subscription period ends. Null for free tier.
  - `subscription_auto_renew_enabled?: boolean` — Whether auto-renewal is enabled. From App Store webhook `autoRenewStatus`.
  - `subscription_in_grace_period?: boolean` — Whether user is in billing retry grace period (still has access despite failed payment).
  - `subscription_updated_at?: Timestamp` — Last time subscription fields were updated (from webhook or manual override).
  - `subscription_environment?: string` — App Store environment. Values: `"Sandbox"`, `"Production"`. Used to distinguish test vs. real purchases.
  - `subscription_override?: string` — Manual override for testing/support. Values: `"premium"` (grants premium access regardless of App Store state), `null` (respect App Store state). Set via admin script `scripts/set_subscription_override.js`.
  - `auto_pilot_enabled?: boolean` — When true, agent recommendations are applied automatically to templates without user review. Default `false`. Premium-only feature; UI toggle in Profile → Preferences. Read by `process-recommendations.js` trigger at execution time.

Subcollections:
1) user_attributes/{uid}
   - Canonical store for user preferences and fitness profile.
   - Fields (observed):
     - `timezone?: string`
     - `weight_format?: 'kilograms' | 'pounds'` — User's preferred display unit for weight values. Default: 'kilograms'. Read by iOS `UserService`, agent via `get-planning-context.js` (`weight_unit` field). All stored weight values remain in kg regardless of this preference.
     - `height_format?: 'centimeter' | 'feet'` — User's preferred display unit for height. Default: 'centimeter'. Read by iOS `UserService` (`heightUnit` property). ProfileEditView shows cm text field or ft+in text fields based on this value. `HeightFormatter` handles cm↔ft conversion.
     - `week_starts_on_monday?: boolean`
     - `locale?: string`
     - `fitness_goal?: string`
     - `fitness_level?: string`
     - `equipment_preference?: string`
     - `height?: number`
     - `weight?: number`
     - `workouts_per_week_goal?: number`
     - `created_at?, updated_at?: Timestamp`

2) linked_devices/{deviceId}
   - Device linkage state.
   - Fields:
     - `device_type: string`
     - `device_name: string`
     - `last_sync: Timestamp`
     - `is_active: boolean`
     - `permissions: { [perm: string]: boolean }`
     - `created_at?, updated_at?: Timestamp`

3) workouts/{workoutId}
   - Archived/completed workouts. Used by analytics and weekly stats triggers.
   - Query patterns: order by `end_time`, filter by `end_time` range, collectionGroup from triggers.
   - Fields:
     - `user_id: string`
     - `source_template_id?: string` (template used to generate this workout)
     - `source_routine_id?: string` (routine this workout belongs to; used for cursor updates)
     - `created_at: Timestamp`
     - `start_time: Timestamp`
     - `end_time: Timestamp` (presence indicates completion)
     - `notes?: string`
     - `exercises: Array<{
           exercise_id: string,
           name?: string,
           position?: number,
           notes?: string (max 500 chars),
           sets: Array<{
             id?: string,
             reps: number,
             rir: number | null,  // null = not recorded (e.g. warmups); 0 = zero reps in reserve
             type?: string,
             weight_kg: number,
             is_completed?: boolean
           }>,
           analytics?: ExerciseAnalytics
         }>`
     - `analytics?: WorkoutAnalytics` (computed by trigger if absent)
     - `completion_watermark?: Timestamp` — Set by `process-workout-completion.js` after the Cloud Tasks workout completion pipeline has processed this workout. Used for idempotency (skip already-processed workouts) and by the daily watchdog to detect missed completions.
     - `template_diff?: {` (present when workout was started from a template; generated by `complete-active-workout.js`)
           `changes_detected: boolean,`
           `exercises_added?: Array<{ exercise_id, exercise_name }>,`
           `exercises_removed?: Array<{ exercise_id, exercise_name }>,`
           `exercises_swapped?: Array<{ from_id, from_name, to_id, to_name }>,`
           `exercises_reordered?: boolean,`
           `weight_changes?: Array<{ exercise_id, exercise_name, direction: 'increased'|'decreased', max_delta_kg }>,`
           `rep_changes?: Array<{ exercise_id, exercise_name, direction: 'increased'|'decreased', max_delta }>,`
           `sets_added_count?: number,`
           `sets_removed_count?: number,`
           `summary?: string`
         `}`

   - ExerciseAnalytics (per exercise):
     - `total_sets, total_reps, total_weight: number`
     - `weight_format: 'kg' | 'lbs'`
     - `avg_reps_per_set, avg_weight_per_set, avg_weight_per_rep: number`
     - `weight_per_muscle_group: { [group]: number }`
     - `weight_per_muscle: { [muscle]: number }`
     - `reps_per_muscle_group: { [group]: number }`
     - `reps_per_muscle: { [muscle]: number }`
     - `sets_per_muscle_group: { [group]: number }`
     - `sets_per_muscle: { [muscle]: number }`

   - WorkoutAnalytics (workout-level): same shape as ExerciseAnalytics aggregates.

4) weekly_stats/{weekId}
   - Aggregate stats keyed by the week start date (ISO date as string), start day depends on user preference.
   - Written by triggers on workout completion/deletion and periodic recalculation job.
   - Fields:
     - `workouts: number`
     - `total_sets, total_reps, total_weight: number`
     - `weight_per_muscle_group, weight_per_muscle: { [key]: number }`
     - `reps_per_muscle_group, reps_per_muscle: { [key]: number }`
     - `sets_per_muscle_group, sets_per_muscle: { [key]: number }`
     - `updated_at: Timestamp`
     - `recalculated_at?: Timestamp`

5) templates/{templateId}
   - User-authored or AI-authored workout templates.
   - Fields:
     - `id: string` (backfilled after create)
     - `user_id: string`
     - `name: string`
     - `description?: string`
     - `exercises: Array<{
           id?: string, // per-template unique
           exercise_id: string, // reference to master `exercises/{id}`
           position: number,
           sets: Array<{ id?: string, reps: number, rir: number | null, type?: string, weight: number, duration?: number }>,
           rest_between_sets?: number
         }>`
     - `analytics?: TemplateAnalytics` (computed server-side for AI-created/updated templates)
     - `created_at, updated_at: Timestamp`

   - TemplateAnalytics:
     - `template_id: string`
     - `total_sets, total_reps, projected_volume: number`
     - `weight_format: 'kg' | 'lbs'`
     - `estimated_duration?: number`
     - `projected_volume_per_muscle_group, projected_volume_per_muscle: { [key]: number }`
     - `sets_per_muscle_group, sets_per_muscle: { [key]: number }`
     - `reps_per_muscle_group, reps_per_muscle: { [key]: number }`
     - `relative_stimulus_per_muscle_group, relative_stimulus_per_muscle: { [key]: number }`

#### `templates/{tid}/changelog/{changelogId}`

Audit trail for template mutations from all sources. Written by Cloud Functions using Admin SDK (bypasses Firestore security rules).

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | timestamp | When the change was made |
| `source` | string | Origin: `"user_edit"` \| `"workout_save"` \| `"agent_auto_pilot"` \| `"agent_coached_edit"` |
| `recommendation_id` | string? | Links to `agent_recommendations` doc if change came from a recommendation |
| `workout_id` | string? | Links to workout if change came from workout save |
| `changes` | array | `[{ field, operation: "update"\|"add", summary }]` |
| `expires_at` | Date | 90-day TTL for automatic cleanup |

**Sources:**
- `user_edit`: Direct template edits via `patch-template.js`
- `workout_save`: Post-workout template save via `save-workout.js`
- `agent_auto_pilot`: Auto-applied recommendations via `apply-progression.js`
- `agent_coached_edit`: Shell agent template/routine updates via `artifact-action.js`

6) routines/{routineId}
   - Weekly/monthly routine structure referencing templates.
   - Fields:
     - `id: string`
     - `user_id: string`
     - `name: string`
     - `description?: string`
     - `template_ids: string[]` (template IDs under this user; canonical field)
     - `templateIds?: string[]` (legacy camelCase mirror; read for backward compat, writes go to template_ids)
     - `frequency: number` (workouts per week)
     - `last_completed_template_id?: string` (cursor: ID of last completed template from this routine)
     - `last_completed_at?: Timestamp` (cursor: when last workout from this routine was completed)
     - `created_at, updated_at: Timestamp`
   - Cursor semantics:
     - Updated by `onWorkoutCreatedUpdateRoutineCursor` trigger when a workout with matching `source_routine_id` is archived.
     - `getNextWorkout` uses cursor for O(1) next-template selection; falls back to history scan if cursor missing/invalid.
     - Cursor cleared when `last_completed_template_id` is removed from `template_ids` via `patchRoutine`.

7) progress_reports/{reportId}
   - StrengthOS progress reports written by service endpoints (API key auth).
   - Fields:
     - `period: { start: Timestamp, end: Timestamp }`
     - `metrics: { [key]: any }`
     - `proposals: { [key]: any }`
     - `created_at, updated_at: Timestamp`

8) active_workouts/{activeWorkoutId}
   - Current in-progress workout state. Ephemeral; upon completion, a record is archived under `workouts` and this is marked completed.
   - Fields:
     - `user_id: string`
     - `status: 'in_progress' | 'completed'`
     - `source_template_id?: string` (template this workout is based on)
     - `source_routine_id?: string` (routine this workout belongs to; copied to archived workout for cursor updates)
     - `plan?: any` (structured blocks used to initialize)
     - `current?: any`
     - `exercises: any[]` (app-managed during session; each exercise object may contain `notes?: string (max 500 chars)` for per-exercise context)
     - `totals: { sets: number, reps: number, volume: number, stimulus_score: number }`
     - `version: number` (monotonically incrementing; starts at 1, incremented on each mutation. Used for debugging and future optimistic concurrency. Existing documents without this field are treated as version 0.)
     - `start_time: Timestamp`
     - `end_time?: Timestamp`
     - `notes?: string`
     - `analytics?: WorkoutAnalytics`
     - `created_at, updated_at: Timestamp`

   - Subcollection: events/{eventId}
     - Logged events during an active workout.
     - Fields:
       - `type: string` (e.g., `set_performed`)
       - `payload: { exercise_id: string, set_index: number, actual: { reps: number, rir: number, weight?: number } }`
       - `created_at: Timestamp`

9) conversations/{conversationId}
   - **Canonical** collection for AI conversations. Replaces the deprecated `canvases` collection.
   - Root document fields:
     - `user_id: string`
     - `purpose?: string` (e.g., 'chat', 'planning', 'analysis')
     - `title?: string | null` — Auto-generated 3-6 word title (set by `stream-agent-normalized.js` via Gemini Flash after first message exchange; null until generated)
     - `created_at, updated_at: Timestamp`

   - Subcollections:
     - messages/{messageId}
       - Conversation messages (user prompts, agent responses, artifact references).
       - Fields:
         - `type: 'user_prompt' | 'agent_response' | 'artifact'`
         - `content?: string` (text content for user_prompt and agent_response, null for artifact)
         - `artifact_type?: string` (for artifact type messages: 'session_plan' | 'routine_summary' | 'analysis_summary' | 'visualization')
         - `artifact_id?: string` (reference to artifact document ID)
         - `correlation_id?: string` (links related messages and artifacts)
         - `created_at: Timestamp`

     - artifacts/{artifactId}
       - AI-proposed artifacts (session plans, routine summaries, analyses, visualizations).
       - Fields:
         - `type: 'session_plan' | 'routine_summary' | 'analysis_summary' | 'visualization'`
         - `content: { ... }` (artifact-specific structured data)
         - `actions: string[]` (available actions, e.g., ["start_workout", "dismiss"])
         - `status: 'proposed' | 'accepted' | 'dismissed'`
         - `correlation_id?: string` (links to message that proposed this artifact)
         - `created_at, updated_at: Timestamp`

10) canvases/{canvasId} **(DEPRECATED — renamed to `conversations`)**
   - Legacy collaboration surface. All new code uses `conversations/{conversationId}`.
   - Existing data remains for backward compatibility but is no longer written.
   - Root document fields:
     - `purpose?: string` — e.g., 'general' (set by `open-canvas.js`)
     - `status?: string` — 'active' (filterable for recent conversations query)
     - `lastMessage?: string | null` — Last user message text (set by `stream-agent-normalized.js`)
     - `title?: string | null` — Auto-generated conversation title (set by `stream-agent-normalized.js` via Gemini Flash after first exchange)
     - `createdAt, updatedAt: Timestamp`
     - `state: { phase: 'planning' | 'active' | 'analysis', version: number, purpose: string, lanes: string[], created_at: Timestamp, updated_at: Timestamp }` (legacy)
     - `meta: { user_id: string }` (legacy)

   - Subcollections:
     - cards/{cardId} (DEPRECATED)
       - Fields:
         - `type: string` (e.g., `session_plan`, `set_target`, `set_result`, `note`, `visualization`, `instruction`, `coach_proposal`, etc.)
         - `status: 'proposed' | 'active' | 'accepted' | 'rejected' | 'expired' | 'completed'`
         - `lane: 'workout' | 'analysis' | 'system'`
         - `content: { ... }` (type-specific payload)
         - `refs?: { exercise_id?: string, set_index?: number, topic_key?: string }`
         - `layout?: any`, `actions?: any[]`, `menuItems?: any[]`, `meta?: any`, `ttl?: number`
         - `by: 'user' | 'agent'`
         - `created_at, updated_at: Timestamp`

     - up_next/{entryId} (DEPRECATED)
       - Queue of next actions/cards; trimmed to max 20.
       - Fields: `card_id: string`, `priority: number`, `inserted_at: Timestamp`

     - events/{eventId} (DEPRECATED)
       - Reducer events for deterministic replay/undo.
       - Fields:
         - `type: 'apply_action' | 'instruction_added' | 'group_action' | 'session_started' | ...`
         - `payload: { action?: string, card_id?: string, changed_cards?: string[], note_id?: string }`
         - `correlation_id?: string`
         - `created_at: Timestamp`

    - idempotency/{key} (DEPRECATED)
      - Scoped idempotency guard.
      - Fields: `key: string`, `created_at: Timestamp`

11) agent_sessions/{purpose} **(REMOVED)**
   - Was: Vertex AI Agent Engine session references for conversation continuity.
   - Sessions have been fully eliminated (stateless agent on Cloud Run). This subcollection is no longer read or written. Existing docs are harmless and will be cleaned up.
   - Fields (legacy):
     - `session_id: string` (Vertex AI Agent Engine session ID)
     - `purpose: string` (e.g., 'chat', 'planning')
     - `created_at, updated_at: Timestamp`

12) analytics_series_exercise/{exercise_id}
   - Per-exercise time series of daily points and compacted weekly aggregates (sublinear growth).
   - Fields:
     - `points_by_day: { [YYYY-MM-DD]: { e1rm?: number, vol?: number } }`
     - `weeks_by_start?: { [YYYY-MM-DD]: { e1rm_max: number, vol_sum: number } }`
     - `schema_version: number`
     - `updated_at: Timestamp`, `compacted_at?: Timestamp`

13) analytics_series_muscle/{muscle}
   - Per-muscle weekly aggregates.
   - Fields:
     - `weeks: { [YYYY-MM-DD]: { sets: number, volume: number, hard_sets?: number, low_rir_sets?: number, load?: number } }`
     - `updated_at: Timestamp`

14) analytics_rollups/{periodId}
   - Weekly/monthly compact rollups keyed by `yyyy-ww` or `yyyy-mm`.
   - Fields:
     - `total_sets, total_reps, total_weight: number`
     - `weight_per_muscle_group: { [group]: number }`
     - `workouts?: number`
     - `hard_sets_total?: number`
     - `low_rir_sets_total?: number`
     - `hard_sets_per_muscle?: { [muscle]: number }`
     - `low_rir_sets_per_muscle?: { [muscle]: number }`
     - `load_per_muscle?: { [muscle]: number }`
     - `hard_sets_per_muscle_group?: { [group]: number }`
     - `low_rir_sets_per_muscle_group?: { [group]: number }`
     - `load_per_muscle_group?: { [group]: number }`
     - `updated_at: Timestamp`

15) analytics_state/current
   - Watermarks and cursors for idempotent incremental processing.
   - Fields:
     - `last_processed_workout_at?: string (ISO)`
     - `last_compaction_at?: string (ISO)`
     - `job_cursors?: { [key]: any }`
     - `updated_at: Timestamp`

16) agent_recommendations/{recommendationId}
   - Audit log of agent-initiated changes to user training data.
   - Created by: `triggers/process-recommendations.js` (onAnalysisInsightCreated, onWeeklyReviewCreated) and `agents/apply-progression.js` (direct agent calls).
   - Reviewed by: `recommendations/review-recommendation.js` (user accept/reject).
   - Expired by: `expireStaleRecommendations` scheduled function (daily, 7-day TTL).
   - Supports two modes: auto-pilot (immediate apply via `auto_pilot_enabled`) or review (pending user approval).
   - iOS listener: `RecommendationRepository.swift` → `RecommendationsViewModel.swift` → bell notification + feed sheet.
   - Fields:
     - `id: string` (document ID)
     - `created_at: Timestamp`
     - `trigger: string` - What triggered this recommendation:
       - `"post_workout"` - After workout completion analysis
       - `"scheduled"` - Scheduled progression check
       - `"plateau_detected"` - Auto-detected plateau
       - `"user_request"` - User asked for adjustment
     - `trigger_context: object` - Additional trigger context (e.g., workout_id, completed_at)
     - `scope: "template" | "exercise" | "routine" | "muscle_group"` - Target type
     - `target: object`:
       - `template_id?: string` - If scope is "template"
       - `template_name?: string` - Human-readable template name (template scope)
       - `routine_id?: string` - If scope is "template" or "routine"
       - `exercise_name?: string` - If scope is "exercise" or "template" (resolved from series_exercises/set_facts)
       - `exercise_id?: string` - If scope is "exercise"
       - `muscle_group?: string` - If scope is "routine" or "muscle_group" (muscle_balance recommendations)
       - `current_exercise?: string` - If type is "swap" — exercise being replaced
       - `exercise_index?: number` - If type is "swap" — index in template exercises array
       - `description?: string` - If scope is "routine" — free-text target description
     - `recommendation: object`:
       - `type: string` - Recommendation type:
         - `"progression"` - Weight increase (user hit target reps with low RIR)
         - `"rep_progression"` - Rep increase (double progression: build reps before adding weight)
         - `"intensity_adjust"` - RIR tuning (adjust target RIR)
         - `"deload"` - Weight reduction
         - `"volume_adjust"` - Sets/reps change
         - `"swap"` - Replace exercise (swap suggestion)
         - `"muscle_balance"` - Muscle group volume imbalance (informational, scope: routine)
       - `suggested_weight?: number` - Explicit weight suggestion from analyzer (for progression/deload)
       - `target_reps?: number` - Target rep count from analyzer (for rep_progression, 1-30)
       - `target_rir?: number` - Target RIR from analyzer (for intensity_adjust, 0-5)
       - `changes: Array<{ path: string, from: any, to: any, rationale?: string }>`
         - `path` values (template-scoped): `exercises[i].sets[j].weight`, `exercises[i].sets[j].reps` (templates use `weight`/`reps`, not `weight_kg`/`target_reps`). Exercise-scoped: `weight`, `reps` (no template baseline).
         - RIR is diagnostic only — not written to templates. High RIR triggers weight progression instead.
         - `from: null` for exercise-scoped reps/RIR (no template baseline) and new fields being added
       - `summary: string` - Human-readable summary
       - `rationale?: string` - Full explanation
       - `confidence: number` - 0-1 confidence score
     - `state: string` - State machine:
       - `"pending_review"` - Waiting for user approval
       - `"applied"` - Applied (auto-pilot or user-approved, template-scoped)
       - `"acknowledged"` - User accepted exercise-scoped recommendation (no mutation)
       - `"rejected"` - User rejected
       - `"expired"` - TTL expired
       - `"failed"` - Application failed
     - `state_history: Array<{ from: string?, to: string, at: string, by: string, note?: string }>`
     - `applied_by?: "agent" | "user"` - Who applied the change
     - `applied_at?: Timestamp` - When applied
     - `result?: object` - Result of application (e.g., { template_id, changes_applied })
     - `user_notification?: string` - Human-readable notification for user (auto-pilot applied changes). Format: `"Auto-applied: <summary>"`. Null when not auto-applied.
     - `notification_read?: boolean` - Whether user has seen this notification. `false` when notification exists, `null` when no notification. iOS queries `where('notification_read', '==', false)` for unread banners.

   - Query patterns:
     - Pending reviews: `where('state', '==', 'pending_review')` ordered by `created_at`
     - Applied by trigger: `where('trigger', '==', 'post_workout')` ordered by `created_at`
     - History for target: `where('target.template_id', '==', templateId)`

   - State transitions:
     ```
     pending_review → applied (user approves or auto-apply, template-scoped)
     pending_review → acknowledged (user accepts exercise-scoped)
     pending_review → rejected (user rejects)
     pending_review → expired (TTL sweep)
     applied (initial) → failed (application error, then retry or manual fix)
     ```

   **Consumed by:**
   - **Post-workout analyzer** (`adk_agent/training_analyst/app/analyzers/post_workout.py`): Reads 4 weeks, limit 20. Deep format with full changes array, rationale, signals. Used for deduplication and rejection-aware re-recommendations.
   - **Weekly review analyzer** (`adk_agent/training_analyst/app/analyzers/weekly_review.py`): Reads 8 weeks, limit 25. Compact format for acceptance rate tracking, progression velocity, and rejection patterns.
   - **Shell agent** via `getAnalysisSummary` (`firebase_functions/functions/training/get-analysis-summary.js`): Reads 30 days, limit 20. Narrative-oriented format with summary fields for coaching context.
   - **Workout brief** (`adk_agent/agent_service/app/skills/workout_skills.py`): Filtered to exercises in current workout, capped at 3 recommendations. Compact one-line format for mid-workout context.

17) subscription_events/{auto-id}
   - Audit log of App Store Server Notifications. Written by `app-store-webhook.js` on every notification.
   - Stored under `users/{uid}/subscription_events/{auto-id}` (auto-generated document ID).
   - Used for debugging subscription issues and reconciliation.
   - Fields:
     - `notification_type: string` - App Store notification type (e.g., `"SUBSCRIBED"`, `"DID_RENEW"`, `"EXPIRED"`, `"DID_FAIL_TO_RENEW"`, `"GRACE_PERIOD_EXPIRED"`, `"REFUND"`, `"REVOKE"`, `"DID_CHANGE_RENEWAL_STATUS"`)
     - `subtype?: string` - App Store notification subtype (e.g., `"GRACE_PERIOD"`)
     - `subscription_status?: string` - The `subscription_status` value set on the user doc by this event (null if no status change)
     - `subscription_tier?: string` - The `subscription_tier` value set on the user doc by this event (null if no tier change)
     - `app_account_token?: string` - UUID linking purchase to user (lowercased)
     - `original_transaction_id?: string` - App Store original transaction ID
     - `environment?: string` - `"Sandbox"` or `"Production"`
     - `created_at: Timestamp` - Server timestamp

18) set_facts/{setId}
   - Denormalized per-set performance records. One document per completed set across all workouts.
   - Document ID: deterministic composite key `{workoutId}_{exerciseId}_{setIndex}`.
   - Written by: `training/set-facts-generator.js` via `writeSetFactsInChunks()`, called from `workouts/upsert-workout.js` (imports) and `triggers/weekly-analytics.js` (workout completion).
   - Read by: `training/query-sets.js` (querySets, aggregateSets), `training/series-endpoints.js` (getExerciseSummary for fuzzy name→ID resolution), iOS `ExercisePerformanceSheet`.
   - Fields:
     - Identity:
       - `set_id: string` (document ID, format: `{workoutId}_{exerciseId}_{setIndex}`)
       - `user_id: string`
       - `workout_id: string`
       - `workout_end_time: Timestamp`
       - `workout_date: string` (YYYY-MM-DD, used for date-range queries)
       - `exercise_id: string` (reference to `exercises/{id}`)
       - `exercise_name: string`
       - `set_index: number`
     - Set performance:
       - `reps: number`
       - `weight_kg: number` (normalized to kg regardless of user preference)
       - `rir: number | null` (reps in reserve, 0-5)
       - `rpe: number | null` (rate of perceived exertion)
       - `is_warmup: boolean`
       - `is_failure: boolean`
       - `volume: number` (reps × weight_kg)
     - Strength proxy:
       - `e1rm: number | null` (Epley formula, only for reps ≤ 12)
       - `e1rm_formula: string | null` ('epley' when e1rm is computed, null otherwise)
       - `e1rm_confidence: number | null` (0-1, higher for lower rep ranges)
     - Classification:
       - `equipment: string` (from exercise catalog)
       - `movement_pattern: string` (from exercise catalog)
       - `is_isolation: boolean`
       - `side: string` ('bilateral' or unilateral side)
     - Attribution maps (fractional credit per muscle/group):
       - `muscle_group_contrib: { [group]: number }` (contribution weights, sum ≈ 1.0)
       - `muscle_contrib: { [muscle]: number }`
       - `effective_volume_by_group: { [group]: number }` (volume × contribution)
       - `effective_volume_by_muscle: { [muscle]: number }`
       - `hard_set_credit_by_group: { [group]: number }` (hard_set_credit × contribution)
       - `hard_set_credit_by_muscle: { [muscle]: number }`
     - Filter arrays (for Firestore array-contains queries):
       - `muscle_group_keys: string[]`
       - `muscle_keys: string[]`
     - Internal:
       - `hard_set_credit: number` (0-1; 1.0 for failure/RIR≤2, 0.5 for RIR 3-4, 0.75 for unknown RIR working sets, 0 for warmups)
     - Timestamps:
       - `created_at, updated_at: Timestamp`

   - Query patterns:
     - Per-exercise history: `where('exercise_id', '==', id).where('is_warmup', '==', false).orderBy('workout_date', 'desc')` (requires composite index)
     - Date range: `where('workout_date', '>=', start).where('workout_date', '<=', end).orderBy('workout_date')`
     - Muscle group filter: `where('muscle_group_keys', 'array-contains', group)`
     - Aggregation: `aggregateSets` groups by exercise_id or muscle_group with sum/avg/max aggregations

19) exercise_usage_stats/{exerciseId}
   - Pre-computed per-exercise usage statistics for client-side sorting (recency, frequency).
   - Document ID: exercise ID from the `exercises` catalog.
   - Written by: `triggers/weekly-analytics.js` (`updateExerciseUsageStats`) on workout completion/creation/deletion. Backfilled by `scripts/backfill_exercise_usage_stats.js`.
   - Read by: iOS `ExerciseRepository.fetchUsageStats()` for exercise list sorting.
   - Security: Owner read, no client writes (`allow write: if false` in firestore.rules). All writes via admin SDK.
   - Fields:
     - `exercise_id: string` (matches document ID and `exercises/{id}`)
     - `exercise_name: string` (denormalized for debugging; not used in sort logic)
     - `last_workout_date: string` (YYYY-MM-DD, most recent workout containing this exercise)
     - `workout_count: number` (total completed workouts containing this exercise)
     - `last_processed_workout_id: string` (idempotency guard — prevents double-increment under trigger retries)
     - `updated_at: Timestamp`
   - Query patterns:
     - Full collection read: iOS fetches all docs for the user to build a lookup map (typically 30-80 docs, small documents)

20) agent_memory/{auto-id}
   - Persistent facts the agent remembers across conversations (Tier 3 memory).
   - Written by: Agent Service (`memory.py`) when it identifies user preferences, injury notes, or other persistent facts.
   - Read by: Agent Service (`context_builder.py`) at the start of each request to hydrate per-request context.
   - Fields:
     - `content: string` — The fact or preference being remembered
     - `category: string` — Category for organization (e.g., `"preference"`, `"injury"`, `"goal"`)
     - `active: boolean` — Whether this memory is currently active (false = retired)
     - `created_at: Timestamp`
     - `source_conversation_id: string` — Conversation where this memory was created
     - `retired_at?: Timestamp` — When the memory was retired (null if active)
     - `retire_reason?: string` — Why the memory was retired (e.g., `"superseded"`, `"user_requested"`)

21) mcp_api_keys/{key_hash}
   - API keys for MCP Server access. Document ID is SHA-256 hash of the key.
   - Written by: `mcp/generate-api-key.js`. Read by: MCP Server for authentication.
   - Premium-gated: only premium users can generate keys.
   - Fields:
     - `user_id: string` — Owner of the API key
     - `name: string` — User-provided key name (e.g., `"My MCP Key"`)
     - `created_at: Timestamp`
     - `last_used_at?: Timestamp` — Updated on each use by MCP Server

---

## Global Collections

### exercises/{exerciseId}
Master exercise catalog (shared across all users).

- Fields:
  - `id?: string` (sometimes mirrored)
  - `name: string`
  - `name_slug: string`
  - `aliases?: string[]`
  - `alias_slugs?: string[]`
  - `family_slug: string` (e.g., `deadlift`, `squat`, ...)
  - `variant_key: string` (e.g., `variant:romanian`)
  - `category: string`
  - `description?: string`
  - `metadata: { level: string, plane_of_motion?: string, unilateral?: boolean }`
  - `movement: { type: string, split?: string }`
  - `equipment: string[]`
  - `muscles: { primary: string[], secondary: string[], category?: string[], contribution?: { [muscle]: number } }`
  - `execution_notes?: string[]`
  - `common_mistakes?: string[]`
  - `programming_use_cases?: string[]`
  - `stimulus_tags?: string[]`
  - `suitability_notes?: string[]`
  - `coaching_cues?: string[]`
  - `status?: 'draft' | 'approved' | ...`
  - `version?: number`
  - `_debug_project_id?: string`
  - `created_by: string`
  - `created_at, updated_at: Timestamp`

Indexes and lookups:
- Find by `name_slug` or by `alias_slugs` (array-contains/array-contains-any).
- Alias registry fallback maps slugs to `exercise_id`.

### exercise_aliases/{alias_slug}
Registry mapping name/alias slugs to canonical `exercises/{exerciseId}`.

- Fields:
  - `alias_slug: string` (document ID)
  - `exercise_id: string`
  - `family_slug?: string`
  - `created_at, updated_at: Timestamp`

### idempotency/{userId:tool:key}
Global idempotency keys for non-canvas operations.

- Fields: `user_id: string`, `tool: string`, `key: string`, `created_at: Timestamp`

### exercises_backup/{exerciseId}
Point-in-time snapshots of `exercises` created by maintenance tooling.

- Fields: All fields from the source exercise plus
  - `_backup_meta: { source: 'exercises', backed_up_at: Timestamp, tag: string }`

---

## Canvas Indexes

firestore.indexes.json contains a collection group index for `cards`:
- Fields: `lane` ASC, `refs.topic_key` ASC
- Scope: `COLLECTION_GROUP` on `cards` (under all canvases)

This supports queries that group or replace analysis-lane proposals by topic key.

Additionally, a collection group index exists for `up_next` to support deterministic ordering and trimming:
- Fields: `priority` DESC, `inserted_at` ASC
- Scope: `COLLECTION_GROUP` on `up_next`

Notes:
- Reducer and proposer code may order by `priority` only in some paths; the two-field index is present for stable ordering where both are used (see `apply-action.js`, `propose-cards-core.js`).

---

## Analytics Indexes

- `workouts` collection group: index on `end_time` (ascending) for time-range queries and active user discovery.
- `analytics_rollups` collection group: index on `updated_at` (descending) for recent rollups.
- `set_facts` subcollection: composite index on `(exercise_id ASC, is_warmup ASC, workout_date DESC)` — used by `ExercisePerformanceSheet` (iOS) to query per-exercise performance history. Required for the query `exercise_id == X, is_warmup == false, order by workout_date desc`.
- Series collections are typically point-lookups by document id; no composite indexes required initially.

---

## Security Rules (firestore.rules)

- `users/{uid}/conversations/**`: read allowed to the authenticated owner; writes to `messages` and `artifacts` disallowed directly (Admin SDK only — agent writes via Functions).
- `users/{uid}/canvases/**` (DEPRECATED): read allowed to the authenticated owner; writes are disallowed directly (single-writer via Functions only). All canvas mutations flow through HTTPS endpoints (e.g., `applyAction`, `proposeCards`, `bootstrapCanvas`).
- `users/{uid}/exercise_usage_stats/**`: read allowed to the authenticated owner; writes disallowed directly (admin SDK only via triggers and backfill scripts).
- Other user subcollections under `users/{uid}`: read/write allowed to the authenticated owner (excluding `canvases`, `artifacts`, and `exercise_usage_stats`). This includes `workouts`, `weekly_stats`, `templates`, `routines`, `user_attributes`, `linked_devices`, `progress_reports`, `active_workouts`, `agent_memory`, and analytics collections under `analytics_*` prefixes. (`agent_sessions` removed — no longer read or written.)
- Admin/agents: Function-layer auth (API keys, service accounts) mediates privileged writes.
- Analytics: lives under `users/{uid}/analytics_*` and inherits owner read/write. Backend Functions (triggers/HTTPS) write these docs on behalf of the user.

Implications:
- Client apps should not attempt to write messages, artifacts, or canvas data directly (Admin SDK only).
- Direct client reads of conversations, messages, artifacts, and canvases are supported (for UI live updates).
- Account deletion uses the `deleteAccount` Cloud Function (Admin SDK) which purges all subcollections including admin-only ones.

---

## Query Patterns (Representative)

- Workouts (per user): `users/{uid}/workouts` ordered by `end_time` desc, with optional date range filters.
- Weekly stats: direct doc get/set `users/{uid}/weekly_stats/{weekId}`.
- Template and Routine CRUD: subcollection reads/writes under the user, with analytics calculations performed by triggers or function logic.
- Active workout session: `users/{uid}/active_workouts` latest by `updated_at`; log set events via `active_workouts/{id}/events`.
- Conversations:
  - Read messages: `users/{uid}/conversations/{conversationId}/messages` ordered by `created_at`.
  - Read artifacts: `users/{uid}/conversations/{conversationId}/artifacts` filtered by `status='proposed'` for pending items.
  - Write messages: Admin SDK only (via `streamAgentNormalized` Cloud Function). Firestore rules block direct client writes to prevent message injection.
  - Agent artifacts: written by agent tools via Functions, client reads for UI updates.
- Canvas (DEPRECATED):
  - Reducer transaction updates `users/{uid}/canvases/{canvasId}` and subcollections (`cards`, `up_next`, `events`, `idempotency`).
  - Agents propose cards in batch and manage `up_next`, enforcing max 20 entries.
 - Analytics:
   - Series (exercise): read `users/{uid}/analytics_series_exercise/{exercise_id}`; use `points_by_day[YYYY-MM-DD]` for recent, or `weeks_by_start` for older windows.
   - Series (muscle): read `users/{uid}/analytics_series_muscle/{muscle}` and pull `weeks[yyyy-ww]`.
   - Rollups: read `users/{uid}/analytics_rollups/{yyyy-ww}` (and `yyyy-mm` when present) ordered by `updated_at` when listing.

---

## Field Naming Notes and Migrations

- The system is converging on snake_case field names in Firestore (`start_time`, `end_time`, `weight_kg`, etc.).
- Some iOS models include camelCase but map via `CodingKeys` to snake_case. When adding fields, prefer snake_case in Firestore.
- Preferences canonical store is `users/{uid}/user_attributes/{uid}`; minimal mirrors on `users/{uid}` may exist for legacy compatibility.

---

## Gaps and TODOs (Observed)

- Active workout analytics and totals may be partial until archived; triggers compute workout analytics post-write if missing.
- Canvas card `content` is type-specific; JSON Schemas live under `firebase_functions/functions/canvas/schemas`. Clients should validate against these when relevant.
- Exercise alias resolution uses both `alias_slugs` on exercises and `exercise_aliases` registry; conflicts are handled with best-effort reservation and may log conflicts.

---

## Routine Draft System (Canvas-Based)

This section describes the routine draft architecture for creating and editing multi-workout routines through the canvas system.

### Card Types for Routines

**routine_summary** - The anchor card for a routine draft:
- `type: 'routine_summary'`
- `status: 'proposed' | 'active' | 'accepted' | 'rejected'`
- `lane: 'workout'`
- `content.name: string` - Routine name
- `content.frequency: number` - Workouts per week
- `content.workouts: Array<{ day, title, card_id, estimated_duration?, exercise_count?, generate? }>`
- `meta.draft: true` - Marks this as a draft anchor
- `meta.draftId: string` - Stable UUID across revisions
- `meta.revision: number` - Incremented on major rewrites
- `meta.groupId: string` - Links all cards in this draft group
- `meta.sourceRoutineId?: string` - If imported from existing routine

**session_plan** (within routine draft):
- Existing `session_plan` cards with additional meta fields:
- `meta.groupId: string` - Same as routine_summary.meta.groupId
- `meta.sourceTemplateId?: string` - If derived from existing template

### Lifecycle States

```
Agent proposes → All cards status='proposed' (TTL sweep eligible)
                        ↓
User touches (PIN_DRAFT) → All cards status='active' (TTL exempt)
                        ↓
User saves (SAVE_ROUTINE) → All cards status='accepted', routine/templates created
         OR
User dismisses (DISMISS_DRAFT) → All cards status='rejected'
```

### Canvas Actions for Routines

- `PIN_DRAFT` - Flip all cards in group to `status='active'` (idempotent)
- `SAVE_ROUTINE` - Create routine + templates from draft, mark cards accepted
- `DISMISS_DRAFT` - Mark all cards in group as `rejected`, remove from up_next

### up_next Behavior

- Only the `routine_summary` anchor card goes into `up_next`
- Day cards (`session_plan`) are referenced by `content.workouts[].card_id` but not queued
- This prevents multi-day routines from consuming multiple queue slots

### Server-Generated IDs

When `proposeCards` receives a batch containing `routine_summary`:
- `meta.draftId` - Generated server-side (UUID)
- `meta.groupId` - Generated server-side, shared by all cards
- `meta.revision` - Set to 1 initially
- `content.workouts[].card_id` - Set to actual Firestore doc IDs after card creation

Agents should NOT set these fields; they are generated by the backend.

---

## Summary Diagram (Textual)

```
users/{uid}
  ├─ user_attributes/{uid}
  ├─ linked_devices/{deviceId}
  ├─ workouts/{workoutId}
  ├─ weekly_stats/{weekId}
  ├─ templates/{templateId}
  ├─ routines/{routineId}
  ├─ progress_reports/{reportId}
  ├─ active_workouts/{activeWorkoutId}
  │    └─ events/{eventId}
  ├─ conversations/{conversationId}
  │    ├─ messages/{messageId}
  │    └─ artifacts/{artifactId}
  ├─ agent_sessions/{purpose} (REMOVED)
  ├─ agent_memory/{auto-id}
  ├─ subscription_events/{auto-id}
  ├─ set_facts/{setId}
  ├─ exercise_usage_stats/{exerciseId}
  └─ canvases/{canvasId} (DEPRECATED → renamed to conversations)
       ├─ cards/{cardId} (DEPRECATED)
       ├─ up_next/{entryId} (DEPRECATED)
       ├─ events/{eventId} (DEPRECATED)
       └─ idempotency/{key} (DEPRECATED)

exercises/{exerciseId}
exercise_aliases/{alias_slug}
idempotency/{userId:tool:key}
mcp_api_keys/{key_hash}
```

---

## Appendix: Types (Condensed)

- WorkoutAnalytics/ExerciseAnalytics keys: `total_sets, total_reps, total_weight, weight_format, avg_reps_per_set, avg_weight_per_set, avg_weight_per_rep, weight_per_muscle_group, weight_per_muscle, reps_per_muscle_group, reps_per_muscle, sets_per_muscle_group, sets_per_muscle`.
- TemplateAnalytics adds `projected_volume`, `estimated_duration`, and relative stimulus maps.
- Canvas state: `{ phase, version, purpose, lanes }`; Cards: `{ type, status, lane, content, refs, by, created_at, updated_at }`.

---

## Subscription Gate Check Logic

Premium feature access is determined by `utils/subscription-gate.js`:

```javascript
// isPremiumUser(userId) returns true if ANY of:
// 1. subscription_override === 'premium' (admin override for testing/support)
// 2. subscription_tier === 'premium' (set by webhook based on status transitions)
```

The gate checks the denormalized `subscription_tier` field, not `status + expires_at`. The webhook is responsible for setting tier correctly based on notification type (e.g., `EXPIRED` → tier=`free`, `DID_RENEW` → tier=`premium`).

**Premium-gated features**:
- AI coaching chat — all streaming via `streamAgentNormalized` (client gate in `DirectStreamingService` + server gate in `stream-agent-normalized.js`)
- Post-workout LLM analysis — job enqueueing in `triggers/weekly-analytics.js`

**Free tier features** (not gated):
- Account creation, profile management
- Manual workout logging (without AI coaching)
- Workout history viewing
- Template/routine browsing (read-only)
- Weekly stats, analytics rollups, set_facts (Firestore-only aggregations, no LLM cost)
- Exercise catalog browsing

Used by:
- `firebase_functions/functions/strengthos/stream-agent-normalized.js` — SSE error `PREMIUM_REQUIRED` for free users
- `firebase_functions/functions/triggers/weekly-analytics.js` — Skips training analysis job enqueueing for free users
- `Povver/Povver/Services/DirectStreamingService.swift` — Client-side gate before SSE connection

---

## Automatic Data Mutations and Background Processes

This section focuses on what data gets added or mutated automatically over time by Cloud Functions (triggers, scheduled jobs, HTTPS reducers) and by the production Catalog Admin agent pipeline.

### Workouts → Weekly Analytics (triggers and jobs)
- On workout completion
  - Trigger: `triggers/weekly-analytics.js:onWorkoutCompleted` on `users/{userId}/workouts/{workoutId}` when `end_time` is added.
  - Reads `workout.analytics` and updates `users/{uid}/weekly_stats/{weekId}` for the week starting on the user’s preference.
  - Week start preference is read from `users/{uid}.week_starts_on_monday` (defaults to Monday when missing).
- On workout deletion
  - Trigger: `onWorkoutDeleted` subtracts the workout’s analytics from the corresponding `weekly_stats/{weekId}`.
- Scheduled backfill/recalculation
  - Job: `weeklyStatsRecalculation` runs daily (2 AM UTC).
  - Discovers active users via `collectionGroup('workouts')` where `end_time` is within last 14 days, then recalculates aggregates for the user’s current and previous week.
  - Writes `updated_at` and `recalculated_at` on `weekly_stats/{weekId}`.
- Manual recalculation
  - Callable: `manualWeeklyStatsRecalculation` recalculates stats for current and previous week for the authenticated user.

Data impacted over time
- `users/{uid}/weekly_stats/{weekId}` continually accrues or decrements `workouts`, set/rep/weight totals, and per-muscle/per-group maps in response to workout lifecycle.

Sources
- `firebase_functions/functions/triggers/weekly-analytics.js` (onWorkoutCompleted, onWorkoutDeleted, weeklyStatsRecalculation, manualWeeklyStatsRecalculation)
- `firebase_functions/functions/index.js` (exports and scheduler wiring)

### Template and Workout Analytics (triggers)
- Template analytics
  - Trigger: `triggers/muscle-volume-calculations.js:onTemplateCreated` computes and writes `template.analytics` when a template under `users/{uid}/templates/{templateId}` is created without analytics and contains exercises.
  - Trigger: `onTemplateUpdated` recomputes `analytics` when exercises change and analytics are absent.
  - Fetches referenced `exercises/{exerciseId}` to drive computations.
- Workout analytics
  - Trigger: `onWorkoutCreated` computes `workout.analytics` and also writes per-exercise `exercises[].analytics` when a workout is created without analytics but contains exercises.
- Working set semantics
  - Only “working” set types are included in volume/rep/set computations (e.g., working set, drop set, failure set, etc.).

### Analytics series and rollups (triggers + controller + compaction + publisher)
- On workout completion (and on eligible creation)
  - Triggers: `triggers/weekly-analytics.js:onWorkoutCompleted` and `onWorkoutCreatedWithEnd` update:
    - `users/{uid}/weekly_stats/{weekId}` (backwards compatibility)
    - `users/{uid}/analytics_rollups/{weekId}` (compact rollup)
    - `users/{uid}/analytics_series_muscle/{muscle}.weeks[weekId]` per affected groups
    - `users/{uid}/analytics_series_exercise/{exercise_id}.points_by_day[YYYY-MM-DD]` with `{ e1rm, vol }` estimated using Epley
- Controller/Worker (HTTPS)
  - `analytics/controller.js:runAnalyticsForUser` processes workouts since watermark (or last 90 days) to backfill series/rollups and updates `analytics_state/current`.
- Compaction (scheduled + HTTPS)
  - `analytics/compaction.js:analyticsCompactionScheduled` compacts `points_by_day` older than 90 days into `weeks_by_start` and deletes old day keys.
  - `analytics/compaction.js:compactAnalyticsForUser` allows on-demand compaction per user.
- Weekly publisher (HTTPS)
  - `analytics/publish-weekly-job.js:publishWeeklyJob` proposes a weekly `proposal-group` (summary + visualization) to the user’s canvas via `proposeCards`.

Response contracts (for LLMs/agents):
- `analytics/get-features.js` responds with `{ userId, mode, period_weeks?, weekIds?, range?, daily_window_days?, rollups, series_muscle, series_exercise, schema_version }`.

### Analytics features (LLM/agent read path)
- Read-only endpoint for compact, typed features that LLMs or fast services can consume to decide what to publish:
  - HTTPS: `analytics/get-features.js:getAnalyticsFeatures`
  - Auth: API key or Bearer token
  - Request:
    - `userId: string`
    - `mode: 'weekly' | 'week' | 'range' | 'daily'` (default `'weekly'`)
    - Weekly: `weeks?: number (1–52)`
    - Week: `weekId?: 'yyyy-mm-dd'` (user-aligned week start)
    - Range: `start?: 'yyyy-mm-dd'`, `end?: 'yyyy-mm-dd'` (week-aligned, inclusive)
    - Daily: `days?: number (1–120)` window for per-exercise daily points
    - Filters: `muscles?: string[] (≤50)`, `exerciseIds?: string[] (≤50)`
  - Response (schema_version=2):
    - `mode, period_weeks?, weekIds?, range?, daily_window_days?`
    - `rollups: [{ id: weekId, total_sets, total_reps, total_weight, weight_per_muscle_group, updated_at }]`
    - `series_muscle: { [muscle]: [{ week, sets, volume }] }`
    - `series_exercise: { [exerciseId]: { days: string[], e1rm: number[], vol: number[], e1rm_slope: number, vol_slope: number } }`

Data impacted over time
- New analytics subcollections under `users/{uid}` accumulate series points, weekly muscle aggregates, and compact rollups; day-level points older than 90 days are merged into weekly aggregates.
- `analytics_state/current` watermarks advance with processing and compaction operations.

Sources
- `firebase_functions/functions/triggers/weekly-analytics.js` (enhanced triggers, e1RM estimate)
- `firebase_functions/functions/active_workout/complete-active-workout.js` (ensures analytics on archive)
- `firebase_functions/functions/utils/analytics-writes.js` (shared writers)
- `firebase_functions/functions/analytics/worker.js`, `.../controller.js` (per-user processing)
- `firebase_functions/functions/analytics/compaction.js` (scheduled/HTTPS compaction)
- `firebase_functions/functions/analytics/publish-weekly-job.js` (weekly canvas group proposer)
- `firebase_functions/functions/analytics/get-features.js` (LLM-facing features API)

Data impacted over time
- `users/{uid}/templates/{templateId}.analytics` is populated/updated server-side as content changes.
- `users/{uid}/workouts/{workoutId}.analytics` and `exercises[].analytics` are filled on first creation if missing.

Sources
- `firebase_functions/functions/triggers/muscle-volume-calculations.js` (onTemplateCreated, onTemplateUpdated, onWorkoutCreated)
- `firebase_functions/functions/utils/analytics-calculator.js` (shared analytics calculator)
- `firebase_functions/functions/templates/create-template.js` and `firebase_functions/functions/templates/update-template.js` (agent-origin analytics path)

### Canvas (transactional reducer + TTL sweeps)
- Deterministic reducer
  - HTTPS: `canvas/apply-action.js` is the sole write gateway for `users/{uid}/canvases/{canvasId}` and subcollections.
  - Transactionally mutates:
    - `state.version` (optimistic concurrency) and `state.phase` transitions.
    - `cards/{cardId}.status` (e.g., proposed → accepted/rejected/expired/completed).
    - Ensures single active `set_target` per `(refs.exercise_id, refs.set_index)` and converts accepted targets into `set_result` on `LOG_SET`.
    - Appends reducer `events/{eventId}` (e.g., `apply_action`, `instruction_added`, `session_started`).
    - Maintains `up_next` priority queue; trims to max 20 entries after each reducer run.
  - Events:
    - `apply_action` payload includes `{ action, card_id?, changed_cards?[] }` and a `correlation_id` of the form `${canvasId}:${version}` for client telemetry.
    - Group actions append `group_action` events with `{ action: 'ACCEPT_ALL|REJECT_ALL', group_id }`.
  - Science/Safety checks enforced when accepting plans or logging sets:
    - `session_plan` targets must satisfy `reps ∈ [1,30]` and `rir ∈ [0,5]`.
    - `LOG_SET.actual` must satisfy `reps ≥ 0` and `rir ∈ [0,5]`.
  - Idempotency:
    - Per-canvas keys under `users/{uid}/canvases/{canvasId}/idempotency/{key}` prevent duplicate actions within a transaction.
- TTL expiration of proposed cards
  - Scheduled: `canvas/expire-proposals-scheduled.js` runs every 15 minutes. It performs a `collectionGroup('cards')` sweep for `status='proposed'` whose `created_at + ttl.minutes` has elapsed, updates those cards to `status='expired'`, and deletes corresponding `up_next` entries.
  - HTTPS: `canvas/expire-proposals.js` can sweep one or all canvases for a user on-demand.
- Bootstrap
  - HTTPS: `canvas/bootstrap-canvas.js` find-or-creates a canvas for `(userId, purpose)` and initializes `state` and `meta`.

Constraints and caps:
- `up_next` is capped to 20 entries. Trimming is best-effort outside the Firestore transaction to avoid reads-after-writes inside the transaction boundary.

Data impacted over time
- `users/{uid}/canvases/{canvasId}` root `state` evolves; `cards`, `up_next`, and `events` change continuously via the reducer. TTL jobs convert stale proposals to `expired` and clean queues.

Sources
- `firebase_functions/functions/canvas/apply-action.js` (transactional reducer)
- `firebase_functions/functions/canvas/expire-proposals-scheduled.js` (scheduled TTL sweeper)
- `firebase_functions/functions/canvas/expire-proposals.js` (on-demand sweep)
- `firebase_functions/functions/canvas/bootstrap-canvas.js` (find-or-create)
- `firebase_functions/functions/canvas/validators.js` and `firebase_functions/functions/canvas/schemas/` (typed validation)

### Active Workout Lifecycle (HTTPS tools and shared cores)
- Start/cancel/complete
  - `startActiveWorkout` writes `users/{uid}/active_workouts/{id}` with `status='in_progress'`, `totals`, and timestamps.
  - `cancelActiveWorkout` updates the active doc to `status='cancelled'` and sets `end_time`.
  - `completeActiveWorkout` archives the in-progress doc to `users/{uid}/workouts` (mapping `weight → weight_kg` in sets, synthesizing analytics if missing), then marks the active doc `status='completed'` and sets `end_time`.
- Set logging and modifications
  - `logSet`, `addExercise`, `swapExercise`, `reorderSets` append `events/{eventId}` under the active workout and update `updated_at`.
  - Idempotency keys recorded in global `idempotency/{userId:tool:key}` for duplicate suppression in non-canvas tools.
- Latest active fetch
  - `getActiveWorkout` returns the most recent active workout (ordered by `updated_at`).

Data impacted over time
- `users/{uid}/active_workouts` grows and shrinks during sessions; `events` accumulate per active workout. Completed sessions are permanently archived to `users/{uid}/workouts`.

Sources
- `firebase_functions/functions/active_workout/start-active-workout.js`
- `firebase_functions/functions/active_workout/cancel-active-workout.js`
- `firebase_functions/functions/active_workout/complete-active-workout.js`
- `firebase_functions/functions/active_workout/get-active-workout.js`
- `firebase_functions/functions/active_workout/log-set.js`
- `firebase_functions/functions/active_workout/add-exercise.js`
- `firebase_functions/functions/active_workout/swap-exercise.js`
- `firebase_functions/functions/shared/active_workout/log_set_core.js`
- `firebase_functions/functions/shared/active_workout/adjust_load_core.js`
- `firebase_functions/functions/shared/active_workout/reorder_sets_core.js`
- `firebase_functions/functions/utils/idempotency.js` (global keys for non-canvas tools)

### Exercise Catalog (service writes + maintenance + agent pipeline)
- Core writes (service HTTPS endpoints)
  - `upsertExercise` creates/merges canonical exercise docs; sets `name_slug`, infers `family_slug` and `variant_key` when needed; reserves alias slugs transactionally in `exercise_aliases/{alias_slug}`; sets `status`, `version`, `created_by`.
  - `ensureExerciseExists` finds-or-creates minimal drafts; seeds alias registry.
  - `refineExercise` merges structured fields; `approveExercise` sets `status='approved'`.
  - `mergeExercises` transfers alias slugs to the target, sets `source.merged_into`, and updates `target.merge_lineage` (union of previous + source id).
- Normalization and maintenance
  - `normalizeCatalog` / `normalizeCatalogPage` backfill `name_slug`, `family_slug`, `variant_key`, canonicalize names, and populate alias registry; optional merge planning can be applied.
  - `backfillNormalizeFamily` merges duplicates within a `family_slug::variant_key` bucket.
  - `repointAlias` / `repointShorthandAliases` retarget `exercise_aliases` entries to canonical exercises; shorthand expansions include `ohp`, `rdl`, `sldl`, `db-*`, `bb-*`, `tbar-*`.
  - `backupExercises` snapshots `exercises` into `exercises_backup` with `_backup_meta`.
- Production Agent Pipeline (Catalog Admin)
  - The orchestrator and agents under `adk_agent/catalog_admin/multi_agent_system` continuously call the HTTPS endpoints above:
    - Triage/Enrichment/Janitor/Specialists improve metadata, add aliases, approve, and merge duplicates.
    - Effects over time: more complete `exercises` documents; growing `exercise_aliases`; evolving `status` (`draft`→`approved` / `merged`), `merge_lineage`, and alias unions.

Data impacted over time
- Global `exercises` density/quality increases; alias registry grows; duplicates are merged; backups are periodically created; merges leave `merged_into` pointers for redirects.

Sources
- `firebase_functions/functions/exercises/upsert-exercise.js`
- `firebase_functions/functions/exercises/ensure-exercise-exists.js`
- `firebase_functions/functions/exercises/refine-exercise.js`
- `firebase_functions/functions/exercises/approve-exercise.js`
- `firebase_functions/functions/exercises/merge-exercises.js`
- `firebase_functions/functions/exercises/normalize-catalog.js`
- `firebase_functions/functions/exercises/normalize-catalog-page.js`
- `firebase_functions/functions/exercises/backfill-normalize-family.js`
- `firebase_functions/functions/exercises/list-families.js`
- `firebase_functions/functions/aliases/upsert-alias.js` and `firebase_functions/functions/aliases/delete-alias.js`
- `firebase_functions/functions/maintenance/repoint-alias.js`
- `firebase_functions/functions/maintenance/repoint-shorthand-aliases.js`
- `firebase_functions/functions/maintenance/backup-exercises.js`
- `firebase_functions/functions/exercises/search-exercises.js`
- `firebase_functions/functions/exercises/search-aliases.js`
- `firebase_functions/functions/exercises/resolve-exercise.js`
- Agent pipeline (production):
  - `adk_agent/catalog_admin/multi_agent_system/orchestrator/orchestrator.py` (batch orchestration)
  - `adk_agent/catalog_admin/app/orchestrator.py` (Agent Engine app integration)
  - `adk_agent/catalog_admin/app/libs/tools_firebase/client.py` (HTTP client to Firebase Functions)
  - `adk_agent/catalog_admin/multi_agent_system/agents/` (triage, enrichment, janitor, specialists)

### Templates and Routines (service writes + cleanup)
- Template lifecycle
  - `createTemplate` writes `users/{uid}/templates/{templateId}` and then backfills `id` field; when the caller is an agent (`auth.source='third_party_agent'`) and no `analytics` exist, analytics are computed and stored.
  - `updateTemplate` merges updates; when an agent updates exercises, analytics are recalculated.
  - `patchTemplate` (new) narrow allowlist patch for `name`, `description`, `exercises` with optional concurrency check via `expected_updated_at`. Clears analytics on exercise change to trigger recompute.
  - `createTemplateFromPlan` (new) converts a `session_plan` card to a template with idempotency. Supports `create` (new template) and `update` (patch existing template's exercises) modes.
  - `deleteTemplate` removes the template and removes references from routines (reads both `template_ids` and `templateIds`, writes only canonical `template_ids`). Clears routine cursor if the deleted template was `last_completed_template_id`.
- Routines
  - `createRoutine`/`updateRoutine`/`deleteRoutine` manage `users/{uid}/routines/{routineId}` with canonical `template_ids` and timestamps. `setActiveRoutine` writes `users/{uid}.activeRoutineId`. `createRoutine` auto-sets `activeRoutineId` if user has no active routine. `getRoutine` and `getUserRoutines` enrich responses with `is_active` derived from `users/{uid}.activeRoutineId`.
  - `patchRoutine` (new) narrow allowlist patch for `name`, `description`, `frequency`, `template_ids`. Validates all templates exist (parallel reads). Clears cursor if `last_completed_template_id` is removed from `template_ids`.
  - `getNextWorkout` (new) deterministic next-template selection. Uses cursor (`last_completed_template_id`) for O(1) lookup; falls back to history scan if cursor missing/invalid. Returns template, routine, index, and selection method.
- Routine cursor updates (trigger)
  - `onWorkoutCreatedUpdateRoutineCursor` updates `routines/{routineId}.last_completed_template_id` and `last_completed_at` when a workout with `source_routine_id` is archived. Uses `source_routine_id` from workout (not current `activeRoutineId`) to handle routine changes mid-workout. Also auto-sets `activeRoutineId` if user has no active routine (best-effort).
- Planning context (agent composite read)
  - `getPlanningContext` (new) returns user profile, active routine, next workout selection, templates (metadata or full), and recent workouts summary in one call. Flag-driven payload control: `includeTemplates`, `includeTemplateExercises`, `includeRecentWorkouts`, `workoutLimit`.

Data impacted over time
- Template analytics become populated/recalculated; routines maintain references to templates and the user's `activeRoutineId` may change.
- Routine cursor fields (`last_completed_template_id`, `last_completed_at`) updated by trigger on workout completion.
- Idempotency keys under `users/{uid}/idempotency/{key}` created by `createTemplateFromPlan` with 24h TTL.

Sources
- Templates: `firebase_functions/functions/templates/create-template.js`, `.../update-template.js`, `.../delete-template.js`, `.../get-template.js`, `.../get-user-templates.js`, `.../create-template-from-plan.js`, `.../patch-template.js`
- Routines: `firebase_functions/functions/routines/create-routine.js`, `.../update-routine.js`, `.../delete-routine.js`, `.../get-routine.js`, `.../get-user-routines.js`, `.../get-active-routine.js`, `.../set-active-routine.js`, `.../get-next-workout.js`, `.../patch-routine.js`
- Routine cursor: `firebase_functions/functions/training/process-workout-completion.js` (Cloud Tasks pipeline; replaces deprecated `workout-routine-cursor.js` Firestore trigger)
- Agent: `firebase_functions/functions/agents/get-planning-context.js`

### StrengthOS Progress Reports (service writes)
- `strengthos/progress-reports.js`
  - `upsertProgressReport` (API key only) upserts `users/{uid}/progress_reports/{reportId}` with `period.start/end`, `metrics`, and `proposals`.
  - `getProgressReports` lists the latest 20 reports ordered by `period.start`.

Sources
- `firebase_functions/functions/strengthos/progress-reports.js`

### Idempotency (duplicate suppression)
- Global: `idempotency/{userId:tool:key}` used by active workout tools (`log_set`, `add_exercise`, `swap_exercise`).
- Canvas-scoped: `users/{uid}/canvases/{canvasId}/idempotency/{key}` inside reducer transactions.

Sources
- `firebase_functions/functions/utils/idempotency.js`
- `firebase_functions/functions/canvas/apply-action.js` (canvas-scoped usage)

---

## Self-Healing Validation Responses for Agents

Schema-validated endpoints can return rich error responses that enable AI agents to self-correct when validation fails. This pattern is implemented via a shared utility and currently deployed on `proposeCards`.

### Error Response Format

When validation fails, the endpoint returns:

```json
{
  "success": false,
  "error": "Schema validation failed",
  "details": {
    "attempted": { /* the exact payload the agent sent */ },
    "errors": [
      {
        "path": "/cards/0/content/blocks/0/sets/0",
        "message": "must have required property 'target'",
        "keyword": "required",
        "params": { "missingProperty": "target" }
      }
    ],
    "hint": "Missing required property 'target' at /cards/0/content/blocks/0/sets/0",
    "expected_schema": { /* the actual JSON Schema that defines valid input */ }
  }
}
```

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `attempted` | Object | The original request body (truncated if >2KB with summary) |
| `errors` | Array | AJV validation errors with path, message, keyword, params |
| `hint` | String | Human-readable explanation of what went wrong |
| `expected_schema` | Object | The JSON Schema that defines valid input structure |

### Agent Self-Correction Flow

1. Agent sends a request that fails schema validation
2. Endpoint returns the error response with `attempted` + `expected_schema`
3. Agent compares what it sent vs. what the schema expects
4. Agent fixes the discrepancy and retries

### Shared Utility

Location: `firebase_functions/functions/utils/validation-response.js`

```javascript
const { formatValidationResponse } = require('../utils/validation-response');

// In your endpoint:
if (!validationResult.valid) {
  const schema = SCHEMAS[cardType] || null;
  const details = formatValidationResponse(req.body, validationResult.errors, schema);
  return fail(res, 'INVALID_ARGUMENT', 'Schema validation failed', details, 400);
}
```

### Exported Functions

- `formatValidationResponse(input, errors, schema)` - Formats the full error response
- `getHintForErrors(errors)` - Generates human-readable hints from AJV errors
- `summarizeInput(input)` - Creates a summary for truncated inputs

### Currently Deployed On

- `proposeCards` - Canvas card proposal endpoint (session_plan schema)

### Future Rollout

This pattern can be extended to any schema-validated endpoint:
1. Import the shared utility
2. Load the relevant JSON schema
3. Call `formatValidationResponse()` when validation fails

Sources
- `firebase_functions/functions/utils/validation-response.js` (shared utility)
- `firebase_functions/functions/canvas/propose-cards.js` (implementation example)
- `firebase_functions/functions/canvas/schemas/card_types/session_plan.schema.json` (example schema)

---

## LLM Usage Tracking

### llm_usage/{auto_id}
Per-request token accounting for Vertex AI LLM calls. Used to attribute costs by user, category, and system for margin analysis. Written fire-and-forget by the `shared/usage_tracker.py` module; never blocks the user-facing request path.

Gated by `ENABLE_USAGE_TRACKING` env var (default `false`). Query with `scripts/query_llm_usage.js`.

- `user_id: string | null` — Firebase Auth UID. Null for system-level calls (catalog enrichment).
- `category: string` — Cost attribution bucket:
  - `"system"` — No user context; internal system jobs (catalog enrichment, catalog agent)
  - `"user_scoped"` — Background job for a specific user, not real-time (training analyst post-workout, weekly review)
  - `"user_initiated"` — User is actively waiting for the response (shell agent, functional lane)
- `system: string` — Agent system that made the call: `"canvas_orchestrator"` | `"catalog_orchestrator"` | `"training_analyst"`
- `feature: string` — Specific feature within the system (e.g. `"shell_agent"`, `"functional"`, `"post_workout"`, `"weekly_review"`, `"enrichment"`)
- `model: string` — Vertex AI model identifier (e.g. `"gemini-2.5-flash"`, `"gemini-2.5-pro"`)
- `prompt_tokens: number` — Input token count
- `completion_tokens: number` — Output token count
- `thinking_tokens: number | null` — Thinking/reasoning tokens (Gemini 2.5+), null if not reported
- `total_tokens: number` — Total token count
- `created_at: Timestamp` — Server timestamp

**Indexes required:** Composite on `(user_id ASC, created_at ASC)` for per-user weekly/monthly rollups.

---

## Training Analysis Collections

### training_analysis_jobs/{jobId}
Background job queue for automated training analysis.

- Fields:
  - `id: string` (document ID)
  - `type: string` - Job type enum:
    - `POST_WORKOUT_ANALYSIS` - Analyze completed workout
    - `WEEKLY_REVIEW_GENERATION` - Generate weekly progression review
    - `PLATEAU_DETECTION` - Detect training plateaus
  - `status: string`:
    - `queued`, `running`, `completed`, `failed`
  - `user_id: string` - Target user
  - `trigger: string` - What triggered the job:
    - `workout_completed` - PubSub trigger from workout completion
    - `scheduled` - Scheduled cron job
    - `manual` - Manual trigger
  - `trigger_context: object` - Additional context (e.g., `workout_id`, `date`)
  - `priority: number` - Higher wins (default 0)
  - `payload: object`:
    - `workout_id?: string` - For POST_WORKOUT_ANALYSIS
    - `week_id?: string` - For WEEKLY_REVIEW_GENERATION (YYYY-MM-DD)
    - `analysis_window_weeks?: number` - Lookback window
  - `result?: object` - Analysis output
  - `error?: object` - Error details if failed
  - `attempts: number` - Retry counter
  - `max_attempts: number` - Max retries (default 3)
  - `created_at, updated_at: Timestamp`
  - `started_at?: Timestamp` - When processing began
  - `completed_at?: Timestamp` - When processing finished

### users/{uid}/analysis_insights/{id}
AI-generated post-workout insights. Written by Training Analyst after each workout completion. TTL: 7 days.

- Fields:
  - `id: string` (document ID)
  - `type: string` - Always `"post_workout"` currently
  - `workout_id: string` - Source workout that triggered this insight
  - `workout_date: string` - Date of the workout (YYYY-MM-DD)
  - `summary: string` - 2-3 sentence overview of the workout
  - `highlights: Array<object>` - Positive observations:
    - `type: string` - `"pr"` | `"volume_up"` | `"consistency"` | `"intensity"`
    - `message: string` - Human-readable description
    - `exercise_id?: string` - Related exercise if applicable
  - `flags: Array<object>` - Concerns or warnings:
    - `type: string` - `"stall"` | `"volume_drop"` | `"overreach"` | `"fatigue"`
    - `severity: string` - `"info"` | `"warning"` | `"action"`
    - `message: string` - Human-readable description
  - `recommendations: Array<object>` - Actionable next steps:
    - `type: string` - `"progression"` | `"deload"` | `"swap"` | `"volume_adjust"` | `"rep_progression"`
    - `target: string` - Exercise or muscle group
    - `action: string` - What to do
    - `confidence: number` - 0-1 confidence score
    - `suggested_weight?: number` - For progression/deload
    - `target_reps?: number` - For rep_progression (1-30)
    - `sets_delta?: number` - For volume_adjust
  - `template_diff_summary?: string` - Summary of user deviations from template (present when workout was started from a template and deviations were detected)
  - `created_at: Timestamp`
  - `expires_at: Timestamp` - TTL (7 days from creation)

### users/{uid}/weekly_reviews/{weekId}
Weekly progression reviews and trend analysis. Document ID is week identifier (YYYY-WNN). TTL: 30 days.

- Fields:
  - `id: string` (YYYY-WNN format, also document ID)
  - `week_ending: string` - Last day of the review week (YYYY-MM-DD)
  - `summary: string` - Paragraph-length overall week assessment
  - `training_load: object`:
    - `sessions: number` - Number of workouts this week
    - `total_sets: number` - Total sets performed
    - `total_volume: number` - Total volume in kg
    - `acwr: number` - Acute:Chronic Workload Ratio (deterministic, load_per_muscle fallback to hard_sets_per_muscle)
    - `vs_last_week: object` - Week-over-week comparison:
      - `sets_delta: number` - Change in sets
      - `volume_delta: number` - Change in volume (kg)
  - `muscle_balance: Array<object>` - Per-muscle-group volume assessment:
    - `muscle_group: string` - e.g., "chest", "back", "legs"
    - `weekly_sets: number` - Total sets this week
    - `trend: string` - Volume trend direction
    - `status: string` - `"undertrained"` | `"optimal"` | `"overtrained"`
  - `exercise_trends: Array<object>` - Per-exercise progression:
    - `exercise_name: string`
    - `trend: string` - `"improving"` | `"plateaued"` | `"declining"`
    - `e1rm_slope: number` - Rate of estimated 1RM change
    - `note: string` - Context for the trend
  - `progression_candidates: Array<object>` - Exercises ready for weight increase:
    - `exercise_name: string`
    - `current_weight: number` - Current working weight (kg)
    - `suggested_weight: number` - Recommended next weight (kg)
    - `rationale: string` - Why this progression is suggested
    - `confidence: number` - 0-1 confidence score
  - `stalled_exercises: Array<object>` - Exercises with no progression:
    - `exercise_name: string`
    - `weeks_stalled: number` - How many weeks without progress
    - `suggested_action: string` - Recommended intervention
    - `rationale: string` - Why this action is suggested
  - `periodization?: object` - Training phase assessment (optional, LLM may not always produce):
    - `current_phase: string` - Current training phase (e.g., "hypertrophy", "strength", "deload")
    - `weeks_in_phase: number` - How long in current phase
    - `suggestion: string` - Phase transition recommendation
    - `reasoning: string` - Evidence-based rationale
  - `routine_recommendations?: Array<object>` - Routine-level suggestions (optional, LLM may not always produce):
    - `type: string` - Recommendation type (e.g., "volume_adjust", "exercise_swap", "frequency_change")
    - `target: string` - What to adjust (muscle group, exercise, etc.)
    - `suggestion: string` - Specific recommendation
    - `reasoning: string` - Evidence-based rationale
  - `fatigue_status?: object` - Fatigue assessment (optional, LLM may not always produce):
    - `overall_acwr: number` - Overall Acute:Chronic Workload Ratio
    - `interpretation: string` - What the ACWR means (e.g., "optimal", "building fatigue", "overreached")
    - `flags: Array<string>` - Warning flags (e.g., "high_acwr", "rapid_load_increase")
    - `recommendation: string` - Fatigue management advice
  - `created_at: Timestamp`

---

## Catalog Admin v2 Collections

### catalog_jobs/{jobId}
Job queue for catalog curation operations.

- Fields:
  - `id: string` (document ID)
  - `type: string` - Job type enum:
    - `MAINTENANCE_SCAN`, `DUPLICATE_DETECTION_SCAN`, `ALIAS_INVARIANT_SCAN`
    - `FAMILY_AUDIT`, `FAMILY_NORMALIZE`, `FAMILY_MERGE`, `FAMILY_SPLIT`, `FAMILY_RENAME_SLUG`
    - `EXERCISE_ADD`, `TARGETED_FIX`, `ALIAS_REPAIR`
  - `queue: 'priority' | 'maintenance'`
  - `priority: number` (higher wins)
  - `status: string`:
    - `queued`, `leased`, `running`, `succeeded`, `succeeded_dry_run`
    - `failed`, `needs_review`, `deadletter`, `deferred`
  - `payload: object`:
    - `family_slug?: string`
    - `exercise_doc_ids?: string[]`
    - `alias_slugs?: string[]`
    - `mode: 'dry_run' | 'apply'`
    - `intent?: object` (for EXERCISE_ADD)
    - `merge_config?: object` (for FAMILY_MERGE)
    - `split_config?: object` (for FAMILY_SPLIT)
    - `rename_config?: object` (for FAMILY_RENAME_SLUG)
  - `lease_owner?: string`
  - `lease_expires_at?: Timestamp`
  - `attempts: number`
  - `max_attempts: number` (default 5)
  - `run_after?: Timestamp`
  - `result_summary?: object`
  - `error?: object`
  - `created_at, updated_at: Timestamp`

### catalog_job_runs/{jobId}/attempts/{attemptId}
Attempt logs for job execution debugging.

- Fields:
  - `id: string`
  - `job_id: string`
  - `attempt_number: number`
  - `worker_id: string`
  - `started_at, completed_at?: Timestamp`
  - `status: 'running' | 'succeeded' | 'failed'`
  - `change_plan?: object`
  - `validator_output?: object`
  - `operations_applied: number`
  - `operations_skipped: number`
  - `journal_id?: string`
  - `error?: object`
  - `events: Array<{ type, timestamp, data }>`

### catalog_locks/{family_slug}
Family-level locks for concurrent mutation prevention.

- Fields:
  - `family_slug: string` (document ID)
  - `lease_owner: string`
  - `lease_expires_at: Timestamp`
  - `job_id: string`
  - `acquired_at: Timestamp`

### catalog_changes/{changeId}
Journal of all applied mutations for audit trail.

- Fields:
  - `change_id: string` (document ID, format: `{job_id}_{attempt_id}`)
  - `job_id: string`
  - `attempt_id: string`
  - `operations: Array<object>`:
    - `operation_index: number`
    - `operation_type: string`
    - `targets: string[]`
    - `before?: object`
    - `after?: object`
    - `idempotency_key?: string`
    - `rationale: string`
    - `success: boolean`
    - `error?: string`
    - `executed_at: Timestamp`
  - `operation_count, successful_count, failed_count: number`
  - `started_at, completed_at: Timestamp`
  - `result_summary?: string`

### catalog_idempotency/{key}
Idempotency records for duplicate operation prevention.

- Fields:
  - `key: string` (document ID, format: `{job_id}:{operation_index}:{seed}`)
  - `job_id: string`
  - `operation_type: string`
  - `targets: string[]`
  - `result: 'success' | 'failed'`
  - `executed_at: Timestamp`
  - `expires_at: Timestamp` (TTL: 7 days)

### exercise_families/{family_slug}
Optional family registry for canonical family metadata.

- Fields:
  - `family_slug: string` (document ID)
  - `base_name: string`
  - `status: 'active' | 'deprecated' | 'merged_into:<slug>'`
  - `allowed_equipments: string[]`
  - `canonical_variants?: string[]`
  - `primary_equipment_set: string[]`
  - `notes?: string`
  - `known_collisions?: string[]`
  - `created_at, updated_at: Timestamp`

---

## Exercises Collection - Enriched Fields

The `exercises/{exerciseId}` collection includes additional enriched fields populated by AI agents:

- `enriched_instructions?: string[]` - AI-enhanced step-by-step instructions
- `enriched_tips?: string[]` - AI-enhanced training tips
- `enriched_cues?: string[]` - AI-enhanced coaching cues
- `enriched_at?: Timestamp` - When enrichment was performed
- `enriched_by?: string` - Agent/process that performed enrichment

These fields are treated as canonical schema extensions. Validators should not reject documents containing these fields.

---

## Catalog Admin v2 Summary Diagram

```
catalog_jobs/{jobId}                    # Job queue
  └─ catalog_job_runs/{jobId}/attempts/{attemptId}  # Attempt logs

catalog_locks/{family_slug}             # Family locks
catalog_changes/{changeId}              # Mutation journal
catalog_idempotency/{key}               # Idempotency records
exercise_families/{family_slug}         # Family registry (optional)
```
