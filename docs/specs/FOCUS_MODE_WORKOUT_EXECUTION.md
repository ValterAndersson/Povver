# Focus Mode Workout Execution Architecture

> **Related Docs**: [FIRESTORE_SCHEMA.md](../FIRESTORE_SCHEMA.md), [FIREBASE_FUNCTIONS_ARCHITECTURE.md](../FIREBASE_FUNCTIONS_ARCHITECTURE.md), [SHELL_AGENT_ARCHITECTURE.md](../SHELL_AGENT_ARCHITECTURE.md)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Mission and Constraints](#2-mission-and-constraints)
3. [Product Behavior Principles](#3-product-behavior-principles)
4. [Data Lifecycle](#4-data-lifecycle)
5. [Firestore Schema](#5-firestore-schema)
6. [Backend Endpoints](#6-backend-endpoints)
7. [Event System](#7-event-system)
8. [iOS Architecture](#8-ios-architecture)
9. [Copilot Integration](#9-copilot-integration)
10. [Validation Rules](#10-validation-rules)
11. [Implementation Phases](#11-implementation-phases)
12. [Acceptance Criteria](#12-acceptance-criteria)
13. [Strength Training Feature Completeness](#13-strength-training-feature-completeness)
14. [Integration with Existing Systems](#14-integration-with-existing-systems)
15. [UI/UX Polish Requirements](#15-uiux-polish-requirements)
16. [Resilience & Crash Recovery](#16-resilience--crash-recovery)
17. [Scalability Considerations](#17-scalability-considerations)

---

## 1. Overview

Focus Mode Workout Execution is the core workout logging experience in StrengthOS. It provides a **spreadsheet-first logger** (Strong/Hevy mental model) with an optional AI Copilot that improves prescription quality and reduces friction—without interrupting the lift.

### 1.1 What This Document Covers

This document specifies:

- **Data Model**: The canonical schema for active workouts, sets, and events
- **Backend Contracts**: All Firebase Functions endpoints, their request/response shapes, and validation rules
- **iOS Architecture**: Local-first state management, commit points, and Firestore reconciliation
- **Copilot Integration**: How the AI assistant interacts with workout state without being intrusive
- **Event System**: Immutable audit trail for all workout mutations

### 1.2 Relationship to Other Systems

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           STRENGTHOS ARCHITECTURE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐                │
│  │   PLANNER    │     │    COACH     │     │   COPILOT    │                │
│  │    Agent     │     │    Agent     │     │    Agent     │                │
│  └──────┬───────┘     └──────────────┘     └──────┬───────┘                │
│         │                                         │                         │
│         │ Creates                                 │ Executes                │
│         ▼                                         ▼                         │
│  ┌──────────────┐                         ┌──────────────┐                 │
│  │  Templates   │──── Initializes ───────▶│   Active     │                 │
│  │  & Routines  │                         │   Workout    │◄─── THIS DOC    │
│  └──────────────┘                         └──────┬───────┘                 │
│                                                  │                          │
│                                                  │ Archives to              │
│                                                  ▼                          │
│                                           ┌──────────────┐                 │
│                                           │  Completed   │                 │
│                                           │   Workouts   │                 │
│                                           └──────┬───────┘                 │
│                                                  │                          │
│                                                  │ Feeds                    │
│                                                  ▼                          │
│                                           ┌──────────────┐                 │
│                                           │  Analytics   │                 │
│                                           │   Pipeline   │                 │
│                                           └──────────────┘                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Local-first state** | Gym connectivity is unreliable; UI must be responsive during lifting |
| **Single-value set model** | No target/actual split—user edits values directly, simpler mental model |
| **Server-canonical events** | Server writes all events to ensure consistent timestamps and diffs |
| **Homogeneous patch requests** | Keeps event model clean; one event per commit |
| **Silent Copilot by default** | AI must not interrupt the lift; user explicitly triggers AI actions |

---

## 2. Mission and Constraints

### 2.1 Mission Statement

> Build focus-mode workout execution with a spreadsheet-first logger plus an optional copilot that improves prescription quality and reduces friction, without interrupting the lift.

**Success Definition**: The user can complete a full workout fast without AI, but can delegate decisions to AI with one tap when desired.

### 2.2 Primary Constraints

These constraints are **non-negotiable** and inform every design decision:

| Constraint | Implication |
|------------|-------------|
| **Latency and "gym flow" > everything** | Local-first state, async sync, no blocking calls during logging |
| **AI must be non-intrusive by default** | No unsolicited chat, no popups, Copilot only responds when asked |
| **AI support must be trustworthy** | Explainable deltas, consistent logic, no silent plan changes |

### 2.3 UX Mental Model

The primary experience is a **spreadsheet/grid**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  BENCH PRESS                                                      [Auto-fill]│
├──────┬────────────┬────────┬────────┬────────┐                              │
│ SET  │   WEIGHT   │  REPS  │  RIR   │   ✓    │                              │
├──────┼────────────┼────────┼────────┼────────┤                              │
│ W1   │    40kg    │   10   │   —    │   ✓    │  ← Warmup (excluded from     │
│ 1    │    80kg    │   10   │   2    │   ✓    │     totals)                  │
│ 2    │    80kg    │   10   │   2    │   ○    │                              │
│ 3    │    80kg    │   10   │   2    │   ○    │                              │
├──────┴────────────┴────────┴────────┴────────┤                              │
│                 [+ Add Set]                   │                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

Users can:
- Tap any cell to edit (weight, reps, RIR)
- Tap done checkbox to mark set complete
- Swipe to delete/duplicate sets
- Add/remove exercises
- Optionally tap AI action buttons for assistance

---

## 3. Product Behavior Principles

### 3.1 P1: Spreadsheet-First Logging is the Primary Experience

The main screen is a table/grid where:

- **Exercises** are sections with collapsible headers
- **Sets** are rows within each exercise section
- **Columns** include: SET#, TYPE, WEIGHT, REPS, RIR, DONE checkbox

Key UX requirements:
- Fast editing via tap-cell → numeric keypad → done
- Quick increment buttons (+2.5kg, ±1 rep)
- Swipe actions for delete/duplicate
- No modals blocking the flow

### 3.2 P2: Copilot is "Available", Not "Present"

**Default behavior**: No messages unless user explicitly asks.

The Copilot may:
- Compute recommendations in the background
- Prepare suggestions for when user requests them

The Copilot must NOT:
- Post unsolicited messages during workout
- Show popups or interruptions
- Auto-modify workout state

**Trigger conditions** (Copilot speaks only when):
1. User opens chat and sends a message
2. User taps an AI action button (Auto-fill, Swap, etc.)
3. User taps "Generate workout" from empty state

### 3.3 P3: Every Significant Interaction is Captured as Structured Event

The system must be able to reconstruct:
- **What changed** (diff ops)
- **Why it changed** (cause: user_edit, user_ai_action, system_init)
- **When it changed** (server timestamp)
- **How the user triggered it** (ui_source: cell_edit, set_done_toggle, ai_button)

Events are written to Firestore subcollection and are immutable.

### 3.4 P4: Explicit Delegation Gates AI Mutations

AI can only mutate workout state when user explicitly triggers:
- AI buttons (Auto-fill, Swap exercise, Generate workout)
- Chat instructions ("change bench press to incline")

Otherwise: AI suggestions are staged as inline actions, never auto-committed.

### 3.5 P5: Post-Workout Analysis Uses Computed Analytics as Source-of-Truth

After workout completion:
- Use existing analytics pipeline for stats computation
- LLM only narrates and highlights computed metrics
- No invented numbers—all data grounded in computed values

---

## 4. Data Lifecycle

### 4.1 The Three Data States

Understanding the relationship between templates, active workouts, and completed workouts is critical:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DATA LIFECYCLE                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  TEMPLATE (Immutable Prescription Baseline)                                 │
│  ┌─────────────────────────────────────────┐                               │
│  │ • Defines target reps/rir/weight        │                               │
│  │ • Never modified during workout         │                               │
│  │ • Created by Planner agent or user      │                               │
│  │ • Referenced by source_template_id      │                               │
│  └─────────────────────────────────────────┘                               │
│                      │                                                      │
│                      │ Initializes                                          │
│                      ▼                                                      │
│  ACTIVE_WORKOUT (Mutable Working Copy)                                     │
│  ┌─────────────────────────────────────────┐                               │
│  │ • Values are what user will log         │                               │
│  │ • User edits directly (single value)    │                               │
│  │ • No target/actual separation           │                               │
│  │ • Copilot assists via explicit actions  │                               │
│  └─────────────────────────────────────────┘                               │
│                      │                                                      │
│                      │ Archives to                                          │
│                      ▼                                                      │
│  COMPLETED_WORKOUT (Archived Actuals)                                      │
│  ┌─────────────────────────────────────────┐                               │
│  │ • Snapshot of active_workout at finish  │                               │
│  │ • Used for analytics and progression    │                               │
│  │ • Immutable historical record           │                               │
│  │ • Copilot compares to prior workouts    │                               │
│  └─────────────────────────────────────────┘                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Key Principle: Progression Compares Completed Workouts

When Copilot calculates progression deltas:
- **Compare**: completed_workout vs prior completed_workouts
- **NOT**: active_workout vs template

The template is just the starting point. What matters for progression is what the user actually did.

### 4.3 Single-Value Set Model

Unlike some systems that track "target" and "actual" separately, we use a **single-value model**:

| Approach | Our Model |
|----------|-----------|
| Template says 10 reps | Active workout starts with 10 reps |
| User changes to 8 reps | Value becomes 8 reps |
| User marks done | Status becomes 'done', value stays 8 |
| Template still says 10 reps | Template is unchanged |

**Why?**
- Simpler mental model for users
- Cleaner data model (no null-handling for "actual" before set is done)
- Template remains the prescription baseline for analytics

### 4.4 Workout State Machine

```
                        startActiveWorkout()
                               │
                               ▼
                      ┌────────────────┐
                      │  in_progress   │
                      └────────┬───────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
    completeActiveWorkout()   │    cancelActiveWorkout()
              │                │                │
              ▼                │                ▼
    ┌─────────────────┐        │     ┌─────────────────┐
    │   completed     │        │     │   cancelled     │
    └─────────────────┘        │     └─────────────────┘
              │                │
              │                │
              ▼                │
    (Archives to workouts      │
     collection, triggers      │
     analytics pipeline)       │
```

### 4.5 Workout Start Entry Points

Focus Mode supports multiple entry surfaces that all converge into a unified workout creation pipeline.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ WORKOUT START ENTRY POINTS                                                  │
│                                                                             │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────────────────┐   │
│  │   Template  │   │  Routine    │   │  Canvas Session Plan            │   │
│  │   Picker    │   │  "Next"     │   │  (Planning Agent)               │   │
│  └──────┬──────┘   └──────┬──────┘   └────────────────┬────────────────┘   │
│         │                 │                           │                    │
│         │ template_id     │ template_id +             │ plan.blocks        │
│         │                 │ source_routine_id         │                    │
│         ▼                 ▼                           ▼                    │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    startActiveWorkout (backend)                      │   │
│  │                                                                      │   │
│  │  1. Transaction lock check (single active workout)                   │   │
│  │  2. Resume if existing workout found                                 │   │
│  │  3. workout-seed-mapper.js transforms to exercises                   │   │
│  │  4. Create active_workout doc with exercises                         │   │
│  │  5. Set lock in users/{uid}/meta/active_workout_state                │   │
│  └────────────────────────────────────────────────────────────────┬─────┘   │
│                                                                    │        │
│                                                          { workout_id,     │
│                                                            workout: {...}, │
│                                                            resumed: bool } │
│                                                                    │        │
│                                                                    ▼        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    FocusModeWorkoutScreen                            │   │
│  │                                                                      │   │
│  │  - Displays exercises with set grid                                  │   │
│  │  - Timer derived from workout.startTime                              │   │
│  │  - Optimistic updates via MutationCoordinator                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Entry Point Options:**

| Entry Point | Source | Parameters |
|-------------|--------|------------|
| **Template Picker** | User-saved templates | `template_id` |
| **Next from Rotation** | Routine cursor | `template_id` + `source_routine_id` |
| **Canvas Session Plan** | Planning Agent output | `plan.blocks` array |
| **Empty Workout** | No source | None (start blank) |

**workout-seed-mapper.js:**

The backend uses `workout-seed-mapper.js` to transform templates and plans into the normalized exercise format:

```javascript
// From template
async function templateToExercises(userId, templateId)
  → [{ instance_id, exercise_id, name, position, sets: [...] }]

// From plan blocks
async function planBlocksToExercises(blocks)
  → [{ instance_id, exercise_id, name, position, sets: [...] }]

// Validation applied during transformation
validateReps(reps)   → clamps to [1, 30]
validateRir(rir)     → clamps to [0, 5]
validateWeight(w)    → null or >= 0
```

### 4.6 Routine Cursor Mechanics

When a user works through a routine, the cursor tracks which template comes next.

**Storage Location:**
- `users/{uid}/routines/{routineId}` → `last_completed_template_id`

**Cursor Advancement Flow:**
```
1. User starts workout from "Next Scheduled"
   → startActiveWorkout({ template_id, source_routine_id })
   
2. User completes workout
   → completeActiveWorkout() archives workout with source_routine_id
   
3. Firestore trigger fires on archived workout creation
   → workout-routine-cursor.js updates last_completed_template_id
   
4. Next getNextWorkout call returns the subsequent template
```

**Selection Logic (getNextWorkout):**
1. **Primary**: Use `last_completed_template_id` cursor (O(1) lookup)
2. **Fallback**: Scan last 50 workouts for matching template
3. **Default**: First template if no history

**Edge Case Handling:**

| Edge Case | Handling |
|-----------|----------|
| Double-tap start | Transaction-based lock prevents race |
| Existing workout on start | Resume gate dialog: Resume or Discard |
| Template deleted from routine | Fallback to first available template |
| No routine set | "Next Scheduled" button hidden |
| No templates saved | "From Template" disabled |

---

## 5. Firestore Schema

### 5.1 Active Workout Document

**Path**: `users/{uid}/active_workouts/{activeWorkoutId}`

```javascript
{
  // === Identity ===
  id: string,                           // Document ID
  user_id: string,                      // Owner user ID
  
  // === State ===
  status: 'in_progress' | 'completed' | 'cancelled',
  
  // === Source References ===
  source_template_id: string | null,    // Template this was initialized from
  source_routine_id: string | null,     // Routine for cursor updates
  
  // === Exercise Data ===
  exercises: [
    {
      instance_id: string,              // Workout-local stable ID (UUID)
      exercise_id: string,              // Catalog reference (exercises collection)
      name: string,                     // Denormalized for display (non-authoritative)
      position: number,                 // Order (0, 1, 2, ...)
      
      sets: [
        {
          id: string,                   // Stable set ID (UUID)
          set_type: 'warmup' | 'working' | 'dropset',
          
          // === Single-Value Fields (user edits directly) ===
          weight: number | null,        // kg, null for bodyweight
          reps: number,                 // 1-30 for planned, 0-30 for done
          rir: number,                  // 0-5 (Reps In Reserve)
          
          // === Status ===
          status: 'planned' | 'done' | 'skipped',
          
          // === Tags ===
          tags: {
            is_failure: boolean | null  // Explicit failure flag (required if reps=0)
          }
        }
      ]
    }
  ],
  
  // === Computed Totals (recomputed on each mutation) ===
  totals: {
    sets: number,                       // Count of done working+dropset sets
    reps: number,                       // Sum of reps for done working+dropset sets
    volume: number                      // Sum of weight*reps for done sets (null weight = 0)
  },
  
  // === Timestamps ===
  start_time: Timestamp,                // When workout started
  end_time: Timestamp | null,           // When completed/cancelled
  created_at: Timestamp,                // Document creation
  updated_at: Timestamp,                // Last modification
  
  // === Optional ===
  notes: string | null                  // User notes
}
```

### 5.2 Exercise Instance vs Exercise ID

Two different IDs serve different purposes:

| Field | Purpose | Generated By | Stability |
|-------|---------|--------------|-----------|
| `instance_id` | Identify this specific exercise in this workout | Server on add | Stable within workout |
| `exercise_id` | Reference to exercise catalog | User selection | Points to exercises collection |

**Why two IDs?**
- User might add the same exercise twice (e.g., two bench press blocks)
- `instance_id` differentiates them within the workout
- `exercise_id` links to catalog for metadata lookup

### 5.3 Set ID Requirements

- **Format**: UUID v4 string
- **Generation**: Client generates for add_set ops, server generates for template initialization
- **Uniqueness**: Must be unique within the workout (not globally)
- **Stability**: Never changes once created

### 5.4 Totals Computation Rules

```javascript
// Totals computation pseudocode
totals = {
  sets: exercises.flatMap(e => e.sets)
    .filter(s => s.status === 'done')
    .filter(s => s.set_type === 'working' || s.set_type === 'dropset')
    .length,
  
  reps: exercises.flatMap(e => e.sets)
    .filter(s => s.status === 'done')
    .filter(s => s.set_type === 'working' || s.set_type === 'dropset')
    .reduce((sum, s) => sum + s.reps, 0),
  
  volume: exercises.flatMap(e => e.sets)
    .filter(s => s.status === 'done')
    .filter(s => s.set_type === 'working' || s.set_type === 'dropset')
    .filter(s => s.weight !== null)
    .reduce((sum, s) => sum + (s.weight * s.reps), 0)
}
```

**Key rules**:
- Warmups are **excluded** from all totals
- Skipped sets are **excluded** from all totals
- Planned sets are **excluded** from all totals
- Sets with `weight: null` contribute 0 to volume (bodyweight exercises)
- `reps: 0` with `is_failure: true` contributes 0 to totals (attempted but failed)

### 5.5 Ordering Model

**Exercises**: Ordered by `position` field (0, 1, 2, ...)
- Position is authoritative
- No reorder operations in MVP
- Position set on add, preserved on swap

**Sets**: Ordered by array index
- Array order is authoritative
- New sets appended to end
- No reorder operations in MVP

### 5.6 Idempotency Keys Subcollection

**Path**: `users/{uid}/active_workouts/{activeWorkoutId}/idempotency/{key}`

```javascript
{
  key: string,                          // The idempotency key
  response: {                           // Cached response
    success: boolean,
    event_id: string,
    totals: { sets, reps, volume }
  },
  created_at: Timestamp,
  expires_at: Timestamp                 // TTL: 24 hours
}
```

Used to prevent duplicate processing on retries.

### 5.7 Idempotency Behavior for ALL Mutating Endpoints (Critical)

**Every structural mutating endpoint** must implement the same idempotency pattern. This is NOT optional.

**Idempotent Endpoints**:
| Endpoint | Idempotency Required | Behavior on Duplicate Key |
|----------|---------------------|---------------------------|
| `logSet` | ✅ YES | Return cached response |
| `patchActiveWorkout` | ✅ YES | Return cached response |
| `addExercise` | ✅ YES | Return cached response (critical for structural ops) |
| `swapExercise` | ✅ YES | Return cached response |
| `autofillExercise` | ✅ YES | Return cached response |
| `startActiveWorkout` | ✅ NO (no idempotency_key param) | Creates new workout each time |
| `completeActiveWorkout` | ✅ NO (once only) | Already completed = error |
| `cancelActiveWorkout` | ✅ NO (once only) | Already cancelled = error |

**Standard Idempotency Pattern** (implement in ALL endpoints marked YES):

```javascript
async function handleEndpoint(workoutId, params, idempotencyKey) {
    // 1. CHECK IDEMPOTENCY FIRST
    const idempotencyRef = db.collection(`users/${uid}/active_workouts/${workoutId}/idempotency`).doc(idempotencyKey);
    const existing = await idempotencyRef.get();
    
    if (existing.exists) {
        // RETURN CACHED RESPONSE - do NOT process again
        return existing.data().response;
    }
    
    // 2. Validate and apply mutation
    const result = await applyMutation(workoutId, params);
    
    // 3. Cache response with TTL
    await idempotencyRef.set({
        key: idempotencyKey,
        response: result,
        created_at: FieldValue.serverTimestamp(),
        expires_at: Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000) // 24h TTL
    });
    
    // 4. Write event
    await writeEvent(workoutId, eventType, eventPayload, idempotencyKey);
    
    return result;
}
```

**Why this matters for structural ops**:
- `add_set` with same idempotency key = no duplicate set created
- `addExercise` with same idempotency key = no duplicate exercise added
- `autofillExercise` with same idempotency key = no duplicate set additions

**Client-generated IDs + Server-side duplicate rejection**:
For `add_set` and `addExercise`, the client provides the `id` field. The server also rejects any request that would create a duplicate ID within the workout, as a safety check even if idempotency lookup fails.

```javascript
// Server-side duplicate ID check (belt and suspenders)
if (workout.exercises.some(e => 
    e.sets.some(s => s.id === newSet.id)
)) {
    return error('DUPLICATE_SET_ID', 'Set ID already exists in workout');
}
```

---

## 6. Backend Endpoints

### 6.1 Endpoint Overview

| Endpoint | Purpose | Event Type |
|----------|---------|------------|
| `startActiveWorkout` | Initialize workout from template/plan | `workout_started` |
| `logSet` | Mark set as done (hot path) | `set_done` |
| `patchActiveWorkout` | Edit values, add/remove sets | `set_updated` / `set_added` / `set_removed` |
| `autofillExercise` | AI bulk prescription | `autofill_applied` |
| `addExercise` | Add exercise with defaults | `exercise_added` |
| `swapExercise` | Replace exercise | `exercise_swapped` |
| `completeActiveWorkout` | Finalize and archive | `workout_completed` |
| `cancelActiveWorkout` | Abort without archive | `workout_cancelled` |

### 6.2 startActiveWorkout

Initialize a new active workout.

**Request**:
```javascript
{
  // Option 1: From template
  template_id: string,
  source_routine_id?: string,           // Required for cursor advancement
  
  // Option 2: From plan (AI-generated or manual)
  plan?: {
    blocks: [
      {
        exercise_id: string,
        name?: string,                  // Server fetches if omitted
        sets: [
          { set_type: 'warmup' | 'working' | 'dropset', reps: number, rir: number, weight: number | null }
        ]
      }
    ]
  }
}
```

**Response**:
```javascript
{
  success: true,
  workout_id: string,
  exercises: [...],                     // Full exercise array
  totals: { sets: 0, reps: 0, volume: 0 }
}
```

**Server Behavior**:
1. Create active_workout document
2. Copy exercises/sets from template OR create from plan
3. Generate `instance_id` for each exercise
4. Generate `id` for each set
5. Set all sets to `status: 'planned'`
6. Fetch exercise names from catalog if needed
7. Write `workout_started` event with `cause: 'system_init'`

### 6.3 logSet (Hot Path)

Mark a set as done. This is the most frequently called endpoint.

**Request**:
```javascript
{
  workout_id: string,
  exercise_instance_id: string,
  set_id: string,
  values: {
    weight: number | null,
    reps: number,                       // 0-30
    rir: number                         // 0-5
  },
  is_failure?: boolean,                 // Required if reps=0
  idempotency_key: string,
  client_timestamp: string              // ISO 8601
}
```

**Response (Success)**:
```javascript
{
  success: true,
  event_id: string,
  totals: { sets, reps, volume }
}
```

**Response (Error - Already Done)**:
```javascript
{
  success: false,
  error: {
    code: 'ALREADY_DONE',
    message: 'Set already marked done. Use patchActiveWorkout to edit.'
  }
}
```

**Server Behavior**:
1. Check idempotency key → return cached response if duplicate
2. Check if set already has `status: 'done'` → return ALREADY_DONE error
3. Validate: reps ∈ [0, 30], rir ∈ [0, 5]
4. Validate: if reps = 0, is_failure must be true
5. Update set: weight, reps, rir, status = 'done', tags.is_failure
6. Recompute totals
7. Write `set_done` event with stable IDs in payload
8. Store idempotency key with response (24h TTL)

**Why separate endpoint for done?**
- Most frequent operation (hottest path)
- Needs atomic status change + value update
- Prevents "mark done" via patch ops (keeps semantics clean)

### 6.4 patchActiveWorkout

Unified endpoint for editing values, adding/removing sets.

**Request**:
```javascript
{
  workout_id: string,
  ops: [
    // Field update
    {
      op: 'set_field',
      target: { exercise_instance_id: string, set_id: string },
      field: 'weight' | 'reps' | 'rir' | 'status' | 'set_type' | 'tags.is_failure',
      value: any
    },
    // Add set
    {
      op: 'add_set',
      target: { exercise_instance_id: string },
      value: {
        id: string,                     // Client-generated UUID (REQUIRED)
        set_type: 'warmup' | 'working' | 'dropset',
        reps: number,
        rir: number,
        weight: number | null,
        status: 'planned',              // Must be 'planned'
        tags: {}
      }
    },
    // Remove set
    {
      op: 'remove_set',
      target: { exercise_instance_id: string, set_id: string }
    }
  ],
  cause: 'user_edit' | 'user_ai_action',
  ui_source: string,                    // 'cell_edit', 'add_set', 'ai_button', etc.
  idempotency_key: string,
  client_timestamp: string,
  ai_scope?: { exercise_instance_id: string }  // Required for AI actions
}
```

**Response (Success)**:
```javascript
{
  success: true,
  event_id: string,                     // Single event for entire request
  totals: { sets, reps, volume }
}
```

**Response (Error)**:
```javascript
{
  success: false,
  error: {
    code: 'TARGET_NOT_FOUND' | 'VALIDATION_ERROR' | 'PERMISSION_DENIED' |
          'MIXED_OP_TYPES' | 'MULTI_SET_EDIT' | 'MULTIPLE_STRUCTURAL_OPS' |
          'DUPLICATE_SET_ID',
    message: string,
    details?: { op_index: number, ... }
  }
}
```

**Homogeneous Request Constraint**:

Requests must be homogeneous to ensure one event per request:

| Allowed | Description |
|---------|-------------|
| Multiple `set_field` ops for SAME set | Edit weight, reps, rir in one call |
| Single `add_set` op | Add one set |
| Single `remove_set` op | Remove one set |

| Rejected | Reason |
|----------|--------|
| Mixed op types | Would require multiple events |
| `set_field` ops for different sets | Would require multiple events |
| Multiple `add_set` ops | Use autofillExercise for bulk adds |

**AI Scope Validation** (when `cause: 'user_ai_action'`):
- REJECT ops on sets with `status: 'done'` or `status: 'skipped'`
- REJECT ops outside `ai_scope.exercise_instance_id`
- REJECT `remove_set` ops
- REJECT ops that modify `status`, `set_type`, or `tags` fields
- ALLOW only: `weight`, `reps`, `rir` on planned sets

### 6.5 autofillExercise

AI bulk prescription for a single exercise.

**Request**:
```javascript
{
  workout_id: string,
  exercise_instance_id: string,
  updates: [
    // Update existing planned sets
    { set_id: string, weight?: number, reps?: number, rir?: number }
  ],
  additions: [
    // Add new planned sets
    { id: string, set_type: 'working' | 'dropset', reps: number, rir: number, weight: number | null }
  ],
  idempotency_key: string,
  client_timestamp: string
}
```

**Response**:
```javascript
{
  success: true,
  event_id: string,                     // Single 'autofill_applied' event
  totals: { sets, reps, volume }
}
```

**Server Validation**:
1. All updates target planned sets only
2. All additions have unique IDs (within workout)
3. All values pass science validation (reps 1-30, rir 0-5, weight >= 0 or null)
4. Total sets per exercise <= 8 after additions

### 6.6 addExercise

Add a new exercise with default sets.

**Request**:
```javascript
{
  workout_id: string,
  exercise_id: string,                  // Catalog reference
  // NOTE: position parameter removed for MVP (append-only)
  sets?: [
    { set_type: string, reps: number, rir: number, weight?: number }
  ],
  idempotency_key: string,
  client_timestamp: string
}
```

**Response**:
```javascript
{
  success: true,
  event_id: string,
  exercise_instance_id: string,         // Generated instance ID
  totals: { sets, reps, volume }
}
```

**Default Set Initialization** (when `sets` omitted):
- Create 3 working sets
- Each set: `{ set_type: 'working', reps: 10, rir: 2, weight: null, status: 'planned', tags: {} }`

**Server Behavior**:
1. Check idempotency key → return cached response if duplicate
2. Fetch exercise name from catalog
3. Generate `instance_id` for exercise
4. Generate `id` for each set (or use provided)
5. **APPEND to end of exercises array** (position = max existing + 1)
6. Store idempotency key with response (24h TTL)
7. Write `exercise_added` event

**Why append-only?**: Supporting arbitrary position insertion implies reordering/renumbering semantics. For MVP, we avoid this complexity. Reordering can be added later.

### 6.7 swapExercise

Replace an exercise while optionally preserving completed sets.

**Request**:
```javascript
{
  workout_id: string,
  exercise_instance_id: string,         // Exercise to replace
  new_exercise_id: string,              // Catalog reference
  preserve_completed: boolean,          // Default: true
  idempotency_key: string,
  client_timestamp: string
}
```

**Response**:
```javascript
{
  success: true,
  event_id: string,
  totals: { sets, reps, volume }
}
```

**Swap Behavior**:

| preserve_completed | Done Sets | Planned Sets |
|--------------------|-----------|--------------|
| `true` (default) | Keep unchanged | Reset to defaults (reps=10, rir=2, weight=null), keep same IDs |
| `false` | Remove all | Remove all, create 3 new defaults |

**Server Behavior**:
1. Fetch new exercise name from catalog
2. Update `exercise_id` and `name`
3. If preserve_completed:
   - Keep done sets unchanged
   - Reset planned sets to defaults (keep IDs)
4. Else: Remove all sets, create 3 new defaults
5. Write `exercise_swapped` event

### 6.8 completeActiveWorkout

Finalize workout and archive to completed workouts.

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
  archived_workout_id: string
}
```

**Server Behavior**:
1. Set `status: 'completed'`, `end_time: now`
2. Archive full data to workouts collection (all sets including warmups)
3. Trigger analytics pipeline
4. Update routine cursor if applicable
5. Write `workout_completed` event

### 6.9 cancelActiveWorkout

Abort workout without archiving.

**Request**:
```javascript
{
  workout_id: string
}
```

**Response**:
```javascript
{
  success: true
}
```

**Server Behavior**:
1. Set `status: 'cancelled'`, `end_time: now`
2. Do NOT archive to workouts
3. Write `workout_cancelled` event

---

## 7. Event System

### 7.1 Events Subcollection

**Path**: `users/{uid}/active_workouts/{activeWorkoutId}/events/{eventId}`

Events form an immutable audit trail of all workout mutations.

### 7.2 Event Schema

```javascript
{
  // === Event Identity ===
  id: string,                           // Document ID
  type: 'workout_started' | 'set_done' | 'set_updated' | 'set_added' |
        'set_removed' | 'exercise_added' | 'exercise_removed' |
        'exercise_swapped' | 'autofill_applied' | 'workout_completed' |
        'workout_cancelled',
  
  // === Stable IDs for Resolution ===
  payload: {
    exercise_instance_id?: string,      // For set/exercise events
    set_id?: string,                    // For set events
    fields_changed?: string[],          // ['weight', 'reps'] - hint for consumers
    // Additional type-specific data
  },
  
  // === Diff Operations (for replay/debugging) ===
  diff_ops: [
    { op: 'replace', path: '/exercises/0/sets/2/status', value: 'done' },
    { op: 'replace', path: '/exercises/0/sets/2/reps', value: 8 }
  ],
  
  // === Causality ===
  cause: 'system_init' | 'user_edit' | 'user_ai_action',
  ui_source: 'system' | 'cell_edit' | 'set_done_toggle' | 'add_set' |
             'remove_set' | 'add_exercise' | 'remove_exercise' |
             'swap_exercise' | 'ai_button',
  
  // === Deduplication ===
  idempotency_key: string,
  
  // === Timestamps ===
  client_timestamp: string,             // ISO 8601 from client (may be unreliable)
  created_at: Timestamp                 // Server timestamp (authoritative)
}
```

### 7.3 Event Types Reference

| Event Type | Cause | UI Source | Payload |
|------------|-------|-----------|---------|
| `workout_started` | `system_init` | `system` | - |
| `set_done` | `user_edit` | `set_done_toggle` | `exercise_instance_id`, `set_id` |
| `set_updated` | `user_edit` or `user_ai_action` | `cell_edit` or `ai_button` | `exercise_instance_id`, `set_id`, `fields_changed` |
| `set_added` | `user_edit` or `user_ai_action` | `add_set` or `ai_button` | `exercise_instance_id`, `set_id` |
| `set_removed` | `user_edit` | `remove_set` | `exercise_instance_id`, `set_id` |
| `exercise_added` | `user_edit` | `add_exercise` | `exercise_instance_id` |
| `exercise_swapped` | `user_edit` or `user_ai_action` | `swap_exercise` or `ai_button` | `exercise_instance_id`, `new_exercise_id` |
| `autofill_applied` | `user_ai_action` | `ai_button` | `exercise_instance_id`, `sets_updated`, `sets_added` |
| `workout_completed` | `user_edit` | `system` | - |
| `workout_cancelled` | `user_edit` | `system` | - |

### 7.4 Server-Written Events

**Critical**: All events are written by the server, not the client.

**Why?**
- Consistent timestamps (server clock is authoritative)
- Atomic with mutation (event + state change in one transaction)
- No drift between client-reported and actual state
- Reliable for analytics and debugging

### 7.5 Status Transition Events

When set status changes via `patchActiveWorkout`:

| Transition | Allowed | Event |
|------------|---------|-------|
| planned → done | NO (use logSet) | - |
| planned → skipped | YES (user_edit only) | `set_updated` |
| skipped → planned | YES (user_edit only) | `set_updated` |
| done → planned | YES (user_edit only, "undo done") | `set_updated` |
| done → skipped | NO | - |

### 7.6 Undo Done Semantics

When user "undoes" a done set (done → planned):
- Set `status: 'planned'`
- **Retain** weight, reps, rir values (user may want to edit, not lose)
- **Retain** tags.is_failure (user can clear separately)
- Totals are recomputed (done count decreases)

---

## 8. iOS Architecture

### 8.1 Local-First State Management with MutationCoordinator

The iOS app uses a **local-first** architecture where optimistic updates are applied immediately, and sync is handled via a `MutationCoordinator` actor that ensures proper ordering and dependency satisfaction.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    LOCAL-FIRST ARCHITECTURE (Current)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  FocusModeWorkoutScreen (UI)                                        │   │
│  │  └── Observes: workout, isLoading, error, exerciseSyncState         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │ User Actions                                 │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  FocusModeWorkoutService (@MainActor, ObservableObject)             │   │
│  │  ├── workout: FocusModeWorkout?      - Local state (source of truth)│   │
│  │  ├── exerciseSyncState: [String: EntitySyncState]  - Per-entity UI  │   │
│  │  ├── currentSessionId: UUID?         - Validates callbacks          │   │
│  │  └── mutationCoordinator             - Handles sync ordering        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │ Optimistic Update + Enqueue                  │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  MutationCoordinator (actor)                                        │   │
│  │  ├── pending: [QueuedMutation]     - Waiting for dependencies       │   │
│  │  ├── ackExercises: Set<String>     - Server-confirmed exercises     │   │
│  │  ├── ackSets: Set<SetKey>          - Server-confirmed sets          │   │
│  │  ├── sessionId: UUID               - Prevents stale callbacks       │   │
│  │  └── inFlight: QueuedMutation?     - Currently executing            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │ Network Calls                                │
│                              ▼                                              │
│  Backend API (addExercise, patchActiveWorkout, logSet, etc.)               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key Components:**

| Component | Responsibility |
|-----------|----------------|
| `FocusModeWorkoutService` | Local-first state, optimistic updates, coordinator orchestration |
| `MutationCoordinator` | Serial queue, dependency ordering, retries, reconciliation |
| `FocusModeWorkout` | Domain model for workout state |
| `exerciseSyncState` | Per-entity sync tracking for UI indicators |

### 8.2 Commit Points

Not every keystroke triggers a server call. Only specific "commit points" sync to Firestore:

| User Action | Commit Type | Endpoint |
|-------------|-------------|----------|
| Tap done checkbox | Immediate | `logSet` |
| Blur/return after editing cell | Debounced (2s) | `patchActiveWorkout` |
| Tap "Add Set" button | Immediate | `patchActiveWorkout` |
| Swipe to delete set | Immediate | `patchActiveWorkout` |
| Tap "Add Exercise" | Immediate | `addExercise` |
| Tap AI action button | Immediate | `autofillExercise` |
| Tap "Finish Workout" | Immediate | `completeActiveWorkout` |

### 8.3 Pending Edits Queue

Edits are accumulated per set before committing:

```swift
struct SetKey: Hashable {
    let exerciseInstanceId: String
    let setId: String
}

struct PendingEdit {
    var weight: Double?
    var reps: Int?
    var rir: Int?
    var hasChanges: Bool { weight != nil || reps != nil || rir != nil }
}

// Pending edits are keyed by (exercise_instance_id, set_id)
var pendingEdits: [SetKey: PendingEdit] = [:]
```

### 8.4 Commit Coordination

**Critical**: When marking a set done, we must:
1. Remove pending edits for THIS set (done values supersede)
2. Flush ALL remaining pending edits (so they don't get stranded)
3. THEN call logSet

```swift
// When user taps done:
func markSetDone(exerciseInstanceId: String, setId: String, values: SetValues) async {
    let key = SetKey(exerciseInstanceId: exerciseInstanceId, setId: setId)
    
    // 1. Remove pending edits for THIS set (done values supersede)
    pendingEdits.removeValue(forKey: key)
    
    // 2. Cancel debounce timer
    debounceTimer?.invalidate()
    
    // 3. Update local state immediately
    updateLocalSet(exerciseInstanceId, setId) { set in
        set.weight = values.weight
        set.reps = values.reps
        set.rir = values.rir
        set.status = .done
    }
    recalculateTotals()
    
    // 4. CRITICAL: Flush ALL remaining pending edits first
    //    This prevents stranding other sets' edits
    await flushPendingEdits()
    
    // 5. Then call logSet
    try await service.logSet(
        workoutId: workoutId,
        exerciseInstanceId: exerciseInstanceId,
        setId: setId,
        values: values,
        isFailure: values.reps == 0,
        idempotencyKey: UUID().uuidString,
        clientTimestamp: Date().iso8601
    )
}
```

**Why this order matters**: If we only cancel the debounce timer without flushing, any pending edits for OTHER sets would never be committed until the next edit or explicit commit. This could cause silent data loss.

### 8.5 Debounced Cell Edits

```swift
func updateSetValue(exerciseInstanceId: String, setId: String, field: SetField, value: Any) {
    let key = SetKey(exerciseInstanceId: exerciseInstanceId, setId: setId)
    
    // 1. Update local state immediately
    updateLocalSet(exerciseInstanceId, setId) { set in
        switch field {
        case .weight: set.weight = value as? Double
        case .reps: set.reps = value as! Int
        case .rir: set.rir = value as! Int
        }
    }
    
    // 2. Accumulate pending edit (last value wins per field)
    var edit = pendingEdits[key] ?? PendingEdit()
    switch field {
    case .weight: edit.weight = value as? Double
    case .reps: edit.reps = value as? Int
    case .rir: edit.rir = value as? Int
    }
    pendingEdits[key] = edit
    
    // 3. Debounce server commit (2s, collapses multiple edits)
    debounceTimer?.invalidate()
    debounceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
        Task { await self.flushPendingEdits() }
    }
}

// Also commit on blur/return
func commitCellEdit() async {
    debounceTimer?.invalidate()
    await flushPendingEdits()
}
```

### 8.5.1 Flush Sends ONE Request Per Set (Critical)

**Backend constraint**: `patchActiveWorkout` only allows `set_field` ops for a SINGLE set per request.

**iOS flush behavior**: Group pending edits by `SetKey` and send one request per set.

```swift
func flushPendingEdits() async {
    guard !pendingEdits.isEmpty else { return }
    
    // Copy and clear atomically
    let editsToFlush = pendingEdits
    pendingEdits = [:]
    
    // Group by SetKey and send ONE request per set
    // This preserves "one event per commit" on the backend
    for (key, edit) in editsToFlush {
        guard edit.hasChanges else { continue }
        
        var ops: [PatchOp] = []
        if let weight = edit.weight {
            ops.append(PatchOp.setField(
                target: Target(exerciseInstanceId: key.exerciseInstanceId, setId: key.setId),
                field: "weight",
                value: weight
            ))
        }
        if let reps = edit.reps {
            ops.append(PatchOp.setField(
                target: Target(exerciseInstanceId: key.exerciseInstanceId, setId: key.setId),
                field: "reps",
                value: reps
            ))
        }
        if let rir = edit.rir {
            ops.append(PatchOp.setField(
                target: Target(exerciseInstanceId: key.exerciseInstanceId, setId: key.setId),
                field: "rir",
                value: rir
            ))
        }
        
        // ONE request per set (multiple fields for same set is allowed)
        do {
            try await service.patchActiveWorkout(
                workoutId: workoutId,
                ops: ops,
                cause: .userEdit,
                uiSource: "cell_edit",
                idempotencyKey: UUID().uuidString,
                clientTimestamp: Date().iso8601
            )
        } catch {
            // Re-queue failed edits for retry
            pendingEdits[key] = edit
        }
    }
}
```

**Why N requests?**: Backend enforces homogeneous requests. This trades latency (N round trips) for semantic cleanliness (one event per set per commit). For typical workouts (1-2 pending edits at flush), this is acceptable.

### 8.6 Firestore Reconciliation

Reconciliation happens only on **app foreground**, not via continuous listeners.

```swift
func reconcileWithServer(serverSnapshot: ActiveWorkout) {
    // Build maps by stable IDs
    var localExercises: [String: (index: Int, exercise: FocusModeExercise)] = [:]
    for (idx, ex) in exercises.enumerated() {
        localExercises[ex.instanceId] = (idx, ex)
    }
    
    var serverExerciseIds = Set<String>()
    
    for serverExercise in serverSnapshot.exercises {
        serverExerciseIds.insert(serverExercise.instanceId)
        
        if let local = localExercises[serverExercise.instanceId] {
            // Exercise exists locally - merge sets
            mergeSets(local: &exercises[local.index], server: serverExercise)
        } else {
            // New exercise from server (AI added?) - insert
            let insertIndex = min(serverExercise.position, exercises.count)
            exercises.insert(serverExercise.toLocal(), at: insertIndex)
        }
    }
    
    // Remove exercises that no longer exist on server
    // (only if no pending local edits for those exercises)
    exercises.removeAll { ex in
        !serverExerciseIds.contains(ex.instanceId) && !hasPendingEdits(for: ex.instanceId)
    }
    
    // Sort by position after merge
    exercises.sort { $0.position < $1.position }
    
    recalculateTotals()
}

func mergeSets(local: inout FocusModeExercise, server: ServerExercise) {
    var localSets: [String: Int] = [:]
    for (idx, set) in local.sets.enumerated() {
        localSets[set.id] = idx
    }
    
    var serverSetIds = Set<String>()
    
    for serverSet in server.sets {
        serverSetIds.insert(serverSet.id)
        let key = SetKey(exerciseInstanceId: server.instanceId, setId: serverSet.id)
        
        if let localIdx = localSets[serverSet.id] {
            // Set exists - update if not actively editing
            if pendingEdits[key] == nil && activelyEditingSet != key {
                local.sets[localIdx] = serverSet.toLocal()
            }
        } else {
            // New set from server - append
            local.sets.append(serverSet.toLocal())
        }
    }
    
    // Remove sets no longer on server (if no pending edits)
    local.sets.removeAll { set in
        let key = SetKey(exerciseInstanceId: local.instanceId, setId: set.id)
        return !serverSetIds.contains(set.id) && pendingEdits[key] == nil
    }
}
```

### 8.7 File Structure (Current)

```
Povver/Povver/
├── UI/
│   └── FocusMode/
│       ├── FocusModeWorkoutScreen.swift     # Main workout execution screen
│       ├── FocusModeSetGrid.swift           # Set table with inline editing
│       ├── FocusModeComponents.swift        # Shared UI components
│       └── FocusModeExerciseSearch.swift    # Add exercise sheet
│
├── Services/
│   ├── FocusModeWorkoutService.swift        # Local-first service layer
│   └── MutationCoordinator.swift            # Serial queue for mutations
│
├── Models/
│   └── FocusModeModels.swift                # Domain models (Workout, Exercise, Set)
│
└── UI/
    └── DesignSystem/
        └── Tokens.swift                     # Design tokens (colors, spacing)
```

**Key Files:**

| File | Purpose |
|------|---------|
| `FocusModeWorkoutService.swift` | Local-first state management, optimistic updates, coordinator orchestration |
| `MutationCoordinator.swift` | Serial mutation queue, dependency ordering, session scoping, reconciliation |
| `FocusModeModels.swift` | Domain models: `FocusModeWorkout`, `FocusModeExercise`, `FocusModeSet` |
| `FocusModeWorkoutScreen.swift` | Main UI, observes service state |
| `FocusModeSetGrid.swift` | Set table with inline value editing |

### 8.8 Entry Points

Focus Mode can be entered from:

1. **Template/Routine Card**: Deep link with `template_id`
2. **"Start Empty Workout"**: Empty state with "Generate workout" CTA
3. **Canvas session_plan card**: Accept → Start → Navigate to Focus Mode

**Critical**: Focus Mode is a **dedicated screen**, NOT a Canvas card. Canvas is for planning; Focus Mode is for execution.

---

## 9. Copilot Integration

### 9.1 Copilot Permission Boundaries

The Copilot agent has strict permission gates enforced by the server:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       COPILOT PERMISSION GATES                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  COPILOT CAN READ:                                                          │
│    ✅ Active workout snapshot                                               │
│    ✅ Prior performance for exercises                                       │
│    ✅ User profile, templates, routines                                     │
│    ✅ Analytics data                                                        │
│                                                                             │
│  COPILOT CAN MUTATE ONLY WHEN:                                              │
│    ✅ User taps explicit AI button (Auto-fill, Swap, Generate)              │
│    ✅ User sends chat message with mutation intent                          │
│                                                                             │
│  COPILOT CANNOT:                                                            │
│    ❌ Mutate workout without explicit user trigger                          │
│    ❌ Send unsolicited messages during workout                              │
│    ❌ Modify done sets                                                      │
│    ❌ Remove sets or exercises                                              │
│    ❌ Change status, set_type, or tags fields                               │
│                                                                             │
│  "SILENT FOLLOW-ALONG" BEHAVIOR:                                            │
│    • Compute recommendations in memory (not persisted for MVP)              │
│    • NO mutations, NO messages                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 Copilot Tools (MVP)

The Copilot has access to 4 tools for MVP:

```python
# 1. Read workout state with timing context
def tool_get_active_workout_snapshot(
    workout_id: str,
    user_id: str
) -> dict:
    """
    Returns:
      workout: ActiveWorkout object
      timing: {
        now: ISO timestamp,
        workout_start_time: ISO,
        elapsed_seconds: int,
        time_since_last_done_set: int or null,
        last_done_set_server_timestamp: ISO or null
      }
    """

# 2. Apply patches (calls autofillExercise)
def tool_apply_workout_patch(
    workout_id: str,
    user_id: str,
    exercise_instance_id: str,  # Required scope
    updates: list,               # Existing set updates
    additions: list,             # New sets
    intent: str,                 # "auto-fill bench press targets"
    idempotency_key: str,
    client_timestamp: str
) -> dict:
    """
    Calls autofillExercise with cause='user_ai_action'.
    Server enforces scope and blocks done-set modifications.
    """

# 3. Get prior performance for prescription
def tool_get_prior_performance(
    user_id: str,
    exercise_id: str,            # Catalog ID
    horizon_days: int = 90
) -> dict:
    """
    Returns:
      last_workout: { date, sets: [{ weight, reps, rir }] }
      best_e1rm: { value, date, weight, reps }
      suggested_next: { weight, reps, rir }  # Simple progression
    """

# 4. Complete workout with summary
def tool_complete_workout(
    workout_id: str,
    user_id: str
) -> dict:
    """
    Finalizes workout, returns:
      archived_workout_id
      summary: { went_well, to_improve, next_session_note }
    """
```

### 9.3 Inline AI Action Buttons

Per exercise, the UI shows small action buttons:

| Button | Behavior | Backend |
|--------|----------|---------|
| **Auto-fill** | Generate prescription from history | `autofillExercise` |
| **Use Last** | Copy last performed scheme exactly | `autofillExercise` |
| **+2.5kg** | Increment weight on all planned sets | `autofillExercise` |
| **Swap** | Show alternatives, replace exercise | `swapExercise` |

These are **small, non-chat UI controls**—not "enter chatbot mode".

### 9.4 Timestamp Context for Agent Calls

When Copilot tools are invoked, include timing context:

```javascript
{
  workout_id: string,
  now: string,                          // ISO timestamp
  workout_start_time: string,           // From active_workout.start_time
  elapsed_seconds: number,              // now - start_time
  time_since_last_done_set: number,     // Seconds since last set marked done
  last_done_set_server_timestamp: string // For reliable timing
}
```

This allows Copilot to reason about pace and rest without inferring from raw events.

### 9.5 Post-Workout Summary

After completing workout, Copilot generates a brief summary:

```
3 BULLETS (computed-metric grounded):
1. What went well (e.g., "Hit a rep PR on bench: 8 reps at 85kg")
2. What to improve (e.g., "RIR was higher than target on squats")
3. Next session adjustment (e.g., "Try +2.5kg on bench next time")

No long explanations unless user taps "Details".
All numbers from analytics pipeline, not invented.
```

---

## 10. Validation Rules

### 10.1 Science Validation

| Field | Context | Valid Range | Notes |
|-------|---------|-------------|-------|
| `reps` | Planned sets | 1–30 | Cannot be 0 |
| `reps` | Done sets | 0–30 | 0 requires `is_failure: true` |
| `rir` | All | 0–5 | Reps In Reserve |
| `weight` | All | >= 0 or null | null for bodyweight |

### 10.2 Reps=0 Requires Failure Tag

```javascript
// Server validation
if (set.reps === 0 && set.status === 'done') {
  if (!set.tags?.is_failure) {
    return error('VALIDATION_ERROR', 'reps=0 requires is_failure=true');
  }
}

if (set.reps === 0 && set.status === 'planned') {
  return error('VALIDATION_ERROR', 'Planned sets must have reps >= 1');
}
```

### 10.3 Status Transition Rules

| From | To | Allowed Via | Validated By |
|------|----|-------------|--------------|
| planned | done | `logSet` only | logSet endpoint |
| planned | skipped | `patchActiveWorkout` (user_edit) | patchActiveWorkout |
| skipped | planned | `patchActiveWorkout` (user_edit) | patchActiveWorkout |
| done | planned | `patchActiveWorkout` (user_edit) | patchActiveWorkout |
| done | skipped | **NEVER** | patchActiveWorkout rejects |
| skipped | done | **NEVER** | logSet rejects, patchActiveWorkout rejects |

### 10.4 AI Operation Restrictions

For `cause: 'user_ai_action'`:

| Operation | Allowed | Reason |
|-----------|---------|--------|
| `set_field` on planned set, field: weight | ✅ | |
| `set_field` on planned set, field: reps | ✅ | reps must be 1-30 |
| `set_field` on planned set, field: rir | ✅ | |
| `set_field` on done/skipped set | ❌ | AI cannot modify completed work |
| `set_field` field: status | ❌ | AI cannot change status |
| `set_field` field: set_type | ❌ | AI cannot change set type |
| `set_field` field: tags.* | ❌ | AI cannot modify tags |
| `add_set` | ✅ | status must be 'planned', reps 1-30 |
| `remove_set` | ❌ | AI cannot delete user work |

### 10.5 Weight Validation

```javascript
function validateWeight(weight) {
  if (weight === null || weight === undefined) return true;  // null allowed
  if (typeof weight !== 'number') return false;
  if (isNaN(weight) || !isFinite(weight)) return false;
  if (weight < 0) return false;
  return true;
}
```

---

## 11. Implementation Phases

### Phase 1: Backend Foundation

**Goal**: All endpoints functional with proper validation and events.

- [ ] `startActiveWorkout` - Initialize from template or plan
- [ ] `logSet` - Mark done with idempotency, validation
- [ ] `patchActiveWorkout` - Homogeneous ops, AI scope validation
- [ ] `autofillExercise` - AI bulk edit
- [ ] `addExercise` - Default set initialization
- [ ] `swapExercise` - Preserve completed logic
- [ ] `completeActiveWorkout` - Archive with analytics
- [ ] `cancelActiveWorkout` - Clean cancellation
- [ ] Idempotency keys subcollection with TTL
- [ ] All validation rules implemented
- [ ] Events written for all mutations

### Phase 2: iOS Focus Mode

**Goal**: Local-first workout execution UI.

- [ ] `FocusModeView` - Main dedicated screen
- [ ] `FocusModeViewModel` - Local-first state management
- [ ] `FocusModeSetGrid` - Adapted from SetGridView for execution
- [ ] Commit handlers (immediate for done, debounced for edits)
- [ ] Pending edits queue with flush coordination
- [ ] "Generate workout" CTA for empty start
- [ ] Background Firestore reconciliation (on foreground only)
- [ ] Entry points from templates/routines/canvas

### Phase 3: Copilot MVP

**Goal**: One working AI action (Auto-fill).

- [ ] `tool_get_active_workout_snapshot`
- [ ] `tool_get_prior_performance`
- [ ] `tool_apply_workout_patch` (calls autofillExercise)
- [ ] `tool_complete_workout`
- [ ] Wire "Auto-fill exercise" button → Copilot
- [ ] Test end-to-end: tap Auto-fill → agent generates prescription → patch applied

### Phase 4: Events & Analysis

**Goal**: Complete audit trail and post-workout analysis.

- [ ] Verify all endpoints write canonical events
- [ ] Add timestamp context to Copilot tool calls
- [ ] Post-workout analysis view (using existing analytics)
- [ ] Brief Copilot summary (3 bullets, metric-grounded)

### Phase 5: Polish (Deferred)

**Goal**: Additional features after core is stable.

- [ ] Collapsible chat drawer
- [ ] Additional AI actions (Swap, +2.5kg hints)
- [ ] Offline queue with conflict resolution
- [ ] Rest timer integration

---

## 12. Acceptance Criteria

### 12.1 Core Logging (No AI)

| Criterion | Description |
|-----------|-------------|
| ✅ Complete workout without AI | User can run full workout with no AI usage, feels like Strong/Hevy |
| ✅ Fast editing | Tap cell → edit → done feels instant |
| ✅ Add/remove sets | Swipe or button actions work immediately |
| ✅ Add/remove exercises | User can customize workout on the fly |
| ✅ Mark set done | Done checkbox toggles status and updates totals |
| ✅ View totals | Sets, reps, volume displayed and updated in real-time |

### 12.2 AI Integration

| Criterion | Description |
|-----------|-------------|
| ✅ Auto-fill exercise | User taps Auto-fill → gets reasonable prescription from history |
| ✅ No unsolicited messages | Copilot never posts messages unless user asks |
| ✅ AI respects done sets | AI cannot modify completed work |

### 12.3 Data Integrity

| Criterion | Description |
|-----------|-------------|
| ✅ Events written | Every interaction writes event with timestamp + diff |
| ✅ Idempotency | Retries don't duplicate sets or corrupt state |
| ✅ Totals accurate | Totals correctly exclude warmups, skipped, planned |

### 12.4 Post-Workout

| Criterion | Description |
|-----------|-------------|
| ✅ Archive on complete | Completing archives to workouts collection |
| ✅ Analytics triggered | Completion triggers analytics pipeline |
| ✅ Summary available | Brief Copilot summary with computed metrics |

---

## 13. Strength Training Feature Completeness

### 13.1 Core Logging Features

| Feature | Status | Notes |
|---------|--------|-------|
| Weight/Reps/RIR per set | ✅ Included | Single-value model |
| Set types (warmup, working, dropset) | ✅ Included | Via `set_type` field |
| Failure tagging | ✅ Included | Via `tags.is_failure` |
| Exercise notes | ⚠️ Add | Per-exercise notes field needed |
| Workout notes | ✅ Included | `notes` field on workout |
| Mark set done/skipped | ✅ Included | `status` field |

### 13.2 "Last Time" Performance Display

**Critical for UX**: Users need to see what they did last time for each exercise.

**Implementation**:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│  BENCH PRESS                                              [Auto-fill]       │
│  Last: 80kg × 10, 10, 8 (Dec 28)                                           │
├──────┬────────────┬────────┬────────┬────────┬────────────────────────────┐
│ SET  │   WEIGHT   │  REPS  │  RIR   │   ✓    │  LAST TIME                 │
├──────┼────────────┼────────┼────────┼────────┼────────────────────────────┤
│ 1    │    80kg    │   10   │   2    │   ✓    │  80kg × 10                 │
│ 2    │    80kg    │   10   │   2    │   ○    │  80kg × 10                 │
│ 3    │    80kg    │   10   │   2    │   ○    │  80kg × 8                  │
└──────┴────────────┴────────┴────────┴────────┴────────────────────────────┘
```

**Data Source**: Query `workouts` collection for most recent workout containing this `exercise_id`.

**Endpoint**: `getPriorPerformance` (existing or new)
- Returns: last workout date, sets performed
- Cached on workout start for all exercises

### 13.3 Rest Timer

**Non-blocking rest timer** that doesn't interrupt logging:

```swift
// Rest timer state
struct RestTimerState {
    var isRunning: Bool = false
    var startedAt: Date?
    var targetSeconds: Int = 120  // User preference
    var elapsedSeconds: Int = 0
}

// Auto-start on set done
func onSetDone() {
    restTimer.start()
}

// Display as compact bar below exercise
┌─────────────────────────────────────────────────────────────────┐
│  ⏱ Rest: 1:32 / 2:00                              [+30s] [Skip] │
└─────────────────────────────────────────────────────────────────┘
```

**Features**:
- Auto-start after set done (optional, user preference)
- Visual progress bar
- Gentle vibration when target reached (not intrusive)
- Does NOT block logging—user can continue immediately

### 13.4 Unit Conversion (kg/lbs)

**Storage**: Always in kilograms (canonical unit).

**Display**: Based on user preference (`user.preferences.weight_unit`).

```swift
// Conversion
let KG_TO_LBS = 2.20462

func displayWeight(_ kg: Double, unit: WeightUnit) -> String {
    switch unit {
    case .kg: return "\(formatNumber(kg))kg"
    case .lbs: return "\(formatNumber(kg * KG_TO_LBS))lbs"
    }
}

// Editing: convert input back to kg before saving
func parseWeight(_ input: String, unit: WeightUnit) -> Double {
    let value = Double(input) ?? 0
    switch unit {
    case .kg: return value
    case .lbs: return value / KG_TO_LBS
    }
}
```

### 13.5 Progression Tracking (e1RM)

**Display on completion**:
- Calculate e1RM for each exercise using Epley formula: `e1RM = weight × (1 + reps/30)`
- Compare to previous e1RM
- Highlight PRs (Personal Records)

```javascript
// Post-workout analysis includes:
{
  exercise_summaries: [
    {
      exercise_id: string,
      e1rm_current: number,
      e1rm_previous: number,
      e1rm_delta_pct: number,
      is_pr: boolean,
      rep_pr: { weight: number, reps: number } | null
    }
  ]
}
```

### 13.6 Exercise Notes (Per-Exercise)

**Add to schema**:
```javascript
exercises: [{
  instance_id: string,
  exercise_id: string,
  name: string,
  position: number,
  notes: string | null,  // NEW: per-exercise notes
  sets: [...]
}]
```

**UI**: Expandable notes field below exercise header.

---

## 14. Integration with Existing Systems

### 14.1 Exercise Catalog Integration

**Read-only access** to exercises collection for:
- Exercise search when adding exercises
- Metadata lookup (muscle groups, equipment, variants)
- Name denormalization

```javascript
// On addExercise:
const exercise = await db.collection('exercises').doc(exercise_id).get();
workout.exercises.push({
  instance_id: generateUUID(),
  exercise_id: exercise_id,
  name: exercise.data().name,  // Denormalize
  // ...
});
```

### 14.2 Template System Integration

**startActiveWorkout from template**:
1. Fetch template from `users/{uid}/templates/{templateId}`
2. Deep copy exercises and sets
3. Set `source_template_id` for traceability
4. Template remains unchanged

**Template structure** (existing):
```javascript
{
  id: string,
  name: string,
  exercises: [{
    exercise_id: string,
    sets: [{ reps, rir, weight?, set_type }]
  }]
}
```

### 14.3 Routine System Integration

**Routine cursor updates** on workout completion:
```javascript
// On completeActiveWorkout:
if (workout.source_routine_id) {
  await updateRoutineCursor(
    uid,
    workout.source_routine_id,
    workout.source_template_id,
    workout.id
  );
}
```

**Routine cursor** tracks:
- Current template in rotation
- Last completed workout
- Next scheduled template

### 14.4 Analytics Pipeline Integration

**On workout completion**:
1. Archive to `users/{uid}/workouts/{workoutId}`
2. Trigger `workout-completed` event
3. Analytics pipeline computes:
   - Weekly volume per muscle group
   - Rolling averages
   - Progression trends
   - e1RM evolution

**Existing endpoints used**:
- `getAnalyticsFeatures` - For post-workout summary
- `getWeeklyStats` - For dashboard
- `getMuscleSeries` - For progression charts

### 14.5 Prior Workout Data

**Fetching last performance**:
```javascript
// Query: most recent workout containing exercise
const lastWorkout = await db.collection(`users/${uid}/workouts`)
  .where('exercise_ids', 'array-contains', exercise_id)
  .orderBy('end_time', 'desc')
  .limit(1)
  .get();

// Extract sets for that exercise
const priorSets = lastWorkout.exercises
  .find(e => e.exercise_id === exercise_id)
  ?.sets;
```

---

## 15. UI/UX Polish Requirements

### 15.1 Visual Feedback & States

**Done state visual hierarchy**:
```
┌────────────────────────────────────────────────────────────────┐
│ PLANNED SET                                                    │
│  • Normal text, empty checkbox                                 │
│  • Full opacity                                                │
├────────────────────────────────────────────────────────────────┤
│ DONE SET                                                       │
│  • Filled green checkbox with checkmark                        │
│  • Subtle green tint on row                                    │
│  • Values become slightly muted (focus shifts to next set)     │
├────────────────────────────────────────────────────────────────┤
│ SKIPPED SET                                                    │
│  • Strikethrough text                                          │
│  • Grey/muted appearance                                       │
│  • Skip icon instead of checkbox                               │
├────────────────────────────────────────────────────────────────┤
│ ACTIVE EDITING                                                 │
│  • Cell highlighted with brand color border                    │
│  • Numeric keypad visible                                      │
│  • Scope selector visible (This / Remaining / All)             │
└────────────────────────────────────────────────────────────────┘
```

### 15.2 Animations & Transitions

| Interaction | Animation |
|-------------|-----------|
| Mark set done | Checkbox fills with scale-up, row slides to muted state |
| Add set | New row slides in from bottom with fade |
| Delete set | Row slides out left, remaining rows collapse smoothly |
| Exercise collapse | Height animates closed, arrow rotates |
| Rest timer complete | Gentle pulse animation on timer bar |

**Animation timing**: Use spring animations with `response: 0.3, dampingFraction: 0.8`

### 15.3 Haptic Feedback

| Action | Haptic |
|--------|--------|
| Mark set done | `.success` (strong, satisfying) |
| Add set | `.light` |
| Delete set | `.medium` |
| Rest timer complete | `.notification(.warning)` |
| AI action complete | `.success` |
| Value increment (+/−) | `.selection` |

### 15.4 Micro-Interactions

**Done button interaction**:
```swift
// Animate done state
withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
    set.status = .done
}
// Haptic
UIImpactFeedbackGenerator(style: .medium).impactOccurred()
// Optional: confetti for PR
if isPR {
    showConfetti()
}
```

**Cell editing**:
- Focus ring appears immediately on tap
- Values update in real-time as typing
- Clear button appears when editing

### 15.5 Accessibility

| Requirement | Implementation |
|-------------|----------------|
| VoiceOver | All cells have descriptive labels ("Set 1, 80 kilograms, 10 reps, 2 RIR, not completed") |
| Dynamic Type | Font sizes scale with system preference |
| Color contrast | All text meets WCAG AA contrast ratios |
| Reduce Motion | Disable animations when preference set |
| Button sizes | Minimum 44×44pt touch targets |

### 15.6 Empty States

**No exercises added**:
```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│                    🏋️ Ready to train?                          │
│                                                                 │
│         [Add Exercise]    [Generate Workout (AI)]               │
│                                                                 │
│    Tip: You can start from a template for faster logging       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 16. Resilience & Crash Recovery

### 16.1 Active Workout Persistence

**Critical**: Active workout must survive app crashes and device restarts.

**Storage layers**:
1. **Firestore** (canonical): `users/{uid}/active_workouts/{id}`
2. **Local cache** (fast resume): UserDefaults/CoreData snapshot

### 16.2 App Launch Recovery Flow

```swift
func onAppLaunch() async {
    // 1. Check for in-progress workout in Firestore
    if let activeWorkout = await fetchActiveWorkout() {
        if activeWorkout.status == .inProgress {
            // 2. Show recovery prompt
            showRecoveryPrompt(activeWorkout)
        }
    }
}

func showRecoveryPrompt(_ workout: ActiveWorkout) {
    // "You have an unfinished workout from 2 hours ago"
    // [Resume]  [Discard]
}
```

### 16.3 Offline Queue

**Pending operations persist to disk**:

```swift
struct PendingOperation: Codable {
    let id: String
    let type: OperationType
    let payload: Data
    let idempotencyKey: String
    let createdAt: Date
    var retryCount: Int
}

class OfflineQueue {
    private let storage: UserDefaults
    private var queue: [PendingOperation] = []
    
    func enqueue(_ operation: PendingOperation) {
        queue.append(operation)
        persistToDisk()
    }
    
    func processWhenOnline() async {
        for op in queue {
            do {
                try await executeOperation(op)
                dequeue(op.id)
            } catch {
                op.retryCount += 1
                if op.retryCount > 3 {
                    // Move to dead letter queue, notify user
                    handleFailedOperation(op)
                }
            }
        }
    }
}
```

### 16.4 Network Loss Handling

**During active workout**:
```swift
func handleNetworkChange(_ isOnline: Bool) {
    if isOnline {
        // Flush pending operations
        Task { await offlineQueue.processWhenOnline() }
    } else {
        // Show subtle offline indicator
        showOfflineIndicator()
        // Continue allowing local edits
    }
}
```

**User experience**:
- Subtle "Offline" badge in header
- All editing continues normally (local-first)
- Operations queue and sync when online
- Conflicts resolved: local edits win

### 16.5 Conflict Resolution

**Last-write-wins with idempotency**:
```javascript
// Server-side
async function applyMutation(workoutId, mutation, idempotencyKey) {
    // 1. Check idempotency
    if (await alreadyProcessed(idempotencyKey)) {
        return getCachedResponse(idempotencyKey);
    }
    
    // 2. Read current state
    const current = await getWorkout(workoutId);
    
    // 3. Apply mutation
    const updated = applyPatch(current, mutation);
    
    // 4. Write with updated_at
    await saveWorkout(updated);
    
    // 5. Cache response
    await cacheIdempotency(idempotencyKey, response);
    
    return response;
}
```

### 16.6 Data Integrity Guarantees

| Scenario | Guarantee |
|----------|-----------|
| App crash mid-edit | Uncommitted edits lost; committed data safe |
| App crash after done tap | Set marked done (idempotent retry) |
| Network loss during sync | Operation queued, retried automatically |
| Conflicting edits | Last-write-wins with idempotency |
| Device restart | Active workout fetched from Firestore |

---

## 17. Scalability Considerations

### 17.1 Firestore Cost Optimization

**Document reads**:
| Operation | Reads | Optimization |
|-----------|-------|--------------|
| Start workout | 1 (template) + 1 (create) | Minimal |
| Log set | 1 (workout) + 1 (write) | Hot path, acceptable |
| Get prior performance | 1 (query) | Cache on workout start |
| Complete workout | 1 (read) + 1 (archive) | Once per session |

**Event subcollection**:
- ~10-50 events per workout
- Cost: negligible for individual users
- Consider TTL cleanup for very old workouts

### 17.2 Rate Limiting

**Per-user limits** (enforced by Firebase Functions):
```javascript
const RATE_LIMITS = {
    logSet: { max: 60, windowSeconds: 60 },      // 60/min (one per second)
    patchActiveWorkout: { max: 120, windowSeconds: 60 },
    startActiveWorkout: { max: 5, windowSeconds: 60 },
    completeActiveWorkout: { max: 5, windowSeconds: 60 }
};
```

### 17.3 Concurrent Access Patterns

**Single-user model**: One user = one active workout at a time.

**Multi-device access** (deferred, not MVP):
- Last-write-wins with updated_at
- Reconciliation on each device foreground
- Consider locking mechanism for MVP+1

### 17.4 Event Subcollection Management

**Growth**: ~30 events per workout × 5 workouts/week = ~150 events/week per user.

**Management**:
- Events are immutable, no updates
- Archive old events with workout on completion
- Consider moving events inline with archived workout for cold storage

### 17.5 Indexes

**Required Firestore indexes**:
```javascript
// For prior performance query
{
  collectionGroup: "workouts",
  fields: [
    { fieldPath: "exercise_ids", order: "ARRAY_CONTAINS" },
    { fieldPath: "end_time", order: "DESCENDING" }
  ]
}

// For active workout query
{
  collection: "active_workouts",
  fields: [
    { fieldPath: "user_id", order: "ASCENDING" },
    { fieldPath: "status", order: "ASCENDING" }
  ]
}
```

### 17.6 Estimated Costs (1000 DAU)

| Metric | Estimate |
|--------|----------|
| Active users/day | 1,000 |
| Workouts/day | ~600 (60% workout rate) |
| Sets logged/day | ~6,000 (10 sets avg) |
| Firestore reads/day | ~50,000 |
| Firestore writes/day | ~20,000 |
| Estimated cost/month | ~$20-50 |

---

## Appendix A: Remaining Work

| Area | Item | Priority |
|------|------|----------|
| iOS | UI polish per design spec (Section 15) | P1 |
| iOS | Offline queue persistence to disk | P2 |
| iOS | Crash recovery flow | P2 |
| Backend | Event subcollection (audit trail) | P2 |
| Backend | Totals recomputation on every mutation | P1 |
| Integration | Copilot tools wiring | P2 |
| Integration | Analytics pipeline trigger on complete | P2 |

### Tests to Add

| ID | Scope | Test Name | What It Proves |
|----|-------|-----------|----------------|
| **T1** | Backend | `logSet_respects_idempotency` | Duplicate keys return cached response |
| **T2** | Backend | `addExercise_idempotent` | Repeated calls with same key create only one exercise |
| **T3** | iOS | `mutation_coordinator_dependency_ordering` | Sets wait for exercise ACK before syncing |
| **T4** | iOS | `session_scoping_prevents_stale_callbacks` | Old session callbacks are ignored |

---

## Appendix B: Related Documentation

- [FIRESTORE_SCHEMA.md](../FIRESTORE_SCHEMA.md) - Full Firestore schema reference
- [FIREBASE_FUNCTIONS_ARCHITECTURE.md](../FIREBASE_FUNCTIONS_ARCHITECTURE.md) - Backend architecture
- [MULTI_AGENT_ARCHITECTURE.md](../MULTI_AGENT_ARCHITECTURE.md) - Agent system design
- [platformvision.md](../platformvision.md) - Product vision and agent boundaries
- [IOS_ARCHITECTURE.md](../IOS_ARCHITECTURE.md) - iOS app architecture
