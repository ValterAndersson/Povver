# POVVER System Architecture

> Cross-cutting data flows, schema contracts, common patterns, and checklists.
> For security invariants and auth lanes, see `docs/SECURITY.md`.
> For analytics and monitoring, see `docs/ANALYTICS.md`.

---

## File Path Reference

Each module doc maintains its own file map:
- **iOS**: `docs/IOS_ARCHITECTURE.md` → "Directory Structure" section
- **Firebase Functions**: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` → "Directory Structure" section
- **Agent Service**: `docs/SHELL_AGENT_ARCHITECTURE.md` → "File Structure" section (covers both legacy canvas_orchestrator and current agent_service)
- **Catalog Orchestrator**: `docs/CATALOG_ORCHESTRATOR_ARCHITECTURE.md` → "File Index" section

**Cross-cutting paths** (not owned by a single module):

| Component | Path | Purpose |
|-----------|------|---------|
| Shared Agent Utilities | `adk_agent/shared/` | Cross-agent usage tracking + pricing |
| LLM Usage Query | `scripts/query_llm_usage.js` | Weekly cost aggregation |
| Privacy Manifest | `Povver/Povver/PrivacyInfo.xcprivacy` | App Store privacy declarations |

---

## Quick Reference: Layer Map

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                             POVVER ARCHITECTURE                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ iOS App (Povver/Povver/)                                                 │   │
│  │  Views → ViewModels → Services/Repositories → Firebase SDK             │   │
│  └───────────────────────────────────┬─────────────────────────────────────┘   │
│                                      │                                          │
│                    HTTP/SSE          │  Firestore Listeners                     │
│                                      │                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ Firebase Functions (firebase_functions/)                                │   │
│  │  HTTP endpoints → Business logic → Firestore reads/writes              │   │
│  └───────────────────────────────────┬─────────────────────────────────────┘   │
│                                      │                                          │
│                    HTTP              │  Service Account                         │
│                                      │                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ Agent Service (adk_agent/agent_service/) — Cloud Run                    │   │
│  │  4-Lane Router → Skills → Firestore (stateless, per-request context)   │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ MCP Server (mcp_server/) — Cloud Run, Node.js/TypeScript               │   │
│  │  Premium-gated dual auth (API key + OAuth 2.1 for Claude Desktop)      │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ Firestore (source of truth)                                             │   │
│  │  users/{uid}/conversations, routines, templates, workouts, active_wks  │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Critical Data Flows

### 1. Conversation Flow with Inline Artifacts (User → Agent → SSE)

```
User types message in iOS
        │
        ▼
iOS: DirectStreamingService.streamQuery()
        │ POST /streamAgentNormalized (conversationId)
        ▼
Firebase: stream-agent-normalized.js
        │ Writes message to conversations/{id}/messages
        │ Opens SSE to Agent Service (Cloud Run)
        │ (At stream end: fire-and-forget title generation via Gemini Flash
        │  → writes `title` to canvases/{id} + conversations/{id})
        ▼
Agent: shell/router.py classifies intent
        │ Routes to Fast/Functional/Slow lane
        ▼
Agent: planner_skills.propose_routine()
        │ Returns artifact data in SkillResult
        ▼
Agent: shell/agent.py emits SSE artifact event
        │ {type: "artifact", data: {...}, artifactId: "..."}
        ▼
iOS: DirectStreamingService receives artifact event
        │ Converts to CanvasCardModel (reuses renderers)
        ▼
iOS: ConversationViewModel appends artifact
        │
        ▼
iOS: UI renders artifact inline with messages
```

**Files involved** (CURRENT PATHS):
- `Povver/Povver/Services/DirectStreamingService.swift` ← iOS streaming
- `firebase_functions/functions/strengthos/stream-agent-normalized.js`
- `adk_agent/agent_service/app/router.py` ← Routes intent
- `adk_agent/agent_service/app/skills/planner_skills.py` ← Returns artifacts
- `Povver/Povver/ViewModels/ConversationViewModel.swift`
- `Povver/Povver/Views/ConversationView.swift`

---

### 2. Accept Artifact Flow

```
User taps "Accept" on routine_summary artifact
        │
        ▼
iOS: artifactAction(action: "accept", artifactId, conversationId)
        │ POST /artifactAction
        ▼
Firebase: artifact-action.js
        │ Routes based on artifact type
        ▼
Firebase: create-routine-from-draft.js
        │ Creates templates + routine
        ▼
Firestore: templates/{id} created (one per day)
Firestore: routines/{id} created
Firestore: users/{uid}.activeRoutineId set
Firestore: conversations/{id}/artifacts/{artifactId} updated (status='accepted')
        │
        ▼ (listeners fire)
iOS: ConversationRepository listener sees artifact update
iOS: RoutineRepository listener receives new routine
```

**Files involved** (CURRENT PATHS):
- `Povver/Povver/Services/ConversationService.swift` → `artifactAction()`
- `firebase_functions/functions/conversations/artifact-action.js`
- `firebase_functions/functions/routines/create-routine-from-draft.js`
- `firebase_functions/functions/utils/plan-to-template-converter.js`

---

### 3. Start Workout Flow

```
User taps "Start Workout" (from routine or template)
        │
        ▼
iOS: ActiveWorkoutManager.startWorkout(templateId, routineId?)
        │ POST /startActiveWorkout
        ▼
Firebase: start-active-workout.js
        │ Fetches template, creates active_workout
        ▼
Firestore: active_workouts/{id} created
  {
    source_template_id: "...",
    source_routine_id: "...",  ← Required for cursor advancement!
    exercises: [...],
    status: "in_progress"      // in_progress | completed | cancelled
  }
        │
        ▼
iOS: Returns workout_id, iOS navigates to workout view
```

**Files involved** (CURRENT PATHS):
- `Povver/Povver/Services/FocusModeWorkoutService.swift` ← startWorkout()
- `firebase_functions/functions/active_workout/start-active-workout.js`

---

### 4. Complete Workout Flow (with Routine Cursor)

```
User taps "Finish Workout"
        │
        ▼
iOS: FocusModeWorkoutService drains pending syncs
        │ Awaits all in-flight logSet/patchField calls
        ▼
iOS: FocusModeWorkoutService.finishWorkout()
        │ POST /completeActiveWorkout
        ▼
Firebase: complete-active-workout.js
        │ Archives workout with analytics
        │ Generates template_diff (exercise adds/removes/swaps/weight changes)
        ▼
Firestore: workouts/{newId} created
  {
    source_routine_id: "...",
    source_template_id: "...",
    end_time: ...,
    analytics: {...},
    template_diff: {...}  // Deviations from source template
  }
        │
        ▼ (Cloud Tasks enqueue via enqueue-workout-task.js)
Cloud Tasks: workout-completion queue
        │ At-least-once delivery with retries
        ▼
Firebase: training/process-workout-completion.js
        │ Unified pipeline: weekly stats, analytics series,
        │ routine cursor, training analysis enqueue
        │ Idempotent via completion_watermark field
        ▼
Firestore: routines/{id} updated (cursor)
  {
    last_completed_template_id: "...",
    last_completed_at: ...
  }
Firestore: workouts/{id} updated (watermark)
  {
    completion_watermark: Timestamp
  }
        │
        ▼
Next get-next-workout.js call uses cursor for O(1) lookup

Watchdog: workout-completion-watchdog.js (daily scheduled)
        │ Scans 48h for workouts missing completion_watermark
        │ Re-enqueues to Cloud Tasks for reprocessing
```

**Files involved** (CURRENT PATHS):
- `Povver/Povver/Services/FocusModeWorkoutService.swift` ← finishWorkout()
- `firebase_functions/functions/active_workout/complete-active-workout.js`
- `firebase_functions/functions/utils/enqueue-workout-task.js` ← Cloud Tasks enqueue
- `firebase_functions/functions/triggers/workout-completion-task.js` ← Cloud Tasks handler
- `firebase_functions/functions/training/process-workout-completion.js` ← unified pipeline
- `firebase_functions/functions/triggers/workout-completion-watchdog.js` ← safety net
- `firebase_functions/functions/routines/get-next-workout.js`

---

### 5. Workout Coaching Flow (Active Workout + Agent)

```
User taps Coach button during active workout
        │
        ▼
iOS: WorkoutCoachView presents compact chat sheet
        │ User sends message (e.g., "log 8 at 100")
        ▼
iOS: WorkoutCoachViewModel.send()
        │ Calls DirectStreamingService.streamQuery(workoutId: workout.id)
        ▼
Firebase: stream-agent-normalized.js
        │ Builds context prefix: (context: conversation_id=X user_id=Y corr=Z workout_id=W today=YYYY-MM-DD)
        │ Opens SSE to Agent Service (Cloud Run)
        ▼
Agent: main.py (agent_service) via SSE proxy
        │ 1. Parses workout_id from context → ctx.workout_mode = true
        │ 2. Routes message (Fast/Functional/Slow)
        │ 3. If Slow Lane: front-loads Workout Brief (~1350 tokens)
        │    - Parallel fetch: getActiveWorkout + getAnalysisSummary
        │    - Sequential: getExerciseSummary (current exercise)
        │    - Formats as [WORKOUT BRIEF] text prepended to message
        │ 4. LLM sees: brief + user message + workout instruction overlay
        │ 5. LLM calls workout tools as needed (tool_log_set, etc.)
        ▼
Agent tools (via workout_skills.py):
        │ tool_log_set → client.log_set → Firebase logSet
        │ tool_add_exercise → client.add_exercise → Firebase addExercise
        │ tool_prescribe_set → client.patch_active_workout → Firebase patchActiveWorkout
        │ tool_swap_exercise → search + client.swap_exercise → Firebase swapExercise
        │ tool_complete_workout → client.complete_active_workout → Firebase completeActiveWorkout
        ▼
Firebase: Active workout endpoints mutate Firestore
        │
        ▼ (Firestore listener fires)
iOS: FocusModeWorkoutService receives updated workout state
```

**Files involved** (CURRENT PATHS):
- `Povver/Povver/UI/FocusMode/WorkoutCoachView.swift` ← Compact chat sheet
- `Povver/Povver/ViewModels/WorkoutCoachViewModel.swift` ← Ephemeral chat VM
- `Povver/Povver/Services/DirectStreamingService.swift` ← streamQuery(workoutId:)
- `firebase_functions/functions/strengthos/stream-agent-normalized.js` ← workout_id in context
- `adk_agent/agent_service/app/main.py` ← Entry point, Workout Brief injection
- `adk_agent/agent_service/app/context.py` ← SessionContext (workout_mode, today)
- `adk_agent/agent_service/app/skills/workout_skills.py` ← Brief builder + mutations
- `adk_agent/agent_service/app/tools/` ← Workout tool wrappers
- `adk_agent/agent_service/app/instruction.py` ← ACTIVE WORKOUT MODE section

**Design decisions**:
- Same Cloud Run deployment, mode-based switching (no second agent)
- Workout Brief front-loaded once per request (not per LLM turn)
- Fast Lane still works in workout mode (bypasses brief fetch for <500ms)
- Chat is ephemeral (in-memory, not persisted to Firestore)
- Instruction overlay enforces 2-sentence max responses for gym context

---

## Conversation & Artifact Architecture

### Design Principles

The conversation system is a lightweight replacement for the previous canvas architecture. Key differences:

| Aspect | Old Canvas | New Conversations |
|--------|-----------|-------------------|
| **State Management** | Transactional reducer with version checking | Simple message append + optional artifact storage |
| **Artifact Delivery** | Firestore subcollection → listener | SSE events → in-memory |
| **Persistence** | 5 subcollections (cards, workspace, actions, drafts, events) | 2 subcollections (messages, artifacts - optional) |
| **Complexity** | apply-action reducer, undo stack, phase state machine | Direct writes, no state machine |
| **Session Init** | openCanvas → bootstrapCanvas → propose initial cards | No init needed — conversation created on first message |

### Conversation Schema

```json
// Firestore: users/{uid}/conversations/{conversationId}
{
  "id": "conv_abc",
  "created_at": Timestamp,
  "updated_at": Timestamp,
  "title": "Push/Pull/Legs Routine",  // Optional, set after first message
  "context": {
    "workout_id": "...",              // If in workout mode
    "routine_id": "..."               // If discussing specific routine
  }
}
```

### Message Schema

```json
// Firestore: users/{uid}/conversations/{id}/messages/{msgId}
{
  "id": "msg_abc",
  "role": "user",                     // user | assistant | system
  "content": "Create a PPL routine",
  "created_at": Timestamp,
  "metadata": {
    "model": "gemini-2.5-flash",     // For assistant messages
    "lane": "slow"                   // fast | functional | slow
  }
}
```

### Artifact Lifecycle

1. **Creation**: Agent tool returns artifact data in SkillResult
2. **Pre-ID**: `stream-agent-normalized.js` pre-generates a Firestore artifact doc ID via `artifactsRef.doc()` before SSE emission
3. **Delivery**: SSE event `{type: "artifact", artifact_id: "pre-generated-id", data: {...}}`
4. **Display**: iOS extracts `artifact_id`, converts to `CanvasCardModel` with artifact provenance in `CardMeta` (`artifactId`, `conversationId`). The `artifact_id` becomes stable card identity.
5. **Persistence**: `stream-agent-normalized.js` writes artifact to Firestore with the pre-generated ID via `set()`
6. **Action**: User taps Accept/Save/Dismiss → iOS routes through `AgentsApi.artifactAction()` using `CardMeta.artifactId` + `conversationId`. Falls back to legacy `applyAction` when `artifactId` is absent.

### SSE Event Types (9-Event Contract)

| Event Type | Data | Purpose |
|------------|------|---------|
| `thinking` | `{}` | Agent processing indicator |
| `thought` | `{content}` | Agent reasoning content |
| `tool_start` | `{tool}` | Tool execution begins |
| `tool_end` | `{tool, result}` | Tool execution completes |
| `message_start` | `{messageId}` | Begin new assistant message |
| `text` | `{delta}` | Streaming text chunk |
| `artifact` | `{type, content, meta, artifactId}` | Inline artifact (routine, workout, etc.) |
| `message_end` | `{}` | Complete assistant message |
| `error` | `{code, message}` | Error during streaming |

### Session Management (REMOVED — Phase 7)

Sessions have been eliminated. Conversations are created on first message — no session initialization, pre-warming, or exchange-token flow needed. The agent service is fully stateless with per-request context via ContextVar.

**Removed components**:
- `firebase_functions/functions/sessions/initialize-session.js` (REMOVED)
- `firebase_functions/functions/sessions/pre-warm-session.js` (REMOVED)
- `firebase_functions/functions/sessions/cleanup-sessions.js` (REMOVED)
- `firebase_functions/functions/auth/exchange-token.js` (REMOVED)
- `Povver/Povver/Services/SessionPreWarmer.swift` (REMOVED)

**Current flow**: iOS sends first message via `streamAgentNormalized` → conversation doc created lazily if needed → agent responds.

### Migration Notes

The `stream-agent-normalized.js` endpoint accepts both `conversationId` and `canvasId` (backward compatibility during migration). New clients should pass `conversationId`.

Agent context prefix changed from `canvas_id=X` to `conversation_id=X`.

---

## Schema Contracts (Cross-Boundary Data Shapes)

### Artifact (Agent → SSE → iOS, Firestore storage optional)

```json
// SSE Event: {type: "artifact", data: {...}, artifactId: "..."}
// Firestore (optional): users/{uid}/conversations/{convId}/artifacts/{artifactId}
{
  "id": "artifact_abc123",
  "type": "session_plan",              // Artifact type (routine_summary, workout_plan, etc.)
  "status": "proposed",                // proposed | accepted | dismissed
  "created_at": Timestamp,
  "updated_at": Timestamp,
  "meta": {
    "draftId": "draft_123",            // For routine_summary only
    "sourceTemplateId": "...",         // If editing existing template
    "sourceRoutineId": "..."           // If editing existing routine
  },
  "content": { ... }                   // Type-specific payload
}
```

**iOS mapping**: Artifacts received via SSE are converted to `CanvasCardModel` for rendering (reuses existing card renderers)

---

### Routine (Firestore → iOS)

```json
// Firestore: users/{uid}/routines/{routineId}
{
  "id": "routine_abc",
  "name": "Push/Pull/Legs",
  "description": "3-day split",
  "template_ids": ["t1", "t2", "t3"],  // Ordered list
  "frequency": 3,
  "created_at": Timestamp,
  "updated_at": Timestamp,
  
  // Cursor fields (updated by trigger)
  "last_completed_template_id": "t2",
  "last_completed_at": Timestamp
}
```

**iOS model**: (legacy - routines handled via CanvasActions now)

---

### Template (Firestore → iOS)

```json
// Firestore: users/{uid}/templates/{templateId}
{
  "id": "template_abc",
  "name": "Push Day",
  "user_id": "uid",
  "exercises": [
    {
      "exercise_id": "ex_bench",
      "name": "Bench Press",           // Denormalized for display
      "sets": [
        { "reps": 8, "rir": 2, "weight": 80 }
      ]
    }
  ],
  "analytics": {
    "estimated_duration_minutes": 45,
    "total_sets": 15,
    "muscles": ["chest", "triceps", "shoulders"]
  },
  "created_at": Timestamp,
  "updated_at": Timestamp
}
```

**iOS model**: `Povver/Povver/Models/WorkoutTemplate.swift`

---

### Active Workout (Firestore → iOS)

```json
// Firestore: users/{uid}/active_workouts/{workoutId}
{
  "id": "active_abc",
  "user_id": "uid",
  "source_template_id": "template_xyz",
  "source_routine_id": "routine_abc",   // Required for cursor advancement
  "status": "in_progress",              // in_progress | completed | cancelled
  "start_time": Timestamp,
  "exercises": [
    {
      "exercise_id": "ex_bench",
      "name": "Bench Press",
      "sets": [
        { 
          "set_index": 0,
          "target_reps": 8,
          "target_rir": 2,
          "weight": 80,                // Actual (null if not logged)
          "reps": 8,                   // Actual (null if not logged)
          "completed_at": Timestamp    // null if not logged
        }
      ]
    }
  ],
  "totals": {
    "sets": 5,
    "reps": 40,
    "volume": 3200
  },
  "created_at": Timestamp,
  "updated_at": Timestamp
}
```

**iOS model**: `Povver/Povver/Models/FocusModeModels.swift` (FocusModeWorkout)

---

## Common Patterns

### Authentication Lanes

See `docs/SECURITY.md` → "Authentication Model" for the authoritative reference on auth lanes (Bearer, Service, Callable), middleware types, and IDOR prevention.

### iOS Authentication Architecture

The iOS app supports three Firebase Auth providers: Email/Password, Google Sign-In, Apple Sign-In.

**Key files**: `AuthService.swift` (service), `AuthProvider.swift` (enum), `AppleSignInCoordinator.swift` (Apple delegate wrapper), `RootView.swift` (reactive navigation)

**SSO flow pattern** (shared by Google and Apple):
1. Provider SDK authenticates → Firebase Auth credential
2. `Auth.auth().signIn(with: credential)` → Firebase creates/links auth account
3. `user.reload()` to refresh stale `providerData` (critical for auto-linking)
4. Check if Firestore `users/{uid}` exists → return `.existingUser` or `.newUser`
5. `.newUser` → confirmation dialog → `createUserDocument()` if confirmed, `signOut()` if cancelled

**Provider data staleness**: After sign-in or linking, `currentUser.providerData` may not reflect auto-linked providers. Always call `user.reload()` + reassign `self.currentUser = Auth.auth().currentUser` after auth state changes.

**Account deletion sequence**: Reauth → Apple token revocation (if applicable) → Firestore subcollection deletion → Firebase Auth deletion → session cleanup → RootView reactively navigates to login.

**Firestore fields for auth**:
- `users/{uid}.provider` — provider used at account creation (`"email"`, `"google.com"`, `"apple.com"`)
- `users/{uid}.apple_authorization_code` — required for Apple token revocation on account deletion

See `docs/IOS_ARCHITECTURE.md` [Authentication System] section for exhaustive details.

### Error Response Format

```javascript
// Success
return ok(res, { data: {...} });

// Error
return fail(res, 'NOT_FOUND', 'Resource not found', { details }, 404);

// Response shape:
{
  "success": true,
  "data": {...}
}
// or
{
  "success": false,
  "error": {
    "code": "NOT_FOUND",
    "message": "Resource not found",
    "details": {...}
  }
}
```

### Idempotency

```javascript
// Artifact actions use idempotency_key to prevent duplicate writes
{
  "action": "accept",
  "artifact_id": "...",
  "conversation_id": "...",
  "idempotency_key": "uuid-v4"  // Client-generated
}

// Server checks: if (await Idempotency.check(key)) return cached response
```

---

## Data Access Patterns

The shared business logic modules (`firebase_functions/functions/shared/`) provide a projection layer for different consumption tiers:

**Orientation tier** — Agent/MCP context assembly (summary views):
- `listWorkouts(db, userId, { view: "summary" })` → exercise names + set counts (~200-500 bytes/workout)
- `listTemplates(db, userId, { view: "summary" })` → name + exercise_names array (~300 bytes/template)
- `getPlanningContext(db, userId, { view: "compact" })` → user basics + routine summary + 10 workouts (~2KB total)

**Inspection tier** — iOS app, detailed views (full documents):
- Default behavior when `view` parameter is omitted
- Includes all fields: per-set data, analytics, full metadata

**Pipeline tier** — Background jobs (unbounded queries):
- Training analyst, backfill scripts, Firestore triggers
- Query collections directly, bypass projections

**Denormalization** — Write-time resolution to avoid read fan-out:
- Exercise names on template exercises (resolved from catalog at write time)
- Template names on routine documents (`template_names` map, propagated on rename)
- Staleness acceptable (exercise names immutable, template renames propagate actively)

See `firebase_functions/functions/shared/ARCHITECTURE.md` for implementation details and consumer mapping.

---

## Adding a New Field (Cross-Stack Checklist)

When adding a new field (e.g., `routine.goal`):

1. **Firestore Schema** (`docs/FIRESTORE_SCHEMA.md`)
   - Add field to collection documentation

2. **Firebase Function - Write**
   - `create-routine-from-draft.js` - Add to routineData
   - `patch-routine.js` - Add to allowed update fields

3. **Firebase Function - Read**
   - `get-routine.js` - Already returns full doc
   - `get-planning-context.js` - Check if included

4. **iOS Model**
   - `Povver/Povver/Models/*.swift` - Add property
   - Ensure `Codable` picks it up

5. **iOS Repository**
   - Usually automatic via Firestore SDK

6. **iOS UI**
   - Add to relevant views (RoutineDetailView, etc.)

7. **Agent Skills** (if agent needs to write it)
   - Update return data in `app/skills/planner_skills.py`
   - Agent prompt instructions in `app/shell/instruction.py`

---

## Weight Unit Handling

All weight values are stored in **kilograms (kg)** across every layer (Firestore, Firebase Functions, Agent system). The user's display preference is a presentation concern handled at two boundaries:

### Storage
- Canonical format: `weight_kg` (Number, always kilograms)
- User preference: `user_attributes/{uid}.weight_format` — `"kilograms"` or `"pounds"`
- Active workouts use field name `weight`, completed workouts use `weight_kg` — both store kg values

### Conversion Boundaries

| Boundary | Direction | Where | How |
|----------|-----------|-------|-----|
| **Display (outbound)** | kg → user unit | iOS Views, Agent text output | `WeightFormatter.display(kg, unit:)` / `format_weight(kg, unit)` |
| **Input (inbound)** | user unit → kg | iOS text fields, steppers, sliders | `WeightFormatter.toKg(value, from:)` |

### Key Files

| Layer | File | Purpose |
|-------|------|---------|
| iOS | `Povver/Povver/Utilities/WeightFormatter.swift` | `WeightUnit`, `HeightUnit` enums, `WeightFormatter`, `HeightFormatter` — conversion functions, plate rounding |
| iOS | `Povver/Povver/Services/ActiveWorkoutManager.swift` | `UserService` singleton — publishes `weightUnit`, `heightUnit`, `activeWorkoutWeightUnit`. Retries preference load via auth state listener. |
| iOS | `Povver/Povver/Views/Settings/PreferencesView.swift` | Weight + height unit picker UI (guarded against rapid toggling via `isInitializing`) |
| iOS | `Povver/Povver/Views/Settings/ProfileEditView.swift` | Text-field-based height/weight editors — height respects `heightUnit` (cm or ft+in), weight respects `weightUnit` |
| iOS | `Povver/Povver/UI/Components/Domain/SetCellModel.swift` | Set display mappers — `toSetCellModels(weightUnit:)` converts stored kg to display unit |
| iOS | `Povver/Povver/UI/Components/Domain/SetTable.swift` | Read-only set table — header shows `UserService.shared.weightUnit.label` |
| Firebase | `firebase_functions/functions/user/update-preferences.js` | Writes `weight_format`/`height_format` to `user_attributes/{uid}` (v2 onRequest with `requireFlexibleAuth`) |
| Firebase | `firebase_functions/functions/agents/get-planning-context.js` | Derives `weight_unit` field (`"kg"` or `"lbs"`) from `weight_format` for agent consumption |
| Agent | `adk_agent/agent_service/app/skills/workout_skills.py` | Weight unit cache (`set_weight_unit`/`get_weight_unit`) with timestamp-based eviction |
| Agent | `adk_agent/agent_service/app/instruction.py` | Unit-aware progression rules, defaults, and rounding — agent reasons in user's unit system, converts to kg only for tool parameters |

### Preference Loading on App Launch
`UserService.init()` calls `loadUserPreferences()`, but Firebase Auth may not have initialized yet (`currentUser` is nil). To handle this:
1. An auth state listener (`AuthService.shared.$currentUser`) retries `loadUserPreferences()` when auth becomes available.
2. `weightUnit.didSet` keeps `activeWorkoutWeightUnit` in sync — if preferences load after the workout starts, the display updates immediately.
3. `startWorkout()` and `resumeWorkout()` both `await ensurePreferencesLoaded()` before snapshotting, guaranteeing the Firestore read completes first.

### Agent Unit-Aware Reasoning
The agent does not merely convert kg to lbs for display. It **thinks in the user's unit system**: progression increments (+5lbs vs +2.5kg), default weights, and rounding are all unit-specific. This prevents plate-misaligned values (e.g., prescribing 226lbs instead of 225lbs). The agent converts to kg only when passing `weight_kg` tool parameters (e.g., 225lbs ÷ 2.205 = 102.04kg). The iOS app converts back to 225lbs for display — no rounding drift.

### Conversion Constants
- kg → lbs: `× 2.20462`
- lbs → kg: `÷ 2.20462`
- Plate rounding: kg = 2.5 increments, lbs = 5.0 increments
- Height: 1 inch = 2.54 cm

---

## Deprecated / Legacy Code

### Files to Avoid

| File | Reason | Replacement |
|------|--------|-------------|
| `Povver/Povver/Archived/CloudFunctionProxy.swift` | Old HTTP wrapper | `ConversationService.swift` |
| `Povver/Povver/Archived/StrengthOSClient.swift` | Old API client | `CloudFunctionService.swift` |
| `Povver/Povver/Repositories/CanvasRepository.swift` | Canvas system removed | `ConversationRepository.swift` |
| `canvas/apply-action.js` | Canvas reducer removed | `conversations/artifact-action.js` |
| `canvas/propose-cards.js` | Canvas cards removed | Artifacts via SSE |
| `canvas/bootstrap-canvas.js` | Canvas bootstrap removed | Conversation created on first message |
| `canvas/open-canvas.js` | Canvas open removed | Direct conversation creation |
| `canvas/emit-event.js` | Canvas events removed | SSE from agent |
| `canvas/purge-canvas.js` | Canvas purge removed | N/A |
| `canvas/expire-proposals.js` | Canvas expiry removed | N/A |
| `canvas/reducer-utils.js` | Canvas reducer removed | N/A |
| `canvas/validators.js` | Canvas validators removed | N/A |
| `routines/create-routine.js` | Manual routine creation | `create-routine-from-draft.js` |
| `routines/update-routine.js` | Direct update | `patch-routine.js` |
| `templates/update-template.js` | Direct update | `patch-template.js` |
| `adk_agent/canvas_orchestrator/` | Vertex AI Agent Engine deployment | `adk_agent/agent_service/` (Cloud Run) |
| `sessions/initialize-session.js` | Session init removed | Conversations created on first message |
| `sessions/pre-warm-session.js` | Session pre-warming removed | No session management needed |
| `sessions/cleanup-sessions.js` | Session cleanup removed | No sessions to clean |
| `auth/exchange-token.js` | Token exchange removed | No sessions |
| `Povver/Povver/Services/SessionPreWarmer.swift` | Session pre-warming removed | No session management needed |
| `triggers/workout-routine-cursor.js` | Firestore trigger for cursor | `training/process-workout-completion.js` (Cloud Tasks) |

### Legacy Field Names

| Legacy | Current | Notes |
|--------|---------|-------|
| `templateIds` | `template_ids` | get-next-workout handles both |
| `weight` | `weight_kg` | Normalized on archive |
| `canvasId` | `conversationId` | stream-agent-normalized supports both during migration |

### Removed Collections

| Collection | Status | Replacement |
|------------|--------|-------------|
| `users/{uid}/canvases/{id}/cards` | Removed | `conversations/{id}/artifacts` (optional Firestore storage) |
| `users/{uid}/canvases/{id}/workspace_entries` | Removed | `conversations/{id}/messages` |
| `users/{uid}/canvases/{id}` | Removed | `conversations/{id}` (lightweight metadata) |

---

## Training Analyst: Background Analysis Architecture

The Training Analyst is an **asynchronous background service** that pre-computes training insights and weekly reviews. It runs as Cloud Run Jobs processing from a Firestore-backed job queue. This allows the chat agent to retrieve analysis instantly instead of computing it during conversations.

### Architecture Flow

```
Workout Completed
        │
        ▼ (Cloud Tasks: workout-completion queue)
Firebase: process-workout-completion.js
        │ Writes job to training_analysis_jobs collection
        ▼
Firestore: training_analysis_jobs/{jobId}
        │ status: "queued"
        ▼ (Cloud Run Job polls every 15 min)
Training Analyst Worker: poll_job() → lease → run
        │ Routes to appropriate analyzer
        ▼
PostWorkoutAnalyzer / WeeklyReviewAnalyzer
        │ Reads aggregated data, calls Gemini LLM
        ▼
Firestore: analysis_insights / weekly_reviews
        │
        ▼ (Chat agent retrieves)
Chat Agent: tool_get_training_analysis()
        │ Instant response (<100ms)
        ▼
User sees pre-computed insights
```

### Key Design Principles

| Principle | Rationale |
|-----------|-----------|
| **Pre-computation** | Analysis happens in background, not during chat |
| **Firestore queue** | Lease-based concurrency, no PubSub dependency |
| **Bounded responses** | All summaries <2KB for fast agent retrieval |
| **Data budget** | Only pre-aggregated data to LLM (never raw workouts) |
| **Retry with backoff** | Max 3 attempts, exponential backoff (5-30 min) |

### Component Map

```
adk_agent/training_analyst/
├── app/
│   ├── config.py                  ← Models, TTLs, collection names
│   ├── firestore_client.py        ← Firestore SDK singleton
│   ├── analyzers/
│   │   ├── base.py                ← Shared LLM client (google.genai + Vertex AI)
│   │   ├── post_workout.py        ← Post-workout insights
│   │   ├── weekly_review.py       ← Weekly progression
│   │   ├── plateau_detector.py    ← Plateau detection analysis
│   │   └── volume_optimizer.py    ← Volume optimization analysis
│   └── jobs/
│       ├── models.py              ← Job, JobPayload, JobStatus, JobType
│       ├── queue.py               ← Create, poll, lease, complete, fail
│       └── watchdog.py            ← Stuck job recovery
├── workers/
│   ├── analyst_worker.py          ← Main worker (+ watchdog entry point)
│   └── scheduler.py               ← Daily/weekly job creation
├── Makefile                       ← Build, deploy, trigger commands
└── ARCHITECTURE.md                ← Tier 2 module docs
```

### Job Types

| Job Type | Trigger | Model | Output Collection | TTL |
|----------|---------|-------|-------------------|-----|
| `POST_WORKOUT` | `onWorkoutCompleted` Firestore trigger | gemini-2.5-pro | `users/{uid}/analysis_insights/{autoId}` | 7 days |
| `WEEKLY_REVIEW` | Scheduler (Sundays) | gemini-2.5-pro | `users/{uid}/weekly_reviews/{YYYY-WNN}` | 30 days |

### Data Budget Strategy

All analyzers read from **pre-aggregated collections only** (never raw workout docs):

| Analyzer | Data Budget | Sources |
|----------|------------|---------|
| Post-Workout | ~18KB | Trimmed workout (~1.5KB) + 8wk rollups (~4KB) + 8wk exercise series (~10KB) + routine summary (~3KB) + exercise catalog (~1KB) + fatigue metrics |
| Weekly Review | ~51KB | 12wk rollups (~6KB) + 15 exercise series (~18KB) + 8 muscle group series (~14KB) + full templates (~5KB) + recent insights (~2KB) + fatigue metrics + exercise catalog (~1KB) |

### Backfill

Historical analysis can be generated via the backfill script:

```bash
# 1. Rebuild analytics foundation (set_facts, series, rollups)
FIREBASE_SERVICE_ACCOUNT_PATH=$FIREBASE_SA_KEY \
  node scripts/backfill_set_facts.js --user <userId> --rebuild-series

# 2. Enqueue analysis jobs (idempotent — safe to re-run)
FIREBASE_SERVICE_ACCOUNT_PATH=$FIREBASE_SA_KEY \
  node scripts/backfill_analysis_jobs.js --user <userId> --months 3

# 3. Process the jobs
GOOGLE_APPLICATION_CREDENTIALS=$GCP_SA_KEY \
  PYTHONPATH=adk_agent/training_analyst \
  python3 adk_agent/training_analyst/workers/analyst_worker.py
```

The backfill script uses deterministic job IDs (`bf-pw-{hash}`, `bf-wr-{hash}`, `bf-db-{hash}`) so re-runs overwrite existing jobs instead of creating duplicates.

**Required Firestore index**: `training_analysis_jobs` composite index on `status` (ASC) + `created_at` (ASC).

### Chat Agent Integration

The chat agent retrieves all pre-computed analysis through a single consolidated tool:

```python
# In app/shell/tools.py
tool_get_training_analysis(sections=None)  # All sections, or filter: ["insights", "weekly_review"]
```

This calls the `getAnalysisSummary` Firebase Function, which reads from Firestore and returns all requested sections in a single HTTP call (~6KB total).

### Firebase Function: getAnalysisSummary

```javascript
// firebase_functions/functions/training/get-analysis-summary.js
// Auth: requireFlexibleAuth (Bearer + API key)
// Params: userId, sections? (array), date? (YYYY-MM-DD), limit? (number)
// Default: returns all sections (insights + weekly_review)
```

---

## Agent Architecture: 4-Lane Agent Service (CURRENT)

> **CRITICAL**: The agent runs on **Cloud Run** as a stateless service (`adk_agent/agent_service/`).
> The old Vertex AI Agent Engine deployment (`adk_agent/canvas_orchestrator/`) is DEPRECATED.
> DO NOT import from the old folder. All new code uses `adk_agent/agent_service/`.

### Architecture Decision Record

| Decision | Rationale |
|----------|-----------|
| Single Shell Agent | Unified persona, no "dead ends" |
| 4-Lane Routing | Fast lane bypasses LLM for <500ms copilot |
| Skills as Modules | Pure functions, not chat agents |
| ContextVars for State | Thread-safe in async serverless |

### Agent Service File Map

```
adk_agent/agent_service/
├── app/
│   ├── main.py                  ← ENTRY POINT (Cloud Run, FastAPI)
│   ├── router.py                ← 4-Lane routing (determines lane)
│   ├── context.py               ← Per-request SessionContext (ContextVar)
│   ├── context_builder.py       ← Builds context from Firestore for agent
│   ├── agent_loop.py            ← Agent execution loop
│   ├── memory.py                ← 4-tier memory system (Tier 3 agent_memory, Tier 4 summaries)
│   ├── instruction.py           ← System prompt
│   ├── planner.py               ← Intent-based planning
│   ├── critic.py                ← Response validation
│   ├── safety_gate.py           ← Write confirmation
│   ├── functional_handler.py    ← JSON/Flash lane
│   ├── firestore_client.py      ← Firestore SDK singleton
│   ├── observability.py         ← Logging and tracing
│   ├── skills/                  ← PURE LOGIC (Shared Brain)
│   │   ├── coach_skills.py      ← Analytics, user data
│   │   ├── planner_skills.py    ← Artifact creation
│   │   ├── copilot_skills.py    ← Set logging, workout
│   │   ├── workout_skills.py    ← Workout Brief + active workout mutations
│   │   └── gated_planner.py     ← Safety-gated writes
│   ├── tools/                   ← Tool wrappers
│   └── llm/                     ← LLM client abstraction
├── tests/                       ← Test suite
├── Dockerfile                   ← Cloud Run container
├── Makefile                     ← Build, deploy, dev commands
└── requirements.txt
```

**Memory System** (4 tiers):
| Tier | Storage | Scope | Purpose |
|------|---------|-------|---------|
| 1 | Session variables | Per-request | Workout mode, today, correlation_id |
| 2 | Conversation history | Per-conversation | Messages in `conversations/{id}/messages` |
| 3 | Agent memory | Per-user, persistent | `users/{uid}/agent_memory/{auto-id}` — facts the agent remembers across conversations |
| 4 | Conversation summaries | Per-conversation | Compressed context from long conversations |

### 4-Lane Routing Decision Table

| Input Pattern | Lane | Model | Latency | Handler |
|---------------|------|-------|---------|---------|
| `"done"`, `"8 @ 100"`, `"next set"` | FAST | None | <500ms | `copilot_skills.*` → `completeCurrentSet` |
| `{"intent": "SWAP_EXERCISE", ...}` | FUNCTIONAL | Flash | <1s | `functional_handler.py` |
| `"create a PPL routine"` | SLOW | Flash | 2-5s | `shell/agent.py` |
| PubSub `workout_completed` | WORKER | Flash | N/A | `post_workout_analyst.py` |

### Tool Permission Matrix (Shell Agent)

| Skill Function | Read | Write | Returns Artifact | Safety Gate |
|----------------|------|-------|------------------|-------------|
| `get_training_context()` | ✅ | - | No | No |
| `get_training_analysis()` | ✅ | - | No | No |
| `get_user_profile()` | ✅ | - | No | No |
| `search_exercises()` | ✅ | - | No | No |
| `get_exercise_details()` | ✅ | - | No | No |
| `get_exercise_progress()` | ✅ | - | No | No |
| `get_muscle_group_progress()` | ✅ | - | No | No |
| `get_muscle_progress()` | ✅ | - | No | No |
| `query_training_sets()` | ✅ | - | No | No |
| `get_planning_context()` | ✅ | - | No | No |
| `propose_workout()` | - | - | **Yes** | **Yes** |
| `propose_routine()` | - | - | **Yes** | **Yes** |
| `update_routine()` | - | - | **Yes** | **Yes** |
| `update_template()` | - | - | **Yes** | **Yes** |
| `log_set()` | - | ✅ | No | No (Fast Lane) |
| `tool_log_set()` | - | ✅ | No | No (workout mode gated) |
| `tool_swap_exercise()` | - | ✅ | No | No (workout mode gated) |
| `tool_complete_workout()` | - | ✅ | No | No (workout mode gated) |
| `tool_get_workout_state()` | ✅ | - | No | No (workout mode gated) |

Note: "Returns Artifact" means the tool returns artifact data in SkillResult, which the agent emits as an SSE artifact event. These tools no longer write directly to Firestore (canvas cards removed).

### Context Flow (SECURITY CRITICAL)

```
main.py (agent_service) handles SSE request
    │
    ├─→ 1. Parse context: ctx = SessionContext from request
    │
    ├─→ 2. Set context: set_current_context(ctx, message)  ← MUST BE FIRST
    │
    ├─→ 3. Route: routing = route_request(message)
    │
    └─→ 4. Execute lane with ctx in ContextVar
```

**Security**: `user_id` comes from authenticated request, NOT from LLM.
Tool functions call `get_current_context()` to retrieve verified user_id.

See `docs/SHELL_AGENT_ARCHITECTURE.md` for exhaustive details.

---

## Key Firestore Indexes

See `firebase_functions/firestore.indexes.json` for composite indexes.

**Critical queries requiring indexes**:
- `workouts` ordered by `end_time desc` (for get-recent-workouts)
- `messages` ordered by `created_at` (for conversation history)
- `artifacts` filtered by `status` (for pending proposals)

---

## Auto-Pilot System

Connects the training analyst pipeline to user-facing recommendations and automated template mutations. The analyst (Python) identifies what needs to change; Firebase Functions translate analysis into specific template changes; the iOS app surfaces recommendations or shows auto-applied changes.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. ANALYSIS (Python — Training Analyst, Cloud Run Jobs)               │
│    Writes: analysis_insights, weekly_reviews (already implemented)     │
└──────────────────┬──────────────────────────────────────────────────────┘
                   │ Firestore trigger (onDocumentCreated)
                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 2. RESOLUTION + APPLICATION (Node.js — Firebase Functions)             │
│    triggers/process-recommendations.js                                 │
│    Reads: user prefs (auto_pilot_enabled), active routine, templates   │
│    Writes: agent_recommendations (+ template if auto-pilot ON)         │
│    Reuses: applyChangesToTarget from agents/apply-progression.js       │
└──────────────────┬──────────────────────────────────────────────────────┘
                   │ Firestore listener (iOS)
                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 3. USER REVIEW (Swift — iOS App)                                       │
│    RecommendationRepository → RecommendationsViewModel → bell + feed   │
│    Calls: reviewRecommendation endpoint (accept/reject)                │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| Analysis triggers | `triggers/process-recommendations.js` | `onAnalysisInsightCreated`, `onWeeklyReviewCreated` — translate analysis into recommendations |
| Review endpoint | `recommendations/review-recommendation.js` | Accept/reject — template-scoped: freshness check + apply; exercise-scoped: acknowledge only |
| Expiry sweep | `triggers/process-recommendations.js` | `expireStaleRecommendations` — daily, 7-day TTL |
| Shared mutations | `agents/apply-progression.js` | `applyChangesToTarget`, `resolvePathValue` — reused by triggers and review endpoint |
| iOS model | `Models/AgentRecommendation.swift` | Codable struct matching `agent_recommendations` schema |
| iOS listener | `Repositories/RecommendationRepository.swift` | Firestore snapshot listener on `agent_recommendations` |
| iOS service | `Services/RecommendationService.swift` | HTTP calls to `reviewRecommendation` via `ApiClient` |
| iOS ViewModel | `ViewModels/RecommendationsViewModel.swift` | Pending/recent state, optimistic UI, premium gate |
| iOS bell | `UI/Components/NotificationBell.swift` | Badge overlay in `MainTabsView` |
| iOS feed | `Views/Recommendations/RecommendationsFeedView.swift` | Sheet with pending + recent cards |
| User preference | `auto_pilot_enabled` on `users/{uid}` | Toggle in Profile → Preferences (premium-only) |

### Recommendation Scopes

| | Template-scoped | Exercise-scoped | Routine-scoped |
|---|---|---|---|
| **Trigger condition** | User has `activeRoutineId` | No `activeRoutineId` | Weekly review muscle_balance |
| **Baseline** | Template set weights | Max working set weight from workout | N/A (informational) |
| **`scope` field** | `"template"` | `"exercise"` | `"routine"` |
| **`target` field** | `{ template_id }` | `{ exercise_name, exercise_id }` | `{ routine_id, muscle_group }` |
| **Auto-apply** | Yes (if `auto_pilot_enabled`) | No (always `pending_review`) | No (always `pending_review`) |
| **Accept action** | Apply changes to template sets | Acknowledge (no mutation) | Acknowledge (no mutation) |
| **Change types** | `weight`, `reps` | `weight`, `reps` | None (empty `changes` array) |

Exercise-scoped recommendations ensure users without routines/templates still receive progression suggestions. Routine-scoped muscle_balance recommendations surface training volume imbalances for the user to consider.

### Progression Rules

**Double Progression Model**: Increase reps to target range first, then increase weight and reset reps. This prevents premature weight jumps when the user hasn't mastered the current load.

**Multi-lever progression types**:
- `progression` — Weight increase: +2.5% for compounds (>40kg), +5% for isolation, rounded to 2.5kg/1.25kg, capped at +5kg/step
- `rep_progression` — Rep increase: compounds +1-2 reps per session (5→6→8), isolation +2-4 reps (8→10→12)
- `intensity_adjust` — RIR tuning: adjust target RIR when consistently too high (≥3) or too low (<1)
- `deload` — Weight reduction: -10%, same rounding rules
- `muscle_balance` — Informational: surfaces overtrained/undertrained muscle groups from weekly review (scope: `routine`, no `changes` array)

**Decision order (per exercise)**:
1. Not at target reps? → `rep_progression` (build reps before adding weight)
2. At target reps with low RIR (≤2)? → `progression` (weight increase)
3. Stalled with room (RIR ≥ 2)? → `rep_progression` (increase reps first)
4. Stalled and grinding (RIR < 2)? → `deload` or `exercise_swap`

Weight computation remains deterministic (no LLM involved). Safety: min 0kg.

### Premium Gates (3 Layers)

1. **Trigger** (`process-recommendations.js`): `isPremiumUser()` prevents template reads and recommendation writes for free users
2. **Review endpoint** (`review-recommendation.js`): `isPremiumUser()` prevents downgraded users from applying stale recommendations
3. **iOS UI** (`RecommendationsViewModel`): Only starts Firestore listener for premium users

---

## Subscription System

Povver uses Apple StoreKit 2 for in-app purchases with server-side state management via App Store Server Notifications V2. The client syncs positive entitlements to Firestore; the webhook is authoritative for downgrades (expiration, refund, revocation).

### Architecture

```
iOS StoreKit 2 (SubscriptionService.swift)
        │ Purchase with appAccountToken (UUID v5 from Firebase UID)
        │ Client-side gate in DirectStreamingService
        ▼
App Store
        │ Completes purchase
        │ Sends V2 Server Notification to webhook
        ▼
Firebase: subscriptions/app-store-webhook.js
        │ Decodes JWS payload (base64; JWS signature verification pending Apple root certs)
        │ Looks up user by subscription_app_account_token (fallback: original_transaction_id)
        │ Updates user subscription fields on users/{uid}
        │ Invalidates profile cache, logs event to subscription_events
        ▼
Firestore: users/{uid}
  {
    subscription_status: "active",
    subscription_tier: "premium",
    subscription_expires_at: ...,
    subscription_override: null        // admin override for test/beta users
  }
        │
        ▼ (Premium feature requests)
Firebase: utils/subscription-gate.js
        │ isPremiumUser(userId): override === 'premium' OR tier === 'premium'
        ▼
Premium features granted or denied
```

### Premium-Gated Features

| Feature | Gate Point | Error Format |
|---------|------------|--------------|
| AI coaching chat (all streaming) | `stream-agent-normalized.js` (server) + `DirectStreamingService` (client) | SSE `{ type: 'error', error: { code: 'PREMIUM_REQUIRED' } }` |
| Post-workout LLM analysis | `triggers/weekly-analytics.js` (job not enqueued) | Silent — free analytics still run |

**Not gated** (free for all users): exercise catalog, manual workout logging, workout history, templates/routines (read-only), weekly_stats, analytics rollups, set_facts.

**Client-side gate**: `DirectStreamingService.streamQuery()` checks `SubscriptionService.shared.isPremium` before opening the SSE connection. If `false`, throws `StreamingError.premiumRequired` which `CanvasViewModel` catches to show the paywall.

**Server-side gate (defense-in-depth)**: `stream-agent-normalized.js` calls `isPremiumUser(userId)` after auth. If `false`, emits an SSE error event with code `PREMIUM_REQUIRED` then closes the stream. `CanvasViewModel` also detects this code in the `.error` event handler.

### Subscription States

| Status | Tier | Description |
|--------|------|-------------|
| `"trial"` | `"premium"` | Introductory offer (7-day free trial) |
| `"active"` | `"premium"` | Paid subscription active |
| `"grace_period"` | `"premium"` | Payment failed, still has access during billing retry |
| `"expired"` | `"free"` | Subscription expired, cancelled, refunded, or revoked |
| `"free"` | `"free"` | Never had subscription or trial ended |

### Override System

The `subscription_override` field allows manual premium access grants for test/beta users:
- Set to `"premium"`: Grants premium access regardless of App Store state
- Set to `null` or absent: Respect App Store subscription state
- Set manually via Firestore console or admin script — never by the app or webhook

**Admin scripts**:
- `scripts/set_subscription_override.js` - Set/remove override for single user

### App Store Server Notifications V2

Webhook at `subscriptions/app-store-webhook.js` (v2 `onRequest`, no auth middleware — Apple calls directly):

| Notification Type | Subtype | subscription_status | subscription_tier |
|-------------------|---------|---------------------|-------------------|
| `SUBSCRIBED` | (offerType=1) | `trial` | `premium` |
| `SUBSCRIBED` | (else) | `active` | `premium` |
| `DID_RENEW` | — | `active` | `premium` |
| `DID_FAIL_TO_RENEW` | `GRACE_PERIOD` | `grace_period` | `premium` |
| `DID_FAIL_TO_RENEW` | (else) | `expired` | `free` |
| `EXPIRED` | any | `expired` | `free` |
| `GRACE_PERIOD_EXPIRED` | — | `expired` | `free` |
| `REFUND` | — | `expired` | `free` |
| `REVOKE` | — | `expired` | `free` |
| `DID_CHANGE_RENEWAL_STATUS` | — | *(unchanged)* | *(unchanged)* |

`DID_CHANGE_RENEWAL_STATUS` only updates `subscription_auto_renew_enabled`. All events logged to `users/{uid}/subscription_events/{auto-id}` for audit trail.

### User Lookup (Webhook)

`appAccountToken` is a deterministic UUID v5 derived from the Firebase UID using the DNS namespace (RFC 4122). Same algorithm on iOS (`SubscriptionService.generateAppAccountToken`) and server. Apple preserves this token across all transactions and webhook notifications.

1. Query `users` where `subscription_app_account_token == token` (lowercased)
2. Fallback: query where `subscription_original_transaction_id == txnId`

### Gate Check Logic

See `utils/subscription-gate.js`:

```javascript
// Premium access = ANY of:
// 1. subscription_override === 'premium' (admin override)
// 2. subscription_tier === 'premium' (set by webhook based on status transitions)
```

The gate checks the denormalized `subscription_tier` field, not `status + expires_at`. The webhook is responsible for setting tier correctly based on status transitions.

### iOS Subscription Components

| File | Purpose |
|------|---------|
| `Models/SubscriptionStatus.swift` | `SubscriptionTier`, `SubscriptionStatusValue`, `UserSubscriptionState` |
| `Services/SubscriptionService.swift` | StoreKit 2 singleton: products, purchase, entitlements, Firestore sync |
| `Views/PaywallView.swift` | Full-screen purchase sheet with trial CTA and restore |
| `Views/Settings/SubscriptionView.swift` | Subscription management in profile settings |

### Authority Model

- **Client writes to Firestore** only when StoreKit reports a **positive entitlement** (trial, active, grace period). This prevents the client from overwriting server-set `subscription_tier: "premium"` with stale `"free"` state (e.g., new device, delayed StoreKit sync).
- **Webhook is authoritative for downgrades** (expiration, cancellation, refund, revocation).
- **Client is authoritative for initial purchase** (syncs tier, token, transaction ID to Firestore so webhook can find the user).

---

