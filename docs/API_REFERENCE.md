# API Reference

> HTTPS endpoints and SSE streaming API for the Povver platform.
> For auth lanes and middleware, see `docs/SECURITY.md`.
> For Firestore data model, see `docs/FIRESTORE_SCHEMA.md`.

---

## Table of Contents

1. [API Reference - HTTPS Endpoints](#api-reference---https-endpoints)
2. [Streaming API - SSE Events](#streaming-api---sse-events)

---

## API Reference - HTTPS Endpoints

All endpoints are Firebase HTTPS Functions. Auth is via Bearer token (Firebase Auth ID token) unless noted as "API Key".

### Canvas Endpoints

#### `POST applyAction`

Single-writer reducer for all canvas mutations. All state changes to a canvas flow through this endpoint.

**Auth**: Bearer token (requireFlexibleAuth)

**Request**:
```javascript
{
  canvasId: string,              // Required
  expected_version?: number,     // Optimistic concurrency check
  action: {
    type: 'ADD_INSTRUCTION' | 'ACCEPT_PROPOSAL' | 'REJECT_PROPOSAL' |
          'ACCEPT_ALL' | 'REJECT_ALL' | 'ADD_NOTE' | 'LOG_SET' |
          'SWAP' | 'ADJUST_LOAD' | 'REORDER_SETS' | 'PAUSE' |
          'RESUME' | 'COMPLETE' | 'UNDO' | 'PIN_DRAFT' |
          'DISMISS_DRAFT' | 'SAVE_ROUTINE',
    idempotency_key: string,     // Required - prevents duplicate actions
    card_id?: string,            // For proposal/draft actions
    payload?: {                  // Type-specific payload
      text?: string,             // ADD_INSTRUCTION, ADD_NOTE
      group_id?: string,         // ACCEPT_ALL, REJECT_ALL
      actual?: { reps, rir, weight? },  // LOG_SET
      exercise_id?: string,      // LOG_SET, SWAP, REORDER_SETS
      set_index?: number,        // LOG_SET
      replacement_exercise_id?: string,  // SWAP
      workout_id?: string,       // SWAP, ADJUST_LOAD, REORDER_SETS
      delta_kg?: number,         // ADJUST_LOAD
      order?: number[],          // REORDER_SETS
      set_active?: boolean,      // SAVE_ROUTINE (default true)
    }
  }
}
```

**Response (Success)**:
```javascript
{
  success: true,
  state: { phase: string, version: number, ... },
  changed_cards: [{ card_id: string, status: string }],
  up_next_delta: [{ op: 'add' | 'remove', card_id: string }],
  version: number
}
```

**Response (SAVE_ROUTINE)**:
```javascript
{
  success: true,
  routine_id: string,
  template_ids: string[],
  is_update: boolean,
  summary_card_id: string
}
```

**Error Codes**:
| Code | HTTP | Description |
|------|------|-------------|
| `STALE_VERSION` | 409 | Version mismatch - refetch and retry |
| `PHASE_GUARD` | 409 | Action not allowed in current phase |
| `SCIENCE_VIOLATION` | 400 | Invalid reps/rir values |
| `UNDO_NOT_POSSIBLE` | 409 | No reversible action to undo |
| `NOT_FOUND` | 404 | Card not found |

---

#### `POST proposeCards`

Agent card proposals (service-only). Creates cards with `status='proposed'` and updates up_next queue.

**Auth**: API Key (withApiKey)

**Request**:
```javascript
{
  userId: string,
  canvasId: string,
  cards: [{
    type: 'session_plan' | 'routine_summary' | 'visualization' |
          'analysis_summary' | 'clarify_questions' | 'list' | ...,
    lane: 'workout' | 'analysis' | 'system',
    content: { ... },           // Type-specific, Ajv-validated
    refs?: { topic_key?: string, ... },
    meta?: { groupId?, draftId?, revision? },
    priority?: number,          // Higher = shown first (default 0)
    ttl?: number,               // Time-to-live in minutes (default 60)
    actions?: [{ key, label, ... }],
    menuItems?: [{ key, label, ... }]
  }]
}
```

**Response (Success)**:
```javascript
{
  success: true,
  card_ids: string[],
  up_next_added: number
}
```

**Response (Validation Failure)**:
```javascript
{
  success: false,
  error: "Schema validation failed",
  details: {
    attempted: { /* original payload */ },
    errors: [{ path, message, keyword, params }],
    hint: "Missing required property 'target' at /cards/0/content/...",
    expected_schema: { /* JSON Schema */ }
  }
}
```

---

#### `POST bootstrapCanvas`

Find or create canvas for (userId, purpose). Returns existing canvas if found.

**Auth**: Bearer token

**Request**:
```javascript
{
  purpose?: string  // Canvas purpose identifier (default 'chat')
}
```

**Response**:
```javascript
{
  success: true,
  canvasId: string,
  created: boolean
}
```

---

#### `POST openCanvas`

Optimized bootstrap + session initialization in one call. Preferred over separate bootstrap + initializeSession.

**Auth**: Bearer token

**Request**:
```javascript
{
  purpose?: string
}
```

**Response**:
```javascript
{
  success: true,
  canvasId: string,
  sessionId: string,
  created: boolean,
  sessionReused: boolean
}
```

---

### Active Workout Endpoints

#### `POST startActiveWorkout`

Initialize workout from template. Creates active_workout document. Auto-cancels stale workouts older than 6 hours.

**Auth**: Bearer token

**Request**:
```javascript
{
  template_id?: string,         // Optional - workout from template
  source_routine_id?: string,   // Optional - links to routine for cursor updates
  plan?: {                      // Optional - direct plan
    blocks: [{
      exercise_id: string,
      sets: [{ reps, rir, weight? }]
    }]
  }
}
```

**Response**:
```javascript
{
  success: true,
  workout_id: string,
  exercises: [{ exercise_id, name, sets: [...] }],
  totals: { sets: 0, reps: 0, volume: 0 }
}
```

**Stale workout handling**: When an existing `in_progress` workout is found, if its `start_time` is older than 6 hours it is auto-cancelled (`status: 'cancelled'`, `end_time` set) and a new workout is created. Non-stale workouts are resumed unless `force_new: true`.

---

#### `POST logSet`

Record completed set during active workout.

**Auth**: Bearer token

**Request**:
```javascript
{
  workout_id: string,
  exercise_id: string,
  set_index: number,
  actual: {
    reps: number,    // >= 0
    rir: number,     // 0-5
    weight?: number  // kg
  }
}
```

**Response**:
```javascript
{
  success: true,
  set_index: number,
  totals: { sets, reps, volume, stimulus_score }
}
```

---

#### `POST completeActiveWorkout`

Archive workout and update analytics. Copies to `workouts` collection and marks active_workout as completed.

**Auth**: Bearer token

**Request**:
```javascript
{
  workout_id: string,
  notes?: string
}
```

**Response**:
```javascript
{
  success: true,
  archived_workout_id: string,
  analytics: { ... }
}
```

---

### Routine Endpoints

#### `GET getNextWorkout` (v2 onCall)

Deterministic next-template selection from active routine using cursor.

**Auth**: Firebase callable (authenticated)

**Request**:
```javascript
{
  // No parameters - uses activeRoutineId from user doc
}
```

**Response**:
```javascript
{
  success: true,
  template: { id, name, exercises: [...] },
  routine: { id, name, template_ids },
  index: number,           // Position in template_ids array
  selection_method: 'cursor' | 'history_scan' | 'first_template'
}
```

---

#### `POST getPlanningContext`

Composite read for agent planning. Returns user profile, routine, templates, and recent workouts in one call.

**Auth**: Bearer token

**Request**:
```javascript
{
  includeTemplates?: boolean,        // Include all routine templates (default true)
  includeTemplateExercises?: boolean, // Include full exercise data (default false)
  includeRecentWorkouts?: boolean,   // Include workout history (default false)
  workoutLimit?: number              // Recent workouts limit (default 5)
}
```

**Response**:
```javascript
{
  success: true,
  user: { uid, name, timezone, fitness_goal, ... },
  activeRoutine: { id, name, template_ids, ... } | null,
  nextWorkout: { template, index, selection_method } | null,
  templates: [{ id, name, exercises: [...] }] | null,
  recentWorkouts: [{ id, name, end_time, exercises }] | null
}
```

---

### Analytics Endpoints

#### `POST getAnalyticsFeatures`

Compact analytics features for LLM/agent consumption. Sublinear data access via pre-computed rollups and series.

**Auth**: Bearer token or API Key

**Request**:
```javascript
{
  userId: string,
  mode: 'weekly' | 'week' | 'range' | 'daily',  // default 'weekly'
  // Mode-specific params:
  weeks?: number,            // weekly mode: 1-52
  weekId?: 'yyyy-mm-dd',     // week mode: specific week start
  start?: 'yyyy-mm-dd',      // range mode: inclusive
  end?: 'yyyy-mm-dd',        // range mode: inclusive
  days?: number,             // daily mode: 1-120
  // Optional filters (max 50 each):
  muscles?: string[],
  exerciseIds?: string[]
}
```

**Response**:
```javascript
{
  success: true,
  mode: string,
  period_weeks?: number,
  weekIds?: string[],
  range?: { start, end },
  daily_window_days?: number,
  rollups: [{
    id: 'yyyy-ww',
    total_sets: number,
    total_reps: number,
    total_weight: number,
    weight_per_muscle_group: { [group]: number },
    hard_sets_per_muscle: { [muscle]: number },
    updated_at: timestamp
  }],
  series_muscle: {
    [muscle]: [{ week: 'yyyy-mm-dd', sets: number, volume: number }]
  },
  series_exercise: {
    [exerciseId]: {
      days: string[],      // 'yyyy-mm-dd' array
      e1rm: number[],      // Estimated 1RM values
      vol: number[],       // Volume values
      e1rm_slope: number,  // Trend coefficient
      vol_slope: number
    }
  },
  schema_version: number
}
```

### Recommendation Endpoints

#### `POST reviewRecommendation`

Accept or reject a pending agent recommendation. Behavior depends on scope:
- **Template-scoped**: Apply changes to target template after a freshness check, state -> `applied`.
- **Exercise-scoped**: Acknowledge only (no template mutation), state -> `acknowledged`.

**Auth**: Bearer token (v2 onRequest with requireFlexibleAuth)

**Premium gate**: `isPremiumUser(userId)` -- returns 403 `PREMIUM_REQUIRED` if not premium.

**Request**:
```javascript
{
  recommendationId: string,    // Required -- agent_recommendations doc ID
  action: "accept" | "reject"  // Required
}
```

**Response (accept, template-scoped)**:
```javascript
{
  success: true,
  data: {
    status: "applied",
    result: {
      template_id: string,
      changes_applied: number
    }
  }
}
```

**Response (accept, exercise-scoped)**:
```javascript
{
  success: true,
  data: { status: "acknowledged" }
}
```

**Response (reject)**:
```javascript
{
  success: true,
  data: { status: "rejected" }
}
```

**Error codes**: `PREMIUM_REQUIRED` (403), `NOT_FOUND` (404), `INVALID_STATE` (409), `STALE_RECOMMENDATION` (409), `INTERNAL_ERROR` (500).

**Freshness check (template-scoped accept only)**: Before applying, verifies each change's `from` value matches the current template value via `resolvePathValue()`. Returns 409 `STALE_RECOMMENDATION` with mismatch details if the template was edited after the recommendation was created. Not applicable to exercise-scoped recommendations.

**Implementation**: `firebase_functions/functions/recommendations/review-recommendation.js`

---

## Streaming API - SSE Events

### `POST streamAgentNormalized`

Server-Sent Events (SSE) stream for agent responses. Transforms ADK events to iOS-friendly format.

**Auth**: Bearer token

**Request**:
```javascript
{
  message: string,           // User message
  canvasId: string,          // Required - links to canvas
  sessionId?: string,        // Optional - reuse existing session
  correlationId?: string,    // Optional - for telemetry
  markdown_policy?: {
    bullets: '-',
    max_bullets: 6,
    no_headers: true
  }
}
```

**Response**: SSE stream with NDJSON events

### Stream Event Types

| Event Type | Description | Content Fields |
|------------|-------------|----------------|
| `status` | Connection/system status | `text`, `session_id?` |
| `thinking` | Agent is reasoning | `text` |
| `thought` | Thinking complete | `text` |
| `toolRunning` | Tool execution started | `tool`, `tool_name`, `args`, `text` |
| `toolComplete` | Tool execution finished | `tool`, `tool_name`, `result`, `text`, `phase?` |
| `message` | Incremental text (delta) | `text`, `role`, `is_delta: true` |
| `agentResponse` | Final text commit | `text`, `role`, `is_commit: true` |
| `error` | Error occurred | `error`, `text` |
| `done` | Stream complete | `{}` |
| `heartbeat` | Keep-alive (every 2.5s) | -- |

### Tool Display Text (`_display` metadata)

Tools return `_display` metadata that the streaming handler uses for human-readable status:

```python
# In tool return value:
{
  "exercises": [...],
  "_display": {
    "running": "Searching chest exercises",
    "complete": "Found 12 exercises",
    "phase": "searching"
  }
}
```

The stream handler extracts:
- `_display.complete` -> `toolComplete.content.text`
- `_display.phase` -> `toolComplete.content.phase`

### Progress Phases

| Phase | Description | Typical Tools |
|-------|-------------|---------------|
| `understanding` | Analyzing user request | Initial routing |
| `searching` | Looking up data | `search_exercises`, `get_recent_workouts` |
| `building` | Constructing artifacts | `propose_workout`, `propose_routine` |
| `finalizing` | Completing output | `save_template`, `create_routine` |
| `analyzing` | Processing analytics | `get_analytics_features` |

### Tool Labels (Fallback)

When `_display` is not provided, the handler uses hardcoded labels:

| Tool Name | Running Label |
|-----------|---------------|
| `tool_search_exercises` | "Searching exercises" |
| `tool_get_planning_context` | "Loading planning context" |
| `tool_propose_workout` | "Creating workout plan" |
| `tool_propose_routine` | "Creating routine" |
| `tool_get_analytics_features` | "Analyzing training data" |
| `tool_save_workout_as_template` | "Saving template" |
| `tool_create_routine` | "Creating routine" |
