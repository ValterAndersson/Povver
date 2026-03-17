# Povver Platform: Agent-Driven Canvas System

> **DEPRECATED**: This document is superseded by `SYSTEM_ARCHITECTURE.md`, `IOS_ARCHITECTURE.md`, and `SHELL_AGENT_ARCHITECTURE.md`. Kept for historical reference only — do not use as a source of truth for current architecture.
>
> **Original Purpose**: Single source of truth for the Povver platform architecture. Written for LLM/agentic coding agents with maximum context and verbosity. Describes implemented functionality, not aspirational features.
>
> **Related Documentation**:
> - `IOS_ARCHITECTURE.md` — Complete iOS application architecture and component catalog
> - `FIREBASE_FUNCTIONS_ARCHITECTURE.md` — Firebase Functions backend layer documentation
> - `FIRESTORE_SCHEMA.md` — Detailed Firestore data model and field specifications
> - `SHELL_AGENT_ARCHITECTURE.md` — Shell Agent architecture (4-lane routing, skills, context)
> - `THINKING_STREAM_ARCHITECTURE.md` — Tool display text architecture for agent thinking streams

---

## Executive Summary

Povver is an agent-driven training canvas platform. The canvas is a live, ranked stream of cards where AI agents propose and users confirm. A single backend reducer applies all state changes after schema, science, and safety validation. The iOS app consumes the canvas via real-time Firestore subscriptions and performs only one type of mutating request: `applyAction`. Agent reasoning is strictly off the hot path (no LLM calls inside the reducer), guaranteeing deterministic outcomes, low latency, and full auditability.

---

## System Components

### 1. iOS App (`Povver/Povver/`)

Native SwiftUI iOS application providing the user interface.

**Key Entry Points**:
- `PovverApp.swift` — App initialization
- `Views/CanvasScreen.swift` — Main canvas interface
- `Views/MainTabsView.swift` — Tab navigation (Canvas, Routines, Templates)
- `ViewModels/CanvasViewModel.swift` — Canvas state management and action dispatch

**Canvas UI Components** (`UI/Canvas/Cards/`):
- `SessionPlanCard.swift` — Workout plan display with exercises/sets grid
- `RoutineSummaryCard.swift` — Multi-day routine draft anchor card
- `RoutineOverviewCard.swift` — Routine summary display
- `VisualizationCard.swift` — Charts and data visualizations
- `AnalysisSummaryCard.swift` — Analysis results display
- `AgentStreamCard.swift` — Streaming agent thinking steps
- `ClarifyQuestionsCard.swift` — Structured agent questions
- `ListCardWithExpandableOptions.swift` — Generic expandable list
- `ProposalGroupHeader.swift` — Accept all/Reject all group actions
- `SetGridView.swift` — Exercise set editing grid

**Services**:
- `CanvasService.swift` — Canvas API client
- `CanvasRepository.swift` — Firestore canvas subscriptions
- `DirectStreamingService.swift` — SSE agent streaming
- `AgentProgressState.swift` — Agent progress tracking (understanding → searching → building → finalizing)

**Design System**:
- `UI/DesignSystem/Tokens.swift` — Centralized design tokens (spacing, typography, colors, elevation)
- 12-track grid layout via `CanvasGridView.swift`

### 2. Firebase Functions (`firebase_functions/functions/`)

Node.js backend providing HTTPS endpoints, Firestore triggers, and scheduled jobs.

**Canvas Endpoints**:
| Endpoint | Purpose | Auth |
|----------|---------|------|
| `applyAction` | Single-writer reducer for all canvas mutations | Bearer token |
| `proposeCards` | Agent card proposals (service-only) | API key |
| `bootstrapCanvas` | Create or return canvas for (userId, purpose) | Bearer token |
| `openCanvas` | Optimized bootstrap + session initialization | Bearer token |
| `expireProposals` | TTL sweep for stale proposed cards | API key |
| `purgeCanvas` | Clear workspace entries | Bearer token |
| `initializeSession` | Initialize Vertex AI agent session | Bearer token |

**Active Workout Endpoints**:
| Endpoint | Purpose |
|----------|---------|
| `startActiveWorkout` | Initialize workout from template |
| `getActiveWorkout` | Fetch current active workout |
| `logSet` | Record completed set |
| `swapExercise` | Replace exercise mid-session |
| `completeActiveWorkout` | Archive workout and update analytics |
| `cancelActiveWorkout` | Cancel without archiving |

**Routine/Template Endpoints**:
| Endpoint | Purpose |
|----------|---------|
| `getNextWorkout` | Deterministic next template from active routine |
| `createTemplateFromPlan` | Convert session_plan card to template |
| `patchTemplate` | Update template exercises |
| `patchRoutine` | Update routine template_ids |
| `getPlanningContext` | Composite read: user + routine + templates + next workout |

**Analytics Endpoints**:
| Endpoint | Purpose |
|----------|---------|
| `getAnalyticsFeatures` | Compact features for LLM consumption |
| `runAnalyticsForUser` | Backfill analytics series/rollups |
| `compactAnalyticsForUser` | Compact old daily points to weekly |
| `publishWeeklyJob` | Propose weekly summary cards to canvas |
| `recalculateWeeklyForUser` | Recalculate weekly_stats |

**Exercise Catalog Endpoints**:
| Endpoint | Purpose |
|----------|---------|
| `searchExercises` | Cached exercise search |
| `upsertExercise` | Create/update exercise |
| `mergeExercises` | Merge duplicate exercises |
| `normalizeCatalog` | Backfill slugs and aliases |

**Firestore Triggers**:
- `onWorkoutCompleted` — Update weekly_stats and analytics series
- `onWorkoutCreatedUpdateRoutineCursor` — Update routine cursor on workout completion
- `onTemplateCreated/Updated` — Compute template analytics
- `onWorkoutCreated` — Compute workout analytics

**Scheduled Jobs**:
- `weeklyStatsRecalculation` — Daily recalculation (2 AM UTC)
- `expireProposalsScheduled` — Every 15 minutes TTL sweep
- `analyticsCompactionScheduled` — Compact old analytics points

### 3. Agent System (`adk_agent/canvas_orchestrator/`)

Python-based multi-agent system using Google ADK (Agent Development Kit) deployed to Vertex AI.

**Agent Architecture** (see `SHELL_AGENT_ARCHITECTURE.md` for current architecture):

```
                    Orchestrator
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
      Coach          Planner         Copilot
   (education +    (workout/routine  (live workout
   data-informed    artifact         execution)
   advice)          creation)
```

**Orchestrator** (`agents/orchestrator.py`):
- Classifies user intent using regex rules first (~80% coverage)
- Falls back to LLM classifier for ambiguous cases
- Routes to appropriate specialist agent
- Tracks session mode transitions

**Coach Agent** (`agents/coach_agent.py`):
- Education, explanations, data-informed advice
- Has analytics tools, NO artifact writes
- Tools: `tool_get_training_context`, `tool_get_analytics_features`, `tool_get_user_profile`, `tool_get_recent_workouts`, `tool_search_exercises`, `tool_get_exercise_details`

**Planner Agent** (`agents/planner_agent.py`):
- Creates and edits workout/routine drafts
- Can write `session_plan` and `routine_summary` cards
- Tools: `tool_get_planning_context`, `tool_search_exercises`, `tool_propose_workout`, `tool_propose_routine`, `tool_save_workout_as_template`, `tool_create_routine`, `tool_manage_routine`

**Copilot Agent** (`agents/copilot_agent.py`):
- Live workout execution support
- ONLY agent that can write to activeWorkout state
- Tools: `tool_get_active_workout`, `tool_start_workout`, `tool_log_set` (planned)

**Shared Voice** (`agents/shared_voice.py`):
- Common system voice for all agents: direct, neutral, high-signal
- No loop statements, no redundant summaries
- Clear adult language, define jargon in one clause

---

## Canvas Architecture

### Core Concepts

| Concept | Description |
|---------|-------------|
| **Canvas** | Firestore-backed workspace at `users/{uid}/canvases/{canvasId}` |
| **Card** | Typed, immutable content unit stored under a canvas |
| **Up-Next** | Prioritized queue (max 20) of cards to surface next |
| **Action** | Single way to mutate state via `applyAction` |
| **Reducer** | Pure business logic in atomic Firestore transaction |
| **Lane** | UI convention: `workout`, `analysis`, `system` |

### Dataflow

```
User (iOS)
  │
  │  applyAction {type, payload, idempotency_key}
  ▼
HTTPS Function: applyAction
  ├── SchemaCheck → ScienceCheck → SafetyCheck
  └── Firestore Transaction (Reducer):
        - optimistic concurrency on state.version
        - update state/cards/up_next atomically
        - append minimal event
  ▼
Firestore (users/{uid}/canvases/{canvasId}/...)
  ▲              ▲
  │              └─ iOS subscribes to state/cards/up_next and re-renders
  │
Agents (off-path)
  │  proposeCards {cards[]}
  ▼
HTTPS Function: proposeCards (API key only)
  - write proposed cards with Ajv validation
  - update up_next priorities
  - no state mutation
```

### Action Types

| Action | Description |
|--------|-------------|
| `ADD_INSTRUCTION` | Add user instruction card, emit event |
| `ACCEPT_PROPOSAL` | Accept a proposed card |
| `REJECT_PROPOSAL` | Reject a proposed card |
| `ACCEPT_ALL` / `REJECT_ALL` | Group actions by `meta.groupId` |
| `ADD_NOTE` | Add a note (supports UNDO) |
| `LOG_SET` | Log completed set with actual values |
| `SWAP` | Replace exercise |
| `ADJUST_LOAD` | Modify weight |
| `REORDER_SETS` | Reorder set sequence |
| `PAUSE` / `RESUME` / `COMPLETE` | Phase transitions |
| `UNDO` | Reverse last reversible action |

### Card Types (Ajv-validated schemas)

Located at `firebase_functions/functions/canvas/schemas/card_types/`:

| Card Type | Description |
|-----------|-------------|
| `session_plan` | Workout plan with blocks/exercises/sets |
| `routine_summary` | Multi-day routine draft anchor |
| `routine_overview` | Routine summary display |
| `visualization` | Charts (line, bar, table, heatmap) |
| `analysis_summary` | Analysis results with metrics |
| `agent_stream` | Streaming agent thinking steps |
| `clarify_questions` | Structured questions from agent |
| `list` | Generic list with expandable items |
| `inline_info` | Inline informational content |
| `proposal_group` | Group header for related cards |
| `set_target` | Individual set prescription |
| `coach_proposal` | Coach suggestion with action/delta/reason |

### Shared Card Fields

All cards support these optional fields (server fills defaults if omitted):
- `layout` — Display configuration
- `actions` — Available user actions
- `menuItems` — Overflow menu items
- `meta` — Metadata including `groupId`, `draftId`, `revision`
- `refs` — References including `topic_key` for replacement
- `priority` — Up-next ordering (higher first)
- `ttl` — Time-to-live in minutes

### Canvas Phases

| Phase | Description |
|-------|-------------|
| `planning` | Building/reviewing a workout plan |
| `active` | Workout in progress |
| `analysis` | Post-workout analysis |

---

## Routine System

### Cursor-Based Next Workout Selection

The routine system uses a cursor-based approach for O(1) next workout selection:

**Cursor Fields** (in `routines/{routineId}`):
- `last_completed_template_id` — ID of most recently completed template
- `last_completed_at` — Timestamp of completion

**Selection Algorithm**:
1. If cursor exists: Find index of last completed template, return next (wrapping)
2. If no cursor: Scan last 30 days of workouts for last matching template
3. If no history: Return first template in list

**Cursor Updates**:
- Trigger `onWorkoutCreatedUpdateRoutineCursor` updates cursor when workout with `source_routine_id` is archived
- Cursor cleared if `last_completed_template_id` is removed from `template_ids`

### Routine Draft Cards

When agent proposes a routine:
1. `routine_summary` card is the anchor (goes into `up_next`)
2. `session_plan` cards for each day linked via `meta.groupId`
3. Server generates `meta.draftId`, `meta.groupId`, `meta.revision`
4. `content.workouts[].card_id` populated with actual Firestore doc IDs

### Routine Actions

| Action | Description |
|--------|-------------|
| `PIN_DRAFT` | Flip all cards in group to `status='active'` |
| `SAVE_ROUTINE` | Create routine + templates from draft |
| `DISMISS_DRAFT` | Mark all cards as `rejected` |

---

## Analytics System

### Data Model

**Per-Exercise Series** (`users/{uid}/analytics_series_exercise/{exercise_id}`):
```javascript
{
  points_by_day: { "YYYY-MM-DD": { e1rm?: number, vol?: number } },
  weeks_by_start: { "YYYY-MM-DD": { e1rm_max: number, vol_sum: number } },
  schema_version: number,
  compacted_at?: timestamp
}
```

**Per-Muscle Series** (`users/{uid}/analytics_series_muscle/{muscle}`):
```javascript
{
  weeks: { "YYYY-MM-DD": { sets, volume, hard_sets?, low_rir_sets?, load? } }
}
```

**Rollups** (`users/{uid}/analytics_rollups/{yyyy-ww}`):
```javascript
{
  total_sets, total_reps, total_weight,
  weight_per_muscle_group: { [group]: number },
  hard_sets_per_muscle: { [muscle]: number },
  load_per_muscle: { [muscle]: number }
}
```

### Analytics Features API

`POST getAnalyticsFeatures` — Compact features for LLM/agent consumption:

**Request**:
```javascript
{
  userId: string,
  mode: 'weekly' | 'week' | 'range' | 'daily',
  weeks?: number,        // For 'weekly' mode (1-52)
  weekId?: 'yyyy-mm-dd', // For 'week' mode
  start?: 'yyyy-mm-dd',  // For 'range' mode
  end?: 'yyyy-mm-dd',
  days?: number,         // For 'daily' mode (1-120)
  muscles?: string[],    // Filter (≤50)
  exerciseIds?: string[] // Filter (≤50)
}
```

**Response**:
```javascript
{
  mode, period_weeks?, weekIds?, range?, daily_window_days?,
  rollups: [{ id: weekId, total_sets, total_reps, total_weight, ... }],
  series_muscle: { [muscle]: [{ week, sets, volume }] },
  series_exercise: { [exerciseId]: { days, e1rm, vol, e1rm_slope, vol_slope } }
}
```

### Compaction

- Points older than 90 days are compacted from `points_by_day` into `weeks_by_start`
- Scheduled job `analyticsCompactionScheduled` runs this periodically
- Keeps storage sublinear while preserving trend data

---

## Firestore Data Model

See `FIRESTORE_SCHEMA.md` for complete field-level documentation.

### Collection Structure

```
users/{uid}
  ├── user_attributes/{uid}     // User preferences and fitness profile
  ├── workouts/{workoutId}      // Archived completed workouts
  ├── weekly_stats/{weekId}     // Weekly aggregates (legacy, still updated)
  ├── templates/{templateId}    // Workout templates
  ├── routines/{routineId}      // Routine definitions
  ├── active_workouts/{id}      // In-progress workouts
  │   └── events/{eventId}      // Workout events
  ├── canvases/{canvasId}       // Canvas workspaces
  │   ├── cards/{cardId}        // Canvas cards
  │   ├── up_next/{entryId}     // Priority queue
  │   ├── events/{eventId}      // Reducer events
  │   └── idempotency/{key}     // Deduplication
  ├── analytics_series_exercise/{exercise_id}
  ├── analytics_series_muscle/{muscle}
  ├── analytics_rollups/{yyyy-ww}
  └── analytics_state/current   // Watermarks

exercises/{exerciseId}          // Global exercise catalog
exercise_aliases/{alias_slug}   // Alias → exercise mapping
```

### Security Rules

- `users/{uid}/canvases/**` — Read-only for clients; writes via Functions only
- Other user subcollections — Owner read/write
- Canvas mutations must flow through `applyAction`

---

## Validation Gates

### SchemaCheck (Ajv)

- Card schemas compiled on cold start and cached
- Validates `content` by card `type`
- Returns `INVALID_ARGUMENT` with field-level details

### ScienceCheck

- Rep ranges: 1-30
- RIR: 0-5
- Weekly set bounds per muscle group

### SafetyCheck

- Contraindications based on user flags
- Equipment availability
- ROM/tempo sanity

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Action → UI round trip | ≤400ms P95 |
| Reducer function time | ≤200ms P50 |
| First agent response | <10s |
| Session reuse rate | >80% |
| Up-next cap | 20 entries |

---

## Caching Strategy

### Exercise Catalog

- **Memory cache**: 5-minute TTL per Firebase Function instance
- **Firestore cache**: 3-day TTL in `cache/exercises/{hash}`
- Returns `source: 'memory' | 'firestore' | 'fresh'`

### User Profile

- **Memory cache**: 5-minute TTL
- **Firestore cache**: 24-hour TTL
- Invalidated on user update via `invalidateProfileCache()`

### GCP Auth Token

- **Memory cache**: 55-minute TTL
- Auto-refreshes 5 minutes before expiry

---

## Agent Tool Display Text

See `THINKING_STREAM_ARCHITECTURE.md` for full details.

Tools emit `_display` metadata in return values:
```python
{
  "items": [...],
  "_display": {
    "running": "Searching chest exercises",
    "complete": "Found 12 exercises",
    "phase": "searching"
  }
}
```

Firebase extracts `_display` and emits to iOS for rendering.

**Phases**: `understanding`, `searching`, `building`, `finalizing`, `analyzing`

---

## Directory Structure

```
Povver/
├── Povver/Povver/                  # iOS app
│       ├── Views/                  # Top-level views
│       ├── ViewModels/             # State management
│       ├── Services/               # API clients
│       ├── Repositories/           # Firestore subscriptions
│       ├── Models/                 # Data models
│       └── UI/
│           ├── Canvas/             # Canvas components
│           │   ├── Cards/          # Card views
│           │   └── Charts/         # Visualization views
│           ├── Routines/           # Routine management
│           ├── Templates/          # Template management
│           ├── Components/         # Shared components
│           └── DesignSystem/       # Design tokens
│
├── firebase_functions/
│   └── functions/
│       ├── canvas/                 # Canvas endpoints
│       │   └── schemas/            # Ajv schemas
│       ├── active_workout/         # Workout endpoints
│       ├── routines/               # Routine endpoints
│       ├── templates/              # Template endpoints
│       ├── analytics/              # Analytics endpoints
│       ├── exercises/              # Exercise catalog
│       ├── triggers/               # Firestore triggers
│       ├── agents/                 # Agent-facing endpoints
│       └── shared/                 # Shared modules
│
├── adk_agent/
│   ├── canvas_orchestrator/        # Main canvas agent
│   │   └── app/
│   │       ├── agents/             # Specialist agents
│   │       │   ├── orchestrator.py
│   │       │   ├── coach_agent.py
│   │       │   ├── planner_agent.py
│   │       │   ├── copilot_agent.py
│   │       │   ├── shared_voice.py
│   │       │   └── tools/          # Agent tools
│   │       └── libs/               # Shared libraries
│   │
│   └── catalog_admin/              # Exercise catalog admin agent
│
└── docs/                           # Documentation
```

---

## Environment Variables

### Firebase Functions

| Variable | Description |
|----------|-------------|
| `VALID_API_KEYS` | Comma-separated valid API keys |
| `PROJECT_ID` | GCP project ID |

### Agent System

| Variable | Default | Description |
|----------|---------|-------------|
| `USE_MULTI_AGENT` | `true` | Enable orchestrator routing |
| `CANVAS_ORCHESTRATOR_MODEL` | `gemini-2.5-flash` | Orchestrator model |
| `CANVAS_COACH_MODEL` | `gemini-2.5-flash` | Coach agent model |
| `CANVAS_PLANNER_MODEL` | `gemini-2.5-flash` | Planner agent model |
| `CANVAS_COPILOT_MODEL` | `gemini-2.5-flash` | Copilot agent model |

---

## Error Handling

### Error Response Format

```javascript
{
  success: false,
  error: {
    code: "INVALID_ARGUMENT" | "STALE_VERSION" | "SCIENCE_VIOLATION" | ...,
    message: "Human-readable message",
    details: [...]
  }
}
```

### Self-Healing Validation (for agents)

When `proposeCards` validation fails:
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

## iOS App Consumption Patterns

### Canvas Bootstrap

```swift
// CanvasViewModel.start(userId, purpose)
let canvasId = try await service.bootstrapCanvas(userId, purpose)
repository.subscribe(userId: userId, canvasId: canvasId)
```

### Action Dispatch

```swift
// All mutations via applyAction
try await canvasService.applyAction(
    canvasId: canvasId,
    action: .init(
        type: .acceptProposal,
        cardId: card.id,
        by: .user
    ),
    expectedVersion: currentVersion,
    idempotencyKey: UUID().uuidString
)
```

### Conflict Handling

- Include `expected_version` in every `applyAction`
- On `STALE_VERSION`: refetch state, retry once
- Generate fresh `idempotency_key` per user interaction

---

## Key Invariants

1. **Single Writer**: All canvas state changes flow through `applyAction` → reducer
2. **Deterministic Reducer**: No LLM calls inside the Firestore transaction
3. **Agents Off-Path**: Agents call `proposeCards`, never mutate state directly
4. **Up-Next Cap**: Maximum 20 entries, priority-ordered
5. **Single Active Set Target**: Only one active `set_target` per `(exercise_id, set_index)`
6. **Phase Guards**: Workout mutations only allowed in `phase === "active"`
7. **Idempotency**: Per-canvas keys prevent duplicate actions
8. **Version Concurrency**: Optimistic locking via `state.version`

---

## Appendix: ASCII Sequence Diagrams

### Ad-hoc Instruction to Insights

```
User(iOS) → applyAction(ADD_INSTRUCTION) → Validator+Reducer → Event(instruction_added)
Agent(worker) ← subscribes/reads event → compute → proposeCards(visualizations, summary)
iOS ← Firestore subscriptions update → render cards in priority order
expireProposals(schedule) → marks scaffolding expired → UI hides them
```

### Active Workout Flow

```
iOS → applyAction(ACCEPT_PROPOSAL: session_plan)
Reducer → state.phase=active; populate workout rail; event(session_started)
iOS → applyAction(LOG_SET: actual)
Reducer → update set_result; pointers; event(set_logged)
iOS → applyAction(COMPLETE)
Reducer → state.phase=analysis; event(workout_completed)
Agent → proposeCards(charts, tables, session_summary)
```

### Routine-Driven Planning

```
User → "next workout" or "today's workout"
Agent → tool_get_next_workout (uses cursor)
Agent → converts template to session_plan
Agent → tool_propose_workout
iOS → receives session_plan card
User → accepts → startActiveWorkout (with source_routine_id)
User → completes workout
Trigger → updates routine cursor → next workout advances
```
