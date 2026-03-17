# Monitoring & Analytics

> Cross-platform analytics instrumentation and server-side observability.

---

## iOS — Firebase Analytics (GA4)

Firebase Analytics is enabled via `IS_ANALYTICS_ENABLED` in `GoogleService-Info.plist`. All events are fired through `AnalyticsService.swift`, a singleton wrapper around `Analytics.logEvent()` that provides typed methods organized by 9 domains. Type-safe enums (`AnalyticsWorkoutSource`, `AnalyticsArtifactAction`, etc.) and parameter structs (`WorkoutCompletedParams`, `ConversationEndedParams`) prevent typos and enforce consistency.

**Debug verification**: Enable Analytics debug mode in Xcode scheme → Arguments → `-FIRAnalyticsDebugEnabled`. Events print to console in DEBUG builds (`[Analytics]` prefix).

**Event Taxonomy (~53 events across 9 domains)**:

*Domain 1 — Authentication*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `signup_started` | `provider` | `RegisterView` on signup button tap |
| `signup_completed` | `provider` | `AuthService.signUp`, `confirmSSOAccountCreation` |
| `login_completed` | `provider` | `LoginView` on successful auth |
| `sso_confirmation_shown` | `provider` | `LoginView` / `RegisterView` SSO dialog |
| `sso_confirmation_cancelled` | `provider` | `LoginView` / `RegisterView` cancel |

*Domain 2 — AI Coaching & Conversations*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `quick_action_tapped` | `action` | `CoachTabView` quick action card |
| `conversation_started` | `entry_point` | `CanvasViewModel.start()` |
| `message_sent` | `message_length`, `conversation_depth` | `CanvasViewModel.startSSEStream()` |
| `first_message_sent` | — | Milestone (once per install) |
| `artifact_received` | `artifact_type`, `conversation_depth` | `CanvasViewModel.handleIncomingStreamEvent` |
| `first_artifact_received` | — | Milestone (once per install) |
| `artifact_action` | `action`, `artifact_type` | `CanvasViewModel.applyAction()` |
| `conversation_ended` | `conversation_depth`, `artifacts_received`, `artifacts_accepted`, `duration_sec` | `CanvasViewModel.stop()` / scene background |

*Domain 3 — Workout Execution*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `workout_start_viewed` | `has_next_scheduled`, `template_count` | `FocusModeWorkoutScreen` start view |
| `workout_started` | `source`, `workout_id`, `template_id?`, `routine_id?`, `planned_exercise_count` | `FocusModeWorkoutService.startWorkout()` |
| `workout_first_set_logged` | `workout_id`, `seconds_to_first_set` (capped 600) | `FocusModeWorkoutService.logSet()` (first set only) |
| `set_logged` | `workout_id`, `exercise_position`, `set_index`, `is_warmup`, `logged_via` | `FocusModeWorkoutService.logSet()` |
| `first_workout_completed` | — | Milestone (once per install) |
| `exercise_added` | `workout_id`, `source` | `FocusModeWorkoutService` |
| `exercise_removed` | `workout_id` | `FocusModeWorkoutService` |
| `exercise_swapped` | `workout_id`, `source` | `FocusModeWorkoutService` |
| `exercise_reordered` | `workout_id` | `FocusModeWorkoutService` |
| `workout_coach_opened` | `workout_id`, `elapsed_min`, `sets_logged` | `WorkoutCoachViewModel` |
| `workout_coach_msg_sent` | `workout_id`, `message_length` | `WorkoutCoachViewModel` |
| `workout_completed` | `workout_id`, `duration_min`, `exercise_count`, `total_sets`, `sets_completed`, `source`, `template_id?`, `routine_id?` | `FocusModeWorkoutService.completeWorkout()` |
| `workout_cancelled` | `workout_id`, `duration_min`, `sets_completed`, `total_sets` | `FocusModeWorkoutService.cancelWorkout()` |

*Domain 4 — Library & Content*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `library_section_opened` | `section` | `LibraryView` |
| `routine_viewed` | `routine_id`, `template_count` | `LibraryView` → routine detail |
| `routine_edited` | `routine_id`, `edit_type` | `RoutineDetailView` |
| `template_viewed` | `template_id`, `exercise_count`, `source` | `LibraryView` → template detail |
| `template_edited` | `template_id`, `edit_type` | `TemplateDetailView` |
| `exercise_searched` | `has_query`, `filter_count`, `result_count` | `ExercisesListView` |
| `exercise_detail_viewed` | `exercise_id`, `source` | `ExercisesListView` detail |

*Domain 5 — Recommendations*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `recommendation_bell_tapped` | `pending_count` | `MainTabsView` |
| `recommendation_viewed` | `type`, `scope` | `RecommendationsViewModel` |
| `recommendation_accepted` | `type`, `scope` | `RecommendationsViewModel.accept()` |
| `recommendation_rejected` | `type`, `scope` | `RecommendationsViewModel.reject()` |
| `auto_pilot_toggled` | `enabled` | `ProfileView` |

*Domain 6 — Monetization*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `premium_gate_hit` | `feature`, `gate_type` | `PaywallView` |
| `paywall_shown` | `trigger` | `PaywallView.onAppear` |
| `paywall_dismissed` | `trigger`, `time_on_screen_sec` | `PaywallView` close button |
| `trial_started` | `product_id` | `SubscriptionService.purchase()` |
| `subscription_purchased` | `product_id`, `is_from_trial`, `value`, `currency` | `SubscriptionService.purchase()` |
| `subscription_restored` | — | `SubscriptionService.restorePurchases()` |

*Domain 7 — History & Review*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `workout_history_viewed` | `workout_id`, `days_ago` | `HistoryView` → detail |
| `workout_history_edited` | `workout_id`, `edit_type` | `WorkoutEditView` |
| `workout_history_deleted` | `workout_id`, `days_ago` | `HistoryView` |

*Domain 8 — Profile & Settings*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `body_metrics_updated` | `field` | `ProfileView` |
| `preference_changed` | `preference`, `value` | `ProfileView` |
| `account_deleted` | — | `DeleteAccountView` |

*Domain 9 — App Lifecycle & Navigation*

| GA4 Event | Parameters | Call Site |
|-----------|-----------|-----------|
| `app_opened` | — | `PovverApp.swift` on launch |
| `tab_viewed` | `tab` | `MainTabsView` on tab switch |
| `screen_viewed` | `screen` | `RootView` (DEPRECATED — 30-day transition, then remove) |
| `streaming_error` | `error_code`, `context` | `CanvasViewModel.startSSEStream()` |

**Workout event correlation**: All workout lifecycle events share a `workout_id` parameter. `workout_started` includes `source`, `template_id`, and `routine_id` so you can join start → first-set → completion rates by origin.

**Conversation depth tracking**: `CanvasViewModel` maintains a 1-indexed `conversationDepth` counter, reset on new conversations. Incremented synchronously before async send. Passed to `message_sent`, `artifact_received`, and `conversation_ended` for funnel depth analysis. `conversation_ended` includes `artifacts_received`, `artifacts_accepted`, and `duration_sec`.

**Milestone events** (fire once per install via UserDefaults guard): `first_message_sent`, `first_artifact_received`, `first_workout_completed`. These fire automatically inside `messageSent()`, `artifactReceived()`, and `workoutCompleted()`.

**User Properties (16 of 25 GA4 slots)**: Set via `Analytics.setUserProperty()`. Counters persisted in `UserDefaults`. Synced via `syncUserPropertiesIfNeeded()` (daily debounce). Calculated properties (`workout_completion_rate`, `avg_workout_duration_min`, `primary_workout_source`, `coach_engagement_level`) only set after threshold data exists (5+ workouts or 10+ sessions). Properties: `subscription_status`, `fitness_level`, `total_workouts`, `total_conversations`, `has_active_routine`, `auto_pilot_enabled`, `workout_completion_rate`, `avg_workout_duration_min`, `primary_workout_source`, `days_since_signup`, `days_since_last_workout`, `total_templates`, `total_routines`, `signup_provider`, `coach_engagement_level`, `install_source`.

**GA4 Key Events**: `signup_completed`, `artifact_action` (accept/start_workout/save_as_template/save_routine), `workout_completed`, `workout_first_set_logged`, `trial_started`, `subscription_purchased` (with `value` + `currency` for revenue), `recommendation_accepted`.

**Key Funnels**: (1) Acquisition: landing_page_viewed → app_store_click → app_opened → signup_completed. (2) New User Activation: signup_completed → conversation_started → first_message_sent → first_artifact_received → artifact_action(accept). (3) Workout Habit: first_workout_completed → 2nd/3rd/4th within 21d. (4) AI Coaching Depth: conversation_started → message_sent(depth=1) → artifact_received → artifact_action → message_sent(depth=2). (5) Workout Execution: workout_started → workout_first_set_logged → set_logged(10+) → workout_completed. (6) Monetization: premium_gate_hit → paywall_shown → trial_started/subscription_purchased. (7) Recommendation Trust: recommendation_bell_tapped → recommendation_viewed → recommendation_accepted. (8) Template Lifecycle: artifact_action(save_as_template) → template_viewed → workout_started(source=template).

**User identity**: `Analytics.setUserID()` is called in `AuthService`'s auth state listener alongside Crashlytics. Same GA4 property (`G-V9YHQNJTB7`) used on both iOS and web for cross-platform funnel tracking.

---

## Server-Side — Structured Cloud Logging

All server-side logs use structured JSON with an `event` field for Cloud Logging filter queries.

**Firebase Functions**:

| Event | File | Filter | Key Fields |
|-------|------|--------|------------|
| `stream_completed` | `stream-agent-normalized.js` | `jsonPayload.event="stream_completed"` | `success`, `latency_ms`, `user_id`, `conversation_id`, `artifact_count`, `data_chunks` |
| `subscription_event_received` | `app-store-webhook.js` | `jsonPayload.event="subscription_event_received"` | `notification_type`, `subtype` |
| `subscription_updated` | `app-store-webhook.js` | `jsonPayload.event="subscription_updated"` | `user_id`, `status`, `tier` |

**Python Agent** (`adk_agent/canvas_orchestrator/`):

| Event | File | Filter | Key Fields |
|-------|------|--------|------------|
| `agent_request_completed` | `agent_engine_app.py` | `jsonPayload.event="agent_request_completed"` | `lane`, `intent`, `workout_mode`, `latency_ms`, `user_id` |
| `tool_called` | `shell/tools.py` | `jsonPayload.event="tool_called"` | `tool`, `success`, `latency_ms`, `error` |

The `@timed_tool` decorator on all tool functions in `tools.py` provides per-tool latency tracking.

---

## Cloud Monitoring (Manual Setup)

**Log-based metrics** (configure in Cloud Console):
- `stream_latency_ms`: Distribution on `jsonPayload.latency_ms` from `stream_completed` events (filter `jsonPayload.success=true` to exclude failed streams)
- `tool_latency_ms`: Distribution on `jsonPayload.latency_ms` from `tool_called` events, grouped by `jsonPayload.tool`
- `agent_request_latency_ms`: Distribution from `agent_request_completed` events, grouped by `jsonPayload.lane`

**Dashboards**:
- **Product Health** (Firebase Console / GA4): Activation funnel, WAU, subscription funnel, retention cohorts
- **System Health** (Cloud Monitoring): Stream latency by lane, tool latency, error rates, function invocations

---

## LLM Usage Tracking (Cost Attribution)

Self-tracked token accounting for per-user, per-system cost visibility. Vertex AI billing shows a flat total — this system breaks it down.

**How it works**: Each LLM call records token counts from `usage_metadata` to the top-level `llm_usage` Firestore collection. Writes are fire-and-forget (failures logged, never crash callers). Gated by `ENABLE_USAGE_TRACKING` env var (default: `false`).

**Categories**:
| Category | System | User Context | Example |
|----------|--------|-------------|---------|
| `system` | Catalog Orchestrator | None | Exercise enrichment |
| `user_scoped` | Training Analyst | Per-user | Post-workout analysis |
| `user_initiated` | Canvas Orchestrator | Per-user | Shell agent chat, functional lane |

**Implementation**: Centralized in `adk_agent/shared/usage_tracker.py`. Each agent system imports it differently (see `adk_agent/shared/ARCHITECTURE.md`).

**Cost estimation**: Token counts are stored raw. Cost in EUR is computed at query time using rates in `adk_agent/shared/llm_pricing.py`. Query with `node scripts/query_llm_usage.js --weeks N [--user UID] [--csv]`.

**Firestore collection**: `llm_usage/{auto_id}` — see `docs/FIRESTORE_SCHEMA.md` for field definitions. Requires composite index: `(user_id ASC, created_at ASC)`.
