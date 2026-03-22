# Firebase Functions Architecture

> **Document Purpose**: Complete documentation of the Firebase Functions backend layer. Written for LLM/agentic coding agents.

---

## Table of Contents

1. [Overview](#overview)
2. [Function Categories](#function-categories)
3. [Authentication & Middleware](#authentication--middleware)
4. [Conversation Operations](#conversation-operations)
5. [Agent Operations](#agent-operations)
6. [Active Workout Operations](#active-workout-operations)
7. [CRUD Operations](#crud-operations)
8. [Firestore Triggers](#firestore-triggers)
9. [Analytics Functions](#analytics-functions)
10. [Exercise Catalog Operations](#exercise-catalog-operations)
11. [Directory Structure](#directory-structure)

---

## Overview

Firebase Functions serve as the backend API layer for the Povver fitness platform. Functions are deployed to Google Cloud and provide:

- RESTful HTTP endpoints for CRUD operations
- Conversation and artifact lifecycle management
- Agent streaming proxy to Agent Service (Cloud Run)
- Firestore triggers for real-time data processing
- Scheduled jobs for analytics and maintenance

**Runtime**: Node.js 22
**Region**: us-central1
**Framework**: Firebase Functions (Gen 1 and Gen 2)

---

## Function Categories

### HTTP Functions by Domain

| Domain | Functions | Auth Type |
|--------|-----------|-----------|
| **User** | `getUser`, `updateUser`, `getUserPreferences`, `updateUserPreferences`, `upsertUserAttributes`, `deleteAccount` | API Key / Flexible |
| **Workouts** | `getUserWorkouts`, `getWorkout`, `upsertWorkout`, `deleteWorkout` | API Key / Flexible |
| **Templates** | `getUserTemplates`, `getTemplate`, `createTemplate`, `updateTemplate`, `deleteTemplate`, `createTemplateFromPlan`, `patchTemplate` | API Key / Flexible |
| **Routines** | `getUserRoutines`, `getRoutine`, `createRoutine`, `updateRoutine`, `deleteRoutine`, `getActiveRoutine`, `setActiveRoutine`, `getNextWorkout`, `patchRoutine` | API Key / Flexible |
| **Exercises** | `getExercises`, `getExercise`, `searchExercises`, `upsertExercise`, `approveExercise`, `ensureExerciseExists`, `resolveExercise`, `mergeExercises` | API Key |
| **Conversations** | `artifactAction` | Flexible Auth |
| **Sessions** | ~~`initializeSession`~~, ~~`preWarmSession`~~, ~~`cleanupSessions`~~ | **(REMOVED — sessions eliminated)** |
| **MCP API Keys** | `generateMcpApiKey`, `listMcpApiKeys`, `revokeMcpApiKey` | Flexible Auth |
| **MCP OAuth** | `getMcpConnectionStatus`, `revokeMcpTokens`, `cleanupMcpTokens` | Flexible / Scheduled |
| **Active Workout** | `startActiveWorkout`, `getActiveWorkout`, `logSet`, `completeCurrentSet`, `addExercise`, `swapExercise`, `completeActiveWorkout`, `cancelActiveWorkout`, `proposeSession`, `patchActiveWorkout`, `autofillExercise` | Flexible Auth |
| **Agents** | `invokeAgent`, `getPlanningContext`, `streamAgentNormalized` | Flexible Auth |
| **Subscriptions** | `appStoreWebhook`, `syncSubscriptionStatus` | None (webhook) / Flexible (sync) |
| **Analytics** | `runAnalyticsForUser`, `compactAnalyticsForUser`, `recalculateWeeklyForUser` | Flexible Auth |
| **Training Analysis** | `getAnalysisSummary`, `getMuscleGroupSummary`, `getMuscleSummary`, `getExerciseSummary`, `querySets`, `aggregateSets`, `getActiveSnapshotLite`, `getActiveEvents` | Flexible Auth |

---

## Authentication & Middleware

### Authentication Lanes

See `docs/SECURITY.md` → "Authentication Model" for the authoritative reference on auth lanes, middleware types (`requireFlexibleAuth`, `withApiKey`, `requireAuth`), and IDOR prevention.

Each endpoint below is annotated with its auth lane. The per-endpoint auth lane annotations in this doc are the source of truth for *which* lane each endpoint uses.

---

## Conversation Operations

Conversations are the primary AI interaction surface. The agent streams messages and emits artifacts (workout plans, routines, analyses) that users can accept, dismiss, or save.

### Artifact Lifecycle

`artifactAction` handles all artifact lifecycle operations:

**Location**: `artifacts/artifact-action.js`
**Auth**: `requireFlexibleAuth` (Bearer lane)

**Input**:
```javascript
{
  userId: string,           // Derived from auth token (req.auth.uid)
  conversationId: string,
  artifactId: string,
  action: string,           // "accept" | "dismiss" | "save_routine" | "start_workout"
  day?: number              // Optional, for routine/template actions
}
```

**Actions**:

| Action | Description | Effect |
|--------|-------------|--------|
| `accept` | Accept artifact | Updates artifact status to "accepted" |
| `dismiss` | Dismiss artifact | Updates artifact status to "dismissed" |
| `save_routine` | Save workout plan as routine | Creates routine document from artifact data |
| `start_workout` | Start workout from plan | Creates active workout from artifact data |

**Output**:
```javascript
{
  success: true,
  artifact: { /* updated artifact document */ },
  routine?: { /* created routine document (if save_routine) */ },
  workout?: { /* created workout document (if start_workout) */ }
}
```

### Session Management (REMOVED)

Sessions have been eliminated. The agent service is fully stateless with per-request context. Conversations are created lazily on first message via `streamAgentNormalized`.

**Removed functions**:
- `initializeSession` — `sessions/initialize-session.js` (REMOVED)
- `preWarmSession` — `sessions/pre-warm-session.js` (REMOVED)
- `cleanupSessions` — `sessions/cleanup-sessions.js` (REMOVED)

### MCP API Key Management

**`generateMcpApiKey`** - Generate API key for MCP Server access:

**Location**: `mcp/generate-api-key.js`
**Auth**: `requireFlexibleAuth` (Bearer lane, premium-gated)

**`listMcpApiKeys`** - List user's MCP API keys:

**Location**: `mcp/list-api-keys.js`
**Auth**: `requireFlexibleAuth`

**`revokeMcpApiKey`** - Revoke an MCP API key:

**Location**: `mcp/revoke-api-key.js`
**Auth**: `requireFlexibleAuth`

---

## Agent Operations

### Streaming Architecture

`streamAgentNormalized` proxies SSE streams from the Agent Service on Cloud Run:

```
iOS App → Firebase Function → Agent Service (Cloud Run)
           (SSE proxy)         (4-Lane Router)
```

**Location**: `strengthos/stream-agent-normalized.js`
**Auth**: `requireFlexibleAuth`

**Input**:
```javascript
{
  conversationId: string,    // Primary identifier (canvasId supported for backward compat)
  message: string,
  userId?: string            // Derived from auth token (req.auth.uid)
}
```

**Stream Event Types:**
- `thinking` - Agent processing indicator
- `thought` - Agent reasoning content
- `tool_start` / `tool_end` - Tool execution lifecycle
- `message` - Agent text response chunk
- `artifact` - Artifact publication event (workout plan, routine, analysis)
- `error` - Error notification

**Message Persistence**:
- User messages persisted to `conversations/{id}/messages`
- Agent messages persisted to `conversations/{id}/messages`
- Replaces old `workspace_entries` collection

**Artifact Detection**:
- Agent tool responses are scanned for `artifact_type` field
- When detected, artifact is emitted as SSE event and persisted to `conversations/{id}/artifacts`
- Artifact types: `workout_plan`, `routine`, `analysis`, etc.

### Agent Invocation

`invokeAgent` triggers agent execution:

**Location**: `agents/invoke-agent.js` (renamed from `invoke-canvas-orchestrator.js`)
**Auth**: `requireFlexibleAuth`

- Forwards user message to agent
- Agent streams responses via `streamAgentNormalized`
- Agent tools emit artifacts directly in responses

### Planning Context

`getPlanningContext` provides agent with user context:

**Location**: `agents/get-planning-context.js`
**Auth**: `requireFlexibleAuth`

**Returns**:
- User preferences and goals
- Workout history
- Active routine information
- Exercise catalog access
- `strengthSummary`: Top 15 exercises by e1RM, derived from recent workouts (zero extra Firestore reads). Each entry: `{ id, name, weight, reps, e1rm }`. Used by the agent to estimate weights for exercises the user hasn't done.

---

## Active Workout Operations

### Workout Lifecycle

| Function | Description |
|----------|-------------|
| `proposeSession` | Generate workout proposal from template/routine |
| `startActiveWorkout` | Create active workout document |
| `getActiveWorkout` | Retrieve current workout state |
| `logSet` | Log completed set |
| `completeCurrentSet` | Mark next planned set done (fast lane) |
| `addExercise` | Add exercise to workout |
| `swapExercise` | Replace exercise in workout |
| `completeActiveWorkout` | Finalize and persist workout |
| `cancelActiveWorkout` | Discard active workout |
| `patchActiveWorkout` | Edit set values, add/remove sets (homogeneous ops per request) |
| `autofillExercise` | AI bulk prescription for a single exercise's planned sets |

### Active Workout Document

```javascript
{
  user_id: string,
  source_template_id: string,           // Template workout was started from
  source_routine_id: string | null,     // Required for cursor advancement
  start_time: Timestamp,
  exercises: [
    {
      instance_id: string,              // Stable ID within workout
      exercise_id: string,              // Catalog reference
      name: string,
      sets: [{ id: string, reps: number, weight: number, rir: number, status: string }]
    }
  ],
  status: 'in_progress' | 'completed' | 'cancelled'
}
```

**Response from startActiveWorkout**:
```javascript
{
  "success": true,
  "workout_id": "...",
  "workout": { /* in-progress workout document */ },
  "resumed": false  // true if existing in-progress workout was returned
}
```

---

## Workout Operations

Completed workout history management. Auth: `requireFlexibleAuth` (Bearer lane).

| Function | Description |
|----------|-------------|
| `getUserWorkouts` | Fetch paginated workout history with analytics |
| `getWorkout` | Fetch single workout with full metrics |
| `upsertWorkout` | Create or update workout with inline analytics and set_facts generation (used by import scripts) |
| `deleteWorkout` | Delete completed workout. Firestore trigger `onWorkoutDeleted` in `weekly-analytics.js` handles weekly_stats rollback automatically |

---

## CRUD Operations

### User Operations

| Function | Path | Method |
|----------|------|--------|
| `getUser` | `/getUser?userId={id}` | GET |
| `updateUser` | `/updateUser` | POST |
| `getUserPreferences` | `/getUserPreferences?userId={id}` | GET |
| `updateUserPreferences` | `/updateUserPreferences` | POST |
| `upsertUserAttributes` | `/upsertUserAttributes` | POST |

### Template Operations

| Function | Path | Method |
|----------|------|--------|
| `getUserTemplates` | `/getUserTemplates?userId={id}` | GET |
| `getTemplate` | `/getTemplate?id={id}&userId={userId}` | GET |
| `createTemplate` | `/createTemplate` | POST |
| `updateTemplate` | `/updateTemplate` | PUT |
| `deleteTemplate` | `/deleteTemplate` | DELETE |
| `createTemplateFromPlan` | `/createTemplateFromPlan` | POST |
| `patchTemplate` | `/patchTemplate` | PATCH |

### Routine Operations

| Function | Path | Method |
|----------|------|--------|
| `getUserRoutines` | `/getUserRoutines?userId={id}` | GET |
| `getRoutine` | `/getRoutine` (body: `{routineId}`, userId from auth) | POST |
| `createRoutine` | `/createRoutine` | POST |
| `updateRoutine` | `/updateRoutine` | PUT |
| `deleteRoutine` | `/deleteRoutine` | DELETE |
| `getActiveRoutine` | `/getActiveRoutine?userId={id}` | GET |
| `setActiveRoutine` | `/setActiveRoutine` | POST |
| `getNextWorkout` | `/getNextWorkout` | POST |
| `patchRoutine` | `/patchRoutine` | PATCH |

---

## Firestore Triggers

### Muscle Volume Calculations

| Trigger | Event | Purpose |
|---------|-------|---------|
| `onTemplateCreated` | Template create | Calculate muscle volume targets |
| `onTemplateUpdated` | Template update | Recalculate muscle volumes |
| `onWorkoutCreated` | Workout create | Calculate actual muscle volumes |

### Workout Completion Pipeline (Cloud Tasks)

Workout creation/completion now uses **Cloud Tasks** instead of Firestore triggers for reliability, retries, and observability.

| Component | Type | Purpose |
|-----------|------|---------|
| `enqueue-workout-task.js` | Utility | Enqueues workout to `workout-completion` Cloud Tasks queue |
| `workout-completion-task.js` | HTTP (Cloud Tasks) | Receives `{userId, workoutId}`, delegates to `process-workout-completion.js` |
| `process-workout-completion.js` | Pipeline | Unified handler: weekly stats, analytics series, routine cursor, training analysis enqueue. Idempotent via `completion_watermark`. |
| `workout-completion-watchdog.js` | Scheduled (daily) | Scans 48h for workouts missing `completion_watermark`, re-enqueues |

Enqueue points: `complete-active-workout.js`, `upsert-workout.js`

### Weekly Analytics (Remaining Triggers)

| Trigger | Event | Purpose |
|---------|-------|---------|
| `onWorkoutDeleted` | Workout delete | Adjust weekly totals, decrement exercise usage stats |

Note: `onWorkoutCompleted`, `onWorkoutCreatedWithEnd`, `onWorkoutCreatedWeekly`, `onWorkoutFinalizedForUser`, and `onWorkoutCreatedUpdateRoutineCursor` have been replaced by the Cloud Tasks workout completion pipeline above.

---

## Analytics Functions

### Weekly Stats Recalculation

- `weeklyStatsRecalculation` - Scheduled weekly recalculation
- `manualWeeklyStatsRecalculation` - Callable manual trigger
- `recalculateWeeklyForUser` - Per-user recalculation

### Analytics Compaction

- `analyticsCompactionScheduled` - Scheduled compaction job
- `compactAnalyticsForUser` - Per-user compaction

### Analytics Features

- `runAnalyticsForUser` - Run analytics pipeline for user
- `publishWeeklyJob` - Publish weekly analytics job to queue

### Training Analysis (Pre-computed)

- `getAnalysisSummary` - Retrieve pre-computed training analysis (insights, weekly review). Supports `sections`, `date`, `limit` params. Called by Shell Agent's `tool_get_training_analysis`.
- `getMuscleGroupSummary` / `getMuscleSummary` / `getExerciseSummary` - Live drilldown summaries for specific muscles/exercises. `getExerciseSummary` accepts `exercise_name` for fuzzy name→ID resolution via the user's `set_facts`
- `querySets` / `aggregateSets` - Raw set-level data queries with filtering (v2 onRequest + requireFlexibleAuth; converted from onCall for HTTP client compatibility). When date range filters (`start`/`end`) are present, sorts by `workout_date` instead of `workout_end_time` to satisfy Firestore's compound query constraint (first orderBy must match the inequality field)
- `getActiveSnapshotLite` - Lightweight active workout state snapshot
- `getActiveEvents` - Paginated workout event stream

---

## Exercise Catalog Operations

### Core CRUD

| Function | Purpose |
|----------|---------|
| `getExercises` | List all exercises |
| `getExercise` | Get single exercise by ID |
| `searchExercises` | Full-text search with filters |
| `upsertExercise` | Create or update exercise |
| `approveExercise` | Mark exercise as approved |

### Resolution & Aliases

| Function | Purpose |
|----------|---------|
| `ensureExerciseExists` | Create if not exists |
| `resolveExercise` | Resolve alias to canonical exercise |
| `upsertAlias` | Create exercise alias |
| `deleteAlias` | Remove exercise alias |
| `searchAliases` | Search alias database |
| `suggestAliases` | AI-powered alias suggestions |

### Catalog Maintenance

| Function | Purpose |
|----------|---------|
| `mergeExercises` | Merge duplicate exercises |
| `normalizeCatalog` | Normalize exercise names |
| `normalizeCatalogPage` | Paginated normalization |
| `backfillNormalizeFamily` | Backfill family normalization |
| `listFamilies` | List exercise families |
| `repointAlias` | Update alias target |
| `repointShorthandAliases` | Batch update shorthand aliases |
| `backupExercises` | Create exercise catalog backup |

### AI-Powered

| Function | Purpose |
|----------|---------|
| `suggestFamilyVariant` | Suggest family classification |
| `refineExercise` | AI refinement of exercise metadata |

---

## Subscription Operations

### App Store Webhook

`appStoreWebhook` handles Apple App Store Server Notifications V2:

**Location**: `subscriptions/app-store-webhook.js`
**Auth**: None — Apple calls this URL directly with a signed JWS payload. The webhook URL itself serves as access control.

**Input**: `{ signedPayload: string }` (JWS-signed notification from Apple)

**Processing**:
1. Verifies outer JWS notification using Apple root certificates via shared `apple-verifier.js` module
2. Decodes `signedTransactionInfo` and `signedRenewalInfo` from inner JWS payloads
3. Looks up user by `subscription_app_account_token` (lowercased UUID v5), fallback by `subscription_original_transaction_id`
4. Maps notification type to subscription field updates (see notification mapping in `SYSTEM_ARCHITECTURE.md`)
5. Updates `users/{uid}` subscription fields
6. Invalidates profile cache via `invalidateProfileCache(userId)` from `user/get-user.js`
7. Logs event to `users/{uid}/subscription_events/{auto-id}`
8. Always returns HTTP 200 (Apple retries non-200s indefinitely)

### Subscription Gate

**Location**: `utils/subscription-gate.js`

**Export**: `isPremiumUser(userId)` → `Promise<boolean>`

**Logic**: Direct Firestore read (not cached — subscription status must be fresh):
1. `subscription_override === 'premium'` → `true` (admin override)
2. `subscription_tier === 'premium'` → `true` (active subscription)
3. Otherwise → `false`

**Used by**:
- `strengthos/stream-agent-normalized.js` — Premium gate before AI streaming (emits SSE error `PREMIUM_REQUIRED`)
- `triggers/weekly-analytics.js` — Skips training analysis job enqueueing for free users (free analytics still run)

---

## Directory Structure

```
firebase_functions/functions/
├── index.js                    # All exports and routing
├── package.json                # Dependencies
├── README.md                   # Basic readme
├── active_workout/             # Active workout endpoints
│   ├── add-exercise.js
│   ├── autofill-exercise.js
│   ├── cancel-active-workout.js
│   ├── complete-active-workout.js
│   ├── complete-current-set.js
│   ├── get-active-workout.js
│   ├── log-set.js
│   ├── patch-active-workout.js
│   ├── propose-session.js
│   ├── start-active-workout.js
│   └── swap-exercise.js
├── agents/                     # Agent invocation
│   ├── get-planning-context.js
│   └── invoke-agent.js         # Renamed from invoke-canvas-orchestrator.js
├── aliases/                    # Exercise alias management
│   ├── delete-alias.js
│   └── upsert-alias.js
├── analytics/                  # Analytics pipeline
│   ├── compaction.js
│   ├── controller.js
│   ├── get-features.js
│   ├── publish-weekly-job.js
│   └── recalculate-weekly-for-user.js
├── artifacts/                  # Artifact lifecycle
│   └── artifact-action.js      # Accept, dismiss, save_routine, start_workout
├── auth/                       # Authentication middleware
│   ├── exchange-token.js       # (REMOVED — sessions eliminated)
│   └── middleware.js
├── exercises/                  # Exercise catalog
│   ├── approve-exercise.js
│   ├── backfill-normalize-family.js
│   ├── ensure-exercise-exists.js
│   ├── get-exercise.js
│   ├── get-exercises.js
│   ├── list-families.js
│   ├── merge-exercises.js
│   ├── normalize-catalog-page.js
│   ├── normalize-catalog.js
│   ├── refine-exercise.js
│   ├── resolve-exercise.js
│   ├── search-aliases.js
│   ├── search-exercises.js
│   ├── suggest-aliases.js
│   ├── suggest-family-variant.js
│   └── upsert-exercise.js
├── health/                     # Health check
│   └── health.js
├── maintenance/                # Maintenance scripts
│   ├── backup-exercises.js
│   ├── repoint-alias.js
│   └── repoint-shorthand-aliases.js
├── recommendations/            # Recommendation endpoints
│   └── review-recommendation.js  # Accept/reject recommendations
├── routines/                   # Routine operations
│   ├── create-routine-from-draft.js
│   ├── create-routine.js
│   ├── delete-routine.js
│   ├── get-active-routine.js
│   ├── get-next-workout.js
│   ├── get-routine.js
│   ├── get-user-routines.js
│   ├── patch-routine.js
│   ├── set-active-routine.js
│   └── update-routine.js
├── scripts/                    # Dev scripts
│   └── weekly_publisher.js
├── mcp/                        # MCP API key management
│   ├── generate-api-key.js     # Generate API key for MCP Server
│   ├── list-api-keys.js        # List user's MCP API keys
│   └── revoke-api-key.js       # Revoke an MCP API key
├── sessions/                   # (REMOVED — sessions eliminated)
│   ├── cleanup-sessions.js     # (REMOVED)
│   ├── initialize-session.js   # (REMOVED)
│   └── pre-warm-session.js     # (REMOVED)
├── shared/                     # Shared utilities
│   ├── artifacts.js            # Artifact action dispatch (accept, dismiss, save)
│   ├── errors.js               # Typed error classes (ValidationError, NotFoundError, etc.) with mapErrorToResponse
│   ├── exercises.js            # Exercise search/resolve operations
│   ├── planning-context.js     # 360° planning context assembly
│   ├── progressions.js         # Progression application with audit trail
│   ├── routines.js             # Routine CRUD operations
│   ├── templates.js            # Template CRUD operations
│   ├── training-queries.js     # Set queries, aggregation, analysis summaries
│   ├── workouts.js             # Workout CRUD operations
│   └── active_workout/
│       └── reorder_sets_core.js
├── strengthos/                 # Agent streaming
│   ├── progress-reports.js
│   └── stream-agent-normalized.js  # SSE proxy with artifact detection + premium gate
├── subscriptions/              # Subscription management
│   ├── ARCHITECTURE.md         # Tier 2 module docs
│   ├── apple-verifier.js       # Shared Apple JWS verification (SignedDataVerifier)
│   ├── app-store-webhook.js    # App Store Server Notifications V2 handler
│   └── sync-subscription-status.js  # iOS → server positive entitlement sync (JWS-verified)
├── templates/                  # Template operations
│   ├── create-template-from-plan.js
│   ├── create-template.js
│   ├── delete-template.js
│   ├── get-template.js
│   ├── get-user-templates.js
│   ├── patch-template.js
│   └── update-template.js
├── tests/                      # Test files
│   └── (test files)
├── triggers/                   # Firestore triggers + Cloud Tasks handlers
│   ├── muscle-volume-calculations.js
│   ├── process-recommendations.js  # Analysis → recommendation pipeline
│   ├── weekly-analytics.js         # Workout deletion handler + scheduled recalculation
│   ├── workout-completion-task.js  # Cloud Tasks handler for workout completion
│   ├── workout-completion-watchdog.js  # Daily safety net for missed completions
│   └── workout-routine-cursor.js   # (DEPRECATED — replaced by process-workout-completion.js)
├── user/                       # User operations
│   ├── delete-account.js       # Server-side account deletion (Admin SDK, App Store 5.1.1(v))
│   ├── get-preferences.js
│   ├── get-user.js
│   ├── update-preferences.js
│   ├── update-user.js
│   └── upsert-attributes.js
├── utils/                      # Shared utilities
│   ├── enqueue-workout-task.js # Cloud Tasks workout completion enqueue
│   ├── plan-to-template-converter.js
│   ├── response.js             # ok() / fail() response helpers
│   ├── subscription-gate.js    # isPremiumUser() shared premium check
│   ├── validation-response.js
│   └── validators.js
├── training/                   # Training analysis endpoints + workout completion pipeline
│   ├── active-events.js
│   ├── context-pack.js
│   ├── get-analysis-summary.js
│   ├── process-workout-completion.js  # Unified workout completion pipeline (Cloud Tasks)
│   ├── progress-summary.js
│   ├── query-sets.js
│   ├── series-endpoints.js
│   └── set-facts-generator.js
└── workouts/                   # Workout operations
    ├── delete-workout.js
    ├── get-user-workouts.js
    ├── get-workout.js
    └── upsert-workout.js
```
