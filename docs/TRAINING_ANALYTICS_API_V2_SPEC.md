# Token-Safe Training Analytics API v2

> **Version**: 2.0
> **Status**: Current

---

## Table of Contents

1. [Overview](#1-overview)
2. [Data Schemas](#2-data-schemas)
3. [API Endpoints](#3-api-endpoints)
4. [Firestore Indexes](#4-firestore-indexes)
5. [Server Caps & Truncation](#5-server-caps--truncation)
6. [Test Plan](#6-test-plan)
7. [Rollout Plan](#7-rollout-plan)
8. [Cleanup Phase](#8-cleanup-phase)

---

## 1. Overview

### 1.1 Problem Statement

The agent is timing out and losing context when reading training data. Current endpoints return LLM-hostile payloads (nested workouts, unbounded analytics maps). The fix is architectural: make the core primitive one document per completed set ("set facts") with narrow, paginated queries.

### 1.2 Goals

- Prevent agent timeouts via server-enforced caps, pagination, and projection
- Support fast drilldown on muscle groups, muscles, and exercises
- Provide robust progression signals (volume, sets, intensity, effort distribution)
- Enable "How is my chest developing?" queries with 1-2 small calls

### 1.3 Non-Goals

- Not rewriting workout logging schema
- Not building advanced physiological models (just reliable data access primitives)

---

## 2. Data Schemas

### 2.1 Muscle Taxonomy (`utils/muscle-taxonomy.js`)

Canonical muscle groups and muscles with stable IDs.

```javascript
const MUSCLE_GROUPS = {
  chest:      { id: 'chest',      display: 'Chest' },
  back:       { id: 'back',       display: 'Back' },
  shoulders:  { id: 'shoulders',  display: 'Shoulders' },
  arms:       { id: 'arms',       display: 'Arms' },
  core:       { id: 'core',       display: 'Core' },
  legs:       { id: 'legs',       display: 'Legs' },
  glutes:     { id: 'glutes',     display: 'Glutes' },
};

const MUSCLES = {
  // Chest
  pectoralis_major:     { id: 'pectoralis_major',     display: 'Pectoralis Major',     group: 'chest' },
  pectoralis_minor:     { id: 'pectoralis_minor',     display: 'Pectoralis Minor',     group: 'chest' },
  
  // Back
  latissimus_dorsi:     { id: 'latissimus_dorsi',     display: 'Latissimus Dorsi',     group: 'back' },
  rhomboids:            { id: 'rhomboids',            display: 'Rhomboids',            group: 'back' },
  trapezius:            { id: 'trapezius',            display: 'Trapezius',            group: 'back' },
  erector_spinae:       { id: 'erector_spinae',       display: 'Erector Spinae',       group: 'back' },
  teres_major:          { id: 'teres_major',          display: 'Teres Major',          group: 'back' },
  teres_minor:          { id: 'teres_minor',          display: 'Teres Minor',          group: 'back' },
  
  // Shoulders
  deltoid_anterior:     { id: 'deltoid_anterior',     display: 'Front Deltoid',        group: 'shoulders' },
  deltoid_lateral:      { id: 'deltoid_lateral',      display: 'Side Deltoid',         group: 'shoulders' },
  deltoid_posterior:    { id: 'deltoid_posterior',    display: 'Rear Deltoid',         group: 'shoulders' },
  rotator_cuff:         { id: 'rotator_cuff',         display: 'Rotator Cuff',         group: 'shoulders' },
  
  // Arms
  biceps_brachii:       { id: 'biceps_brachii',       display: 'Biceps',               group: 'arms' },
  triceps_brachii:      { id: 'triceps_brachii',      display: 'Triceps',              group: 'arms' },
  brachialis:           { id: 'brachialis',           display: 'Brachialis',           group: 'arms' },
  brachioradialis:      { id: 'brachioradialis',      display: 'Brachioradialis',      group: 'arms' },
  forearms:             { id: 'forearms',             display: 'Forearms',             group: 'arms' },
  
  // Core
  rectus_abdominis:     { id: 'rectus_abdominis',     display: 'Rectus Abdominis',     group: 'core' },
  obliques:             { id: 'obliques',             display: 'Obliques',             group: 'core' },
  transverse_abdominis: { id: 'transverse_abdominis', display: 'Transverse Abdominis', group: 'core' },
  
  // Legs
  quadriceps:           { id: 'quadriceps',           display: 'Quadriceps',           group: 'legs' },
  hamstrings:           { id: 'hamstrings',           display: 'Hamstrings',           group: 'legs' },
  calves:               { id: 'calves',               display: 'Calves',               group: 'legs' },
  adductors:            { id: 'adductors',            display: 'Adductors',            group: 'legs' },
  abductors:            { id: 'abductors',            display: 'Abductors',            group: 'legs' },
  tibialis_anterior:    { id: 'tibialis_anterior',    display: 'Tibialis Anterior',    group: 'legs' },
  
  // Glutes
  gluteus_maximus:      { id: 'gluteus_maximus',      display: 'Gluteus Maximus',      group: 'glutes' },
  gluteus_medius:       { id: 'gluteus_medius',       display: 'Gluteus Medius',       group: 'glutes' },
  gluteus_minimus:      { id: 'gluteus_minimus',      display: 'Gluteus Minimus',      group: 'glutes' },
};

// Mapping from exercise catalog identifiers to canonical IDs
const CATALOG_MUSCLE_MAP = {
  // Map existing catalog values to canonical IDs
  'chest': 'pectoralis_major',
  'pecs': 'pectoralis_major',
  'lats': 'latissimus_dorsi',
  'traps': 'trapezius',
  'biceps': 'biceps_brachii',
  'triceps': 'triceps_brachii',
  'quads': 'quadriceps',
  'hams': 'hamstrings',
  'glutes': 'gluteus_maximus',
  'abs': 'rectus_abdominis',
  // ... additional mappings
};
```

### 2.2 Set Facts Schema

**Collection**: `users/{uid}/set_facts/{set_id}`

**Document ID Format**: `{workoutId}_{exerciseId}_{setIndex}` (deterministic, idempotent)

```typescript
interface SetFact {
  // === Identity ===
  set_id: string;                    // Explicit field (same as doc ID, for cursor tie-breaker)
  user_id: string;
  workout_id: string;
  workout_end_time: Timestamp;       // For sorting
  workout_date: string;              // YYYY-MM-DD for grouping
  exercise_id: string;
  exercise_name: string;
  set_index: number;
  
  // === Set Performance ===
  reps: number;
  weight_kg: number;                 // Always normalized to kg
  rir: number | null;                // 0-5, null if not recorded
  rpe: number | null;                // 5-10, null if not recorded
  is_warmup: boolean;                // Default false
  is_failure: boolean;               // Default false
  volume: number;                    // reps * weight_kg
  
  // === Strength Proxy ===
  e1rm: number | null;               // Computed only when reps <= 12
  e1rm_formula: 'epley' | null;
  e1rm_confidence: number | null;    // 0..1 based on rep range
  
  // === Classification ===
  equipment: string;                 // 'barbell', 'dumbbell', 'cable', 'machine', 'bodyweight'
  movement_pattern: string;          // 'push', 'pull', 'hinge', 'squat', 'lunge', 'carry', 'core'
  is_isolation: boolean;
  side: 'bilateral' | 'unilateral';
  
  // === Attribution Maps (for display/detail) ===
  muscle_group_contrib: Record<string, number>;    // { chest: 0.7, shoulders: 0.3 }
  muscle_contrib: Record<string, number>;          // { pectoralis_major: 0.6, deltoid_anterior: 0.3 }
  effective_volume_by_group: Record<string, number>;
  effective_volume_by_muscle: Record<string, number>;
  hard_set_credit_by_group: Record<string, number>;
  hard_set_credit_by_muscle: Record<string, number>;
  
  // === Filter Arrays (for Firestore queries) ===
  muscle_group_keys: string[];       // ['chest', 'shoulders'] - use array-contains
  muscle_keys: string[];             // ['pectoralis_major', 'deltoid_anterior']
  
  // === Timestamps ===
  created_at: Timestamp;
  updated_at: Timestamp;
}
```

**Hard Set Credit Formula**:
```javascript
function computeHardSetCredit(rir, isWarmup, isFailure) {
  if (isWarmup) return 0;
  if (isFailure || rir === 0) return 1.0;
  if (rir <= 2) return 1.0;
  if (rir <= 4) return 0.5;
  return 0;
}
```

**e1RM Confidence**:
```javascript
function computeE1rmConfidence(reps) {
  if (reps === 1) return 1.0;
  if (reps <= 3) return 0.95;
  if (reps <= 6) return 0.90;
  if (reps <= 10) return 0.80;
  if (reps <= 12) return 0.70;
  return null; // Don't compute e1RM for reps > 12
}
```

### 2.3 Series Schemas

#### 2.3.1 Exercise Series

**Collection**: `users/{uid}/series_exercises/{exercise_id}`

```typescript
interface ExerciseSeries {
  exercise_id: string;
  exercise_name: string;
  
  // Weekly points (last 52 weeks max)
  weeks: Record<string, WeeklyExercisePoint>;  // Key: YYYY-MM-DD (week start)
  
  // Rolling summary
  summary: {
    total_sets: number;
    last_session_date: string;
    best_e1rm_ever: number;
    best_e1rm_date: string;
  };
  
  updated_at: Timestamp;
  schema_version: number;
}

interface WeeklyExercisePoint {
  week_start: string;                // YYYY-MM-DD
  sets: number;                      // Excluding warmups
  hard_sets: number;                 // Sum of hard_set_credit
  volume: number;
  
  // Store raw sums/counts for incremental updates (compute avg on read)
  rir_sum: number;                   // Sum of RIR values
  rir_count: number;                 // Count of sets with RIR recorded
  failure_sets: number;              // Count of failure sets
  set_count: number;                 // Total sets (for failure_rate = failure_sets/set_count)
  
  reps_bucket: {                     // Distribution
    '1-5': number;
    '6-10': number;
    '11-15': number;
    '16-20': number;
  };
  e1rm_max: number | null;           // Best estimated 1RM this week (v1 only, p90 deferred)
}

// Computed on read (not stored):
// avg_rir = rir_sum / rir_count (or null if rir_count === 0)
// failure_rate = failure_sets / set_count
```

#### 2.3.2 Muscle Group Series

**Collection**: `users/{uid}/series_muscle_groups/{muscle_group}`

```typescript
interface MuscleGroupSeries {
  muscle_group: string;              // 'chest', 'back', etc.
  display_name: string;
  
  // Weekly points (last 52 weeks max)
  weeks: Record<string, WeeklyMuscleGroupPoint>;
  
  // Rolling summary
  summary: {
    avg_weekly_volume_8w: number;
    avg_weekly_hard_sets_8w: number;
    trend_slope: number;             // Volume trend (positive = growing)
  };
  
  updated_at: Timestamp;
  schema_version: number;
}

interface WeeklyMuscleGroupPoint {
  week_start: string;
  sets: number;
  hard_sets: number;
  volume: number;
  effective_volume: number;          // Weighted by contribution
  
  // Store raw sums/counts for incremental updates (compute on read)
  rir_sum: number;
  rir_count: number;
  failure_sets: number;
  set_count: number;
  
  reps_bucket: {
    '1-5': number;
    '6-10': number;
    '11-15': number;
    '16-20': number;
  };
}

// Computed on read: avg_rir = rir_sum / rir_count, failure_rate = failure_sets / set_count
```

#### 2.3.3 Muscle Series

**Collection**: `users/{uid}/series_muscles/{muscle}`

```typescript
interface MuscleSeries {
  muscle: string;                    // 'pectoralis_major', 'rhomboids', etc.
  display_name: string;
  muscle_group: string;              // Parent group
  
  // Weekly points (last 52 weeks max)
  weeks: Record<string, WeeklyMusclePoint>;
  
  // Rolling summary
  summary: {
    avg_weekly_effective_volume_8w: number;
    avg_weekly_hard_sets_8w: number;
    trend_slope: number;
  };
  
  updated_at: Timestamp;
  schema_version: number;
}

interface WeeklyMusclePoint {
  week_start: string;
  sets: number;
  hard_sets: number;
  volume: number;
  effective_volume: number;
  
  // Store raw sums/counts for incremental updates (compute on read)
  rir_sum: number;
  rir_count: number;
  failure_sets: number;
  set_count: number;
  
  reps_bucket: {
    '1-5': number;
    '6-10': number;
    '11-15': number;
    '16-20': number;
  };
}

// Computed on read: avg_rir = rir_sum / rir_count, failure_rate = failure_sets / set_count
```

---

## 3. API Endpoints

### 3.1 Standard Response Envelope

All endpoints return this envelope:

```typescript
interface ApiResponse<T> {
  success: boolean;
  data: T;
  next_cursor: string | null;        // Opaque, base64-encoded
  truncated: boolean;                 // True if more results available
  meta: {
    returned: number;                 // Count of items in this response
    limit: number;                    // Requested limit
    response_bytes?: number;          // Approximate response size
  };
}
```

### 3.2 Cursor Encoding

Cursors are opaque base64-encoded JSON:

```typescript
interface CursorPayload {
  sort: string;                       // Must match request sort
  last_workout_end_time: string;      // ISO timestamp
  last_set_id: string;                // Tie-breaker
  version: number;                    // Cursor format version
}

// Encoding
function encodeCursor(payload: CursorPayload): string {
  return Buffer.from(JSON.stringify(payload)).toString('base64url');
}

// Decoding with validation
function decodeCursor(cursor: string, expectedSort: string): CursorPayload | null {
  try {
    const payload = JSON.parse(Buffer.from(cursor, 'base64url').toString());
    if (payload.sort !== expectedSort) return null;  // Invalid for this query
    if (payload.version !== 1) return null;
    return payload;
  } catch {
    return null;
  }
}
```

### 3.3 training.sets.query

**Purpose**: Drill down to raw sets with filters

**File**: `firebase_functions/functions/training/query-sets.js`

**Target Enforcement**: Server enforces exactly one target. Request is rejected if:
- Zero targets provided
- More than one target provided (e.g., both `muscle_group` and `muscle`)

This keeps indexes predictable and prevents accidental "fetch everything" queries.

**Request**:
```typescript
interface QuerySetsRequest {
  // Target filter (EXACTLY ONE required - server enforced)
  target: {
    muscle_group?: string;           // Single muscle group (mutually exclusive)
    muscle?: string;                 // Single muscle (mutually exclusive)
    exercise_ids?: string[];         // Up to 10 exercise IDs (mutually exclusive)
  };
  
  // Date range (required)
  date_range: {
    start: string;                   // YYYY-MM-DD
    end: string;                     // YYYY-MM-DD
  };
  
  // Effort filters
  effort?: {
    include_warmups?: boolean;       // Default: false
    is_failure?: boolean;            // Filter to failure sets only
    rir_min?: number;
    rir_max?: number;
  };
  
  // Performance filters
  performance?: {
    reps_min?: number;
    reps_max?: number;
    weight_min_kg?: number;
    weight_max_kg?: number;
  };
  
  // Pagination
  limit?: number;                    // Default: 50, max: 200
  cursor?: string;                   // From previous response
  
  // Sort (v1 locked to date_desc)
  sort?: 'date_desc';                // Only supported option in v1
  
  // Projection
  fields?: string[];                 // Allowlist, max 20 fields
}
```

**Supported Sort + Filter Combinations (v1)**:

| Sort | Filters | Index Required |
|------|---------|----------------|
| `date_desc` | `muscle_group_keys array-contains` + `workout_end_time desc` | Yes (IDX-1) |
| `date_desc` | `muscle_keys array-contains` + `workout_end_time desc` | Yes (IDX-2) |
| `date_desc` | `exercise_id ==` + `workout_end_time desc` | Yes (IDX-3) |

**Note**: `e1rm_desc` sort is deferred to v2. Use series endpoints for strength trends.

**Response**:
```typescript
interface QuerySetsResponse {
  success: true;
  data: SetFactProjected[];          // Projected fields only
  next_cursor: string | null;
  truncated: boolean;
  meta: {
    returned: number;
    limit: number;
  };
}

interface SetFactProjected {
  set_id: string;
  workout_date: string;
  exercise_id: string;
  exercise_name: string;
  set_index: number;
  reps: number;
  weight_kg: number;
  rir?: number;
  volume: number;
  e1rm?: number;
  // ... other requested fields
}
```

**Fields Allowlist**:
```javascript
const ALLOWED_FIELDS = [
  'set_id', 'workout_id', 'workout_date', 'workout_end_time',
  'exercise_id', 'exercise_name', 'set_index',
  'reps', 'weight_kg', 'rir', 'rpe', 'is_warmup', 'is_failure',
  'volume', 'e1rm', 'e1rm_confidence',
  'equipment', 'movement_pattern', 'is_isolation',
  'muscle_group_keys', 'muscle_keys'
];
```

### 3.4 series.exercise.get

**Purpose**: Get exercise progression series

**File**: `firebase_functions/functions/training/series-exercise.js`

**Request**:
```typescript
interface ExerciseSeriesRequest {
  exercise_id: string;
  window_weeks?: number;             // Default: 12, max: 52
}
```

**Response**:
```typescript
interface ExerciseSeriesResponse {
  success: true;
  data: {
    exercise_id: string;
    exercise_name: string;
    weeks: WeeklyExercisePoint[];    // Capped to window_weeks
    summary: {
      total_sets: number;
      last_session_date: string;
      best_e1rm_ever: number;
      best_e1rm_date: string;
      recent_avg_volume: number;     // Last 4 weeks
      trend_slope: number;
    };
  };
  next_cursor: null;                 // No pagination for series
  truncated: false;
  meta: { returned: number; limit: number; };
}
```

### 3.5 series.muscle_group.get

**Purpose**: Get muscle group development series

**File**: `firebase_functions/functions/training/series-muscle-group.js`

**Request**:
```typescript
interface MuscleGroupSeriesRequest {
  muscle_group: string;              // Canonical ID from taxonomy
  window_weeks?: number;             // Default: 12, max: 52
}
```

**Response**:
```typescript
interface MuscleGroupSeriesResponse {
  success: true;
  data: {
    muscle_group: string;
    display_name: string;
    weeks: WeeklyMuscleGroupPoint[]; // Capped to window_weeks
    summary: {
      avg_weekly_volume_8w: number;
      avg_weekly_hard_sets_8w: number;
      trend_slope: number;
    };
  };
  next_cursor: null;
  truncated: false;
  meta: { returned: number; limit: number; };
}
```

### 3.6 series.muscle.get

**Purpose**: Get individual muscle development series

**File**: `firebase_functions/functions/training/series-muscle.js`

**Request**:
```typescript
interface MuscleSeriesRequest {
  muscle: string;                    // Canonical ID (e.g., 'rhomboids')
  window_weeks?: number;             // Default: 12, max: 52
}
```

**Response**: Same structure as muscle group series.

### 3.7 progress.muscle_group.summary

**Purpose**: Comprehensive muscle group progress for coaching

**File**: `firebase_functions/functions/training/progress-summary.js`

**Request**:
```typescript
interface MuscleGroupSummaryRequest {
  muscle_group: string;
  window_weeks?: number;             // Default: 12, max: 52
  proxy_method?: 'top_volume_exercises' | 'predefined_proxies';
  include_distribution?: boolean;    // Include reps bucket distribution
}
```

**Response**:
```typescript
interface MuscleGroupSummaryResponse {
  success: true;
  data: {
    muscle_group: string;
    display_name: string;
    
    // Weekly series (bounded)
    weekly_series: WeeklyMuscleGroupPoint[];
    
    // Top exercises (capped at 5)
    top_exercises: {
      exercise_id: string;
      exercise_name: string;
      total_effective_volume: number;
      sessions: number;
    }[];
    
    // Proxy trends (capped at 3)
    proxy_trends: {
      exercise_id: string;
      exercise_name: string;
      recent_e1rm: number;
      e1rm_trend: number;            // Slope
    }[];
    
    // Deterministic flags
    flags: {
      plateau: boolean;              // e1RM flat 4 weeks + volume unchanged
      deload: boolean;               // Volume drop >40% WoW
      overreach: boolean;            // failure_rate >35%, rising volume, avg_rir near 0
    };
    
    // Distribution (if requested)
    reps_distribution?: {
      '1-5': number;
      '6-10': number;
      '11-15': number;
      '16-20': number;
    };
  };
  next_cursor: null;
  truncated: false;
  meta: { returned: 1; limit: 1; };
}
```

### 3.8 progress.muscle.summary

Same as muscle group summary but for individual muscles.

### 3.9 progress.exercise.summary

**Request**:
```typescript
interface ExerciseSummaryRequest {
  exercise_id: string;
  window_weeks?: number;
}
```

**Response**:
```typescript
interface ExerciseSummaryResponse {
  success: true;
  data: {
    exercise_id: string;
    exercise_name: string;
    
    // Weekly series
    weekly_series: WeeklyExercisePoint[];
    
    // Last session recap (cap 3 sets)
    last_session: {
      date: string;
      sets: { reps: number; weight_kg: number; rir?: number; e1rm?: number; }[];
    };
    
    // PRs
    prs: {
      all_time_e1rm: number;
      all_time_e1rm_date: string;
      window_e1rm: number;
      window_e1rm_date: string;
    };
    
    // Flags
    flags: {
      plateau: boolean;
      pr_this_week: boolean;
    };
  };
  next_cursor: null;
  truncated: false;
  meta: { returned: 1; limit: 1; };
}
```

### 3.10 context.coaching.pack

**Purpose**: Single small call for initial agent context

**File**: `firebase_functions/functions/training/context-pack.js`

**Request**:
```typescript
interface CoachingPackRequest {
  window_weeks?: number;             // Default: 8
  top_n_targets?: number;            // Default: 6
}
```

**Response**:
```typescript
interface CoachingPackResponse {
  success: true;
  data: {
    // Top muscle groups by effective volume
    top_muscle_groups: {
      muscle_group: string;
      display_name: string;
      weekly_effective_volume: number[];  // Last 8 weeks
      weekly_hard_sets: number[];
      avg_rir: number;
      top_exercises: { id: string; name: string; }[];  // Cap 3
    }[];
    
    // Adherence
    adherence: {
      sessions_per_week_target: number;
      sessions_per_week_actual: number;
      consistency_score: number;         // 0-1
    };
    
    // Change flags
    alerts: {
      volume_drop_groups: string[];      // Groups with >30% drop
      high_failure_rate_groups: string[];
      low_frequency: boolean;
    };
  };
  next_cursor: null;
  truncated: false;
  meta: { returned: 1; limit: 1; response_bytes: number; };
}
```

**Hard Cap**: Response must be under 15 KB.

### 3.11 active.snapshotLite

**Purpose**: Minimal active workout state

**File**: `firebase_functions/functions/training/active-snapshot.js`

**Request**: (GET, no body needed)

**Response**:
```typescript
interface ActiveSnapshotResponse {
  success: true;
  data: {
    workout_id: string;
    status: 'in_progress' | 'completed' | 'cancelled';
    start_time: string;
    current_exercise_id: string;
    current_exercise_name: string;
    next_set_index: number;
    totals: {
      sets: number;
      reps: number;
      volume: number;
    };
  } | null;                          // null if no active workout
  next_cursor: null;
  truncated: false;
  meta: { returned: 1; limit: 1; };
}
```

### 3.12 active.events.list

**Purpose**: Paginated workout events

**File**: `firebase_functions/functions/training/active-events.js`

**Request**:
```typescript
interface ActiveEventsRequest {
  workout_id: string;
  after_version?: number;            // Event version cursor
  after_timestamp?: string;          // ISO timestamp cursor
  limit?: number;                    // Default: 20, max: 50
}
```

**Response**:
```typescript
interface ActiveEventsResponse {
  success: true;
  data: {
    type: string;
    payload: any;
    version: number;
    created_at: string;
  }[];
  next_cursor: string | null;
  truncated: boolean;
  meta: { returned: number; limit: number; };
}
```

---

## 4. Firestore Indexes

### 4.1 Required Composite Indexes

Add to `firebase_functions/firestore.indexes.json`:

```json
{
  "indexes": [
    {
      "collectionGroup": "set_facts",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "muscle_group_keys", "arrayConfig": "CONTAINS" },
        { "fieldPath": "workout_end_time", "order": "DESCENDING" },
        { "fieldPath": "set_id", "order": "DESCENDING" }
      ]
    },
    {
      "collectionGroup": "set_facts",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "muscle_keys", "arrayConfig": "CONTAINS" },
        { "fieldPath": "workout_end_time", "order": "DESCENDING" },
        { "fieldPath": "set_id", "order": "DESCENDING" }
      ]
    },
    {
      "collectionGroup": "set_facts",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "exercise_id", "order": "ASCENDING" },
        { "fieldPath": "workout_end_time", "order": "DESCENDING" },
        { "fieldPath": "set_id", "order": "DESCENDING" }
      ]
    },
    {
      "collectionGroup": "set_facts",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "workout_date", "order": "DESCENDING" },
        { "fieldPath": "set_id", "order": "DESCENDING" }
      ]
    }
  ]
}
```

### 4.2 Index Usage Reference

| Index ID | Query Pattern | Endpoint |
|----------|--------------|----------|
| IDX-1 | `muscle_group_keys array-contains X` + `workout_end_time desc` | `training.sets.query` |
| IDX-2 | `muscle_keys array-contains X` + `workout_end_time desc` | `training.sets.query` |
| IDX-3 | `exercise_id == X` + `workout_end_time desc` | `training.sets.query` |
| IDX-4 | `workout_date desc` | Date range queries |

---

## 5. Server Caps & Truncation

### 5.1 Universal Caps

```javascript
const CAPS = {
  // Pagination
  DEFAULT_LIMIT: 50,
  MAX_LIMIT: 200,
  
  // Projection
  MAX_FIELDS: 20,
  
  // Response size
  MAX_RESPONSE_BYTES: 32768,        // 32 KB hard limit
  TARGET_RESPONSE_BYTES: 15360,     // 15 KB target for summaries
  
  // Series
  MAX_WEEKS: 52,
  DEFAULT_WEEKS: 12,
  
  // Lists
  MAX_TOP_EXERCISES: 5,
  MAX_PROXY_TRENDS: 3,
  MAX_EXERCISE_IDS_FILTER: 10,
};
```

### 5.2 Enforcement Implementation

```javascript
/**
 * Server-side cap enforcement for all training endpoints
 */
function enforceQueryCaps(request) {
  // Clamp limit
  const limit = Math.min(
    Math.max(1, request.limit || CAPS.DEFAULT_LIMIT),
    CAPS.MAX_LIMIT
  );
  
  // Validate and clamp fields
  const fields = (request.fields || [])
    .filter(f => ALLOWED_FIELDS.includes(f))
    .slice(0, CAPS.MAX_FIELDS);
  
  // Clamp weeks
  const weeks = Math.min(
    Math.max(1, request.window_weeks || CAPS.DEFAULT_WEEKS),
    CAPS.MAX_WEEKS
  );
  
  // Validate exercise_ids length
  if (request.target?.exercise_ids?.length > CAPS.MAX_EXERCISE_IDS_FILTER) {
    throw new Error(`exercise_ids exceeds max ${CAPS.MAX_EXERCISE_IDS_FILTER}`);
  }
  
  return { limit, fields, weeks };
}

/**
 * Response size check with truncation
 */
function buildResponse(data, limit, hasMore) {
  const serialized = JSON.stringify(data);
  const responseBytes = Buffer.byteLength(serialized, 'utf8');
  
  let truncated = hasMore;
  let finalData = data;
  
  // If response exceeds max, truncate data array
  if (responseBytes > CAPS.MAX_RESPONSE_BYTES && Array.isArray(data)) {
    // Binary search for safe length
    let lo = 1, hi = data.length;
    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2);
      const testSize = Buffer.byteLength(JSON.stringify(data.slice(0, mid)), 'utf8');
      if (testSize <= CAPS.MAX_RESPONSE_BYTES) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    finalData = data.slice(0, lo);
    truncated = true;
  }
  
  return {
    success: true,
    data: finalData,
    next_cursor: truncated ? encodeCursor(...) : null,
    truncated,
    meta: {
      returned: Array.isArray(finalData) ? finalData.length : 1,
      limit,
      response_bytes: Buffer.byteLength(JSON.stringify(finalData), 'utf8'),
    },
  };
}
```

### 5.3 Per-Endpoint Caps

| Endpoint | Max Items | Max Bytes | Notes |
|----------|-----------|-----------|-------|
| `training.sets.query` | 200 | 32 KB | Paginated |
| `series.*.get` | 52 weeks | 10 KB | Single doc read |
| `progress.*.summary` | 1 | 15 KB | Computed summary |
| `context.coaching.pack` | 1 | 15 KB | Agent context |
| `active.snapshotLite` | 1 | 2 KB | Minimal state |
| `active.events.list` | 50 | 16 KB | Paginated |

---

## 6. Test Plan

### 6.1 Unit Tests

**File**: `firebase_functions/functions/tests/training/`

```javascript
// test-set-facts-generator.js
describe('SetFactsGenerator', () => {
  it('generates deterministic set_id', () => {...});
  it('computes e1rm only for reps <= 12', () => {...});
  it('computes hard_set_credit correctly', () => {...});
  it('populates muscle_group_keys from contrib map', () => {...});
  it('populates muscle_keys from contrib map', () => {...});
  it('normalizes weight to kg', () => {...});
});

// test-series-builder.js
describe('SeriesBuilder', () => {
  it('aggregates weekly points correctly', () => {...});
  it('updates all affected series in batch', () => {...});
  it('handles concurrent updates via transactions', () => {...});
  it('caps weeks at 52', () => {...});
});

// test-query-caps.js
describe('QueryCaps', () => {
  it('clamps limit to max 200', () => {...});
  it('filters fields to allowlist', () => {...});
  it('rejects unknown sort modes', () => {...});
  it('validates cursor against sort mode', () => {...});
});
```

### 6.2 Golden Size Tests

**Critical**: Tests that fail if response exceeds caps.

```javascript
// test-response-sizes.js
describe('Response Size Limits', () => {
  it('training.sets.query response under 32KB', async () => {
    const response = await querySets({ limit: 200 });
    const size = Buffer.byteLength(JSON.stringify(response), 'utf8');
    expect(size).toBeLessThan(32768);
  });
  
  it('progress.muscle_group.summary under 15KB', async () => {
    const response = await getMuscleGroupSummary({ muscle_group: 'chest' });
    const size = Buffer.byteLength(JSON.stringify(response), 'utf8');
    expect(size).toBeLessThan(15360);
  });
  
  it('context.coaching.pack under 15KB', async () => {
    const response = await getCoachingPack({});
    const size = Buffer.byteLength(JSON.stringify(response), 'utf8');
    expect(size).toBeLessThan(15360);
  });
  
  it('active.snapshotLite under 2KB', async () => {
    const response = await getActiveSnapshotLite();
    const size = Buffer.byteLength(JSON.stringify(response), 'utf8');
    expect(size).toBeLessThan(2048);
  });
});
```

### 6.3 Integration Tests

```javascript
// test-workout-to-set-facts.js
describe('Workout Completion → Set Facts', () => {
  it('trigger creates set_facts for all completed sets', async () => {...});
  it('trigger updates series_exercises', async () => {...});
  it('trigger updates series_muscle_groups', async () => {...});
  it('trigger updates series_muscles', async () => {...});
  it('set_facts are queryable by muscle_group_keys', async () => {...});
});
```

---

## 7. Rollout Plan

### 7.1 Phase 1: Data Layer (Week 1)

1. **Deploy muscle taxonomy**
   - Create `firebase_functions/functions/utils/muscle-taxonomy.js`
   - No breaking changes

2. **Deploy set_facts trigger (idempotent)**
   - Modify `triggers/weekly-analytics.js` to also write set_facts
   - Uses deterministic `set_id` for upserts
   - New workouts start generating set_facts immediately

3. **Deploy series updates**
   - Enhance `utils/analytics-writes.js` with new series collections
   - Update triggers to write to `series_muscle_groups`, `series_muscles`

4. **Deploy Firestore indexes**
   - Add composite indexes to `firestore.indexes.json`
   - `firebase deploy --only firestore:indexes`
   - Wait for index build (may take hours for large collections)

### 7.2 Phase 2: Backfill (Week 1-2)

1. **Deploy backfill Cloud Run job**
   - `firebase_functions/functions/scripts/backfill-set-facts.js`
   - Processes historical workouts in batches of 100
   - Uses watermarking to resume on failure
   - Idempotent: safe to re-run

2. **Run backfill**
   ```bash
   gcloud run jobs execute backfill-set-facts \
     --region=us-central1 \
     --args="--start-date=2023-01-01"
   ```

3. **Validate backfill**
   - Spot check set_facts counts vs workout counts
   - Verify series summaries match expected values

### 7.3 Phase 3: New Endpoints (Week 2)

1. **Deploy new training endpoints**
   - `training.sets.query`
   - `series.exercise.get`
   - `series.muscle_group.get`
   - `series.muscle.get`

2. **Deploy summary endpoints**
   - `progress.muscle_group.summary`
   - `progress.muscle.summary`
   - `progress.exercise.summary`
   - `context.coaching.pack`

3. **Deploy active workout safety endpoints**
   - `active.snapshotLite`
   - `active.events.list`

4. **Smoke test all endpoints**

### 7.4 Phase 4: Agent Tool Switch (Week 3)

1. **Add new agent tools**
   - `tool_get_muscle_group_progress`
   - `tool_get_muscle_progress`
   - `tool_get_exercise_progress`
   - `tool_query_sets`
   - `tool_get_coaching_context`

2. **Update agent instructions**
   - Prefer series endpoints for default reasoning
   - Use set queries only for drilldown
   - Use context pack as initial call

3. **Gradual rollout**
   - Enable for test users first
   - Monitor token usage and latency
   - Full rollout after validation

### 7.5 Phase 5: Cleanup (Week 4)

See Section 8.

---

## 8. Cleanup Phase

### 8.1 Remove from Agent Tool Surface

**Tools to Remove**:
| Tool | Replacement |
|------|-------------|
| `tool_get_analytics_features` | `tool_get_muscle_group_progress`, `tool_get_coaching_context` |
| `tool_get_planning_context` | `tool_get_coaching_context` |
| `tool_get_recent_workouts` | `tool_query_sets` (with filters) |

### 8.2 Deprecation Steps

1. **Mark endpoints as deprecated**
   ```javascript
   // In get-features.js
   console.warn('DEPRECATED: getAnalyticsFeatures - use training.sets.query or series endpoints');
   res.setHeader('X-Deprecated', 'true');
   res.setHeader('X-Replacement', 'series.muscle_group.get, context.coaching.pack');
   ```

2. **Remove from agent tools.py**
   ```python
   # REMOVED - was causing agent timeouts
   # def tool_get_analytics_features(...):
   #     ...
   
   # REMOVED - replaced by context.coaching.pack
   # def tool_get_planning_context(...):
   #     ...
   ```

3. **Update CanvasFunctionsClient**
   - Add new endpoint methods
   - Keep old methods for app compatibility
   - Mark old methods as `@deprecated`

### 8.3 Grep Checklist

Run these to find remaining usages:

```bash
# Agent code
grep -r "get_analytics_features" adk_agent/
grep -r "get_planning_context" adk_agent/
grep -r "get_recent_workouts" adk_agent/
grep -r "tool_get_analytics_features" adk_agent/
grep -r "tool_get_planning_context" adk_agent/

# Firebase functions
grep -r "getAnalyticsFeatures" firebase_functions/
grep -r "getPlanningContext" firebase_functions/

# iOS app (if applicable)
grep -r "getAnalyticsFeatures" Povver/
grep -r "getPlanningContext" Povver/
```

### 8.4 Documentation Updates

1. Update `docs/FIRESTORE_SCHEMA.md`
   - Add `set_facts` collection
   - Add `series_muscle_groups` collection
   - Add `series_muscles` collection

2. Update `docs/SHELL_AGENT_ARCHITECTURE.md`
   - Document new tool surface
   - Document deprecations

3. Update `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
   - Add new training endpoints
   - Mark deprecated endpoints

---

## 9. Series Update Strategy (Write Amplification Avoidance)

### 9.1 Batch Updates on Workout Completion

```javascript
/**
 * On workout completion, compute all weekly aggregates in memory
 * then batch update series docs with individual FieldValue.increment per field.
 * 
 * This avoids per-set write amplification.
 */
async function updateSeriesOnWorkoutComplete(userId, workout, increment = 1) {
  const weekId = getWeekStart(workout.end_time);
  
  // Aggregate in memory: accumulate deltas per target
  const exerciseDeltas = new Map();      // exercise_id -> { sets, volume, hard_sets, ... }
  const muscleGroupDeltas = new Map();   // group_id -> { sets, volume, ... }
  const muscleDeltas = new Map();        // muscle_id -> { sets, volume, ... }
  
  for (const ex of workout.exercises) {
    for (const set of ex.sets) {
      if (!set.is_completed) continue;
      if (set.is_warmup) continue;  // Skip warmups for aggregation
      
      const setFact = computeSetFact(set, ex);
      
      // Aggregate to exercise
      accumulateDelta(exerciseDeltas, ex.exercise_id, {
        sets: 1,
        hard_sets: setFact.hard_set_credit,
        volume: setFact.volume,
        rir_sum: setFact.rir ?? 0,
        rir_count: setFact.rir !== null ? 1 : 0,
        failure_sets: setFact.is_failure ? 1 : 0,
        set_count: 1,
        e1rm_max: setFact.e1rm,  // Handle max specially
        reps_bucket: getRepsBucket(setFact.reps),
      });
      
      // Aggregate to muscle groups
      for (const [group, contrib] of Object.entries(setFact.muscle_group_contrib)) {
        accumulateDelta(muscleGroupDeltas, group, {
          sets: 1,
          hard_sets: setFact.hard_set_credit * contrib,
          volume: setFact.volume * contrib,
          effective_volume: setFact.volume * contrib,
          rir_sum: (setFact.rir ?? 0) * contrib,
          rir_count: setFact.rir !== null ? 1 : 0,
          failure_sets: setFact.is_failure ? 1 : 0,
          set_count: 1,
          reps_bucket: getRepsBucket(setFact.reps),
        });
      }
      
      // Aggregate to muscles
      for (const [muscle, contrib] of Object.entries(setFact.muscle_contrib)) {
        accumulateDelta(muscleDeltas, muscle, {
          sets: 1,
          hard_sets: setFact.hard_set_credit * contrib,
          volume: setFact.volume * contrib,
          effective_volume: setFact.volume * contrib,
          rir_sum: (setFact.rir ?? 0) * contrib,
          rir_count: setFact.rir !== null ? 1 : 0,
          failure_sets: setFact.is_failure ? 1 : 0,
          set_count: 1,
          reps_bucket: getRepsBucket(setFact.reps),
        });
      }
    }
  }
  
  // Collect all batch operations
  const operations = [];
  
  for (const [exerciseId, delta] of exerciseDeltas) {
    operations.push({
      ref: db.collection('users').doc(userId).collection('series_exercises').doc(exerciseId),
      weekId,
      delta,
      hasE1rmMax: true,
    });
  }
  
  for (const [group, delta] of muscleGroupDeltas) {
    operations.push({
      ref: db.collection('users').doc(userId).collection('series_muscle_groups').doc(group),
      weekId,
      delta,
      hasE1rmMax: false,
    });
  }
  
  for (const [muscle, delta] of muscleDeltas) {
    operations.push({
      ref: db.collection('users').doc(userId).collection('series_muscles').doc(muscle),
      weekId,
      delta,
      hasE1rmMax: false,
    });
  }
  
  // Write in chunks (Firestore batch limit = 500 operations)
  await writeOperationsInChunks(operations, weekId, increment);
}

/**
 * Chunk operations to respect Firestore batch limit (500 ops per batch)
 */
async function writeOperationsInChunks(operations, weekId, increment = 1) {
  const BATCH_LIMIT = 500;
  const sign = increment >= 0 ? 1 : -1;
  
  for (let i = 0; i < operations.length; i += BATCH_LIMIT) {
    const chunk = operations.slice(i, i + BATCH_LIMIT);
    const batch = db.batch();
    
    for (const op of chunk) {
      const { ref, delta, hasE1rmMax } = op;
      
      // Build update object with individual FieldValue.increment() calls
      const update = {
        [`weeks.${weekId}.sets`]: FieldValue.increment(delta.sets * sign),
        [`weeks.${weekId}.hard_sets`]: FieldValue.increment(delta.hard_sets * sign),
        [`weeks.${weekId}.volume`]: FieldValue.increment(delta.volume * sign),
        [`weeks.${weekId}.rir_sum`]: FieldValue.increment(delta.rir_sum * sign),
        [`weeks.${weekId}.rir_count`]: FieldValue.increment(delta.rir_count * sign),
        [`weeks.${weekId}.failure_sets`]: FieldValue.increment(delta.failure_sets * sign),
        [`weeks.${weekId}.set_count`]: FieldValue.increment(delta.set_count * sign),
        [`weeks.${weekId}.reps_bucket.1-5`]: FieldValue.increment((delta.reps_bucket['1-5'] || 0) * sign),
        [`weeks.${weekId}.reps_bucket.6-10`]: FieldValue.increment((delta.reps_bucket['6-10'] || 0) * sign),
        [`weeks.${weekId}.reps_bucket.11-15`]: FieldValue.increment((delta.reps_bucket['11-15'] || 0) * sign),
        [`weeks.${weekId}.reps_bucket.16-20`]: FieldValue.increment((delta.reps_bucket['16-20'] || 0) * sign),
        updated_at: FieldValue.serverTimestamp(),
      };
      
      // effective_volume for muscle/muscle_group series
      if (delta.effective_volume !== undefined) {
        update[`weeks.${weekId}.effective_volume`] = FieldValue.increment(delta.effective_volume * sign);
      }
      
      batch.set(ref, update, { merge: true });
      
      // e1rm_max requires transaction for proper max tracking (see 9.3)
      // For simplicity in v1, we skip e1rm_max on negative increments (delete)
      // and rely on backfill job for recalculation if needed
    }
    
    await batch.commit();
  }
}
```

### 9.2 e1RM Max Handling

For `e1rm_max`, we cannot use `FieldValue.increment()` since it's a max, not a sum.

**v1 Approach (simple)**:
- On workout create: use transaction to compare and update if new e1rm > stored max
- On workout delete: do not decrement e1rm_max (would require recalculation)
- Periodic nightly job recalculates e1rm_max from set_facts if drift is suspected

```javascript
// e1rm_max update via transaction (on create only)
async function updateE1rmMax(userId, exerciseId, weekId, newE1rm) {
  if (newE1rm === null) return;
  
  const ref = db.collection('users').doc(userId)
    .collection('series_exercises').doc(exerciseId);
  
  await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const currentMax = doc.data()?.weeks?.[weekId]?.e1rm_max || 0;
    
    if (newE1rm > currentMax) {
      tx.set(ref, {
        [`weeks.${weekId}.e1rm_max`]: newE1rm,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  });
}
```

### 9.3 Workout Delete Handling

**Decision**: Completed workouts support deletion. On delete, we apply negative increments.

```javascript
/**
 * On workout delete, apply negative increments to all affected series.
 * Uses the same updateSeriesOnWorkoutComplete with increment = -1.
 */
exports.onWorkoutDeleted = onDocumentDeleted(
  'users/{userId}/workouts/{workoutId}',
  async (event) => {
    const workout = event.data.data();
    if (!workout || !workout.end_time) return null;
    
    const userId = event.params.userId;
    
    // Delete all set_facts for this workout
    const setFactsQuery = db
      .collection('users').doc(userId)
      .collection('set_facts')
      .where('workout_id', '==', event.params.workoutId);
    
    const setFactsSnap = await setFactsQuery.get();
    const deleteOps = setFactsSnap.docs.map(doc => doc.ref.delete());
    
    // Chunk deletes
    for (let i = 0; i < deleteOps.length; i += 500) {
      await Promise.all(deleteOps.slice(i, i + 500));
    }
    
    // Apply negative increments to series
    await updateSeriesOnWorkoutComplete(userId, workout, -1);
    
    // Note: e1rm_max is NOT decremented (see 9.2)
    // If accurate e1rm_max is critical after deletes, run recalculation job
  }
);
```

### 9.4 Set Facts Chunking

```javascript
/**
 * Write set_facts in chunks to avoid batch limit
 */
async function writeSetFactsInChunks(userId, setFacts) {
  const BATCH_LIMIT = 500;
  
  for (let i = 0; i < setFacts.length; i += BATCH_LIMIT) {
    const chunk = setFacts.slice(i, i + BATCH_LIMIT);
    const batch = db.batch();
    
    for (const sf of chunk) {
      const ref = db.collection('users').doc(userId)
        .collection('set_facts').doc(sf.set_id);
      batch.set(ref, sf, { merge: true });
    }
    
    await batch.commit();
  }
}
```

---

## 10. File Summary

### New Files to Create

| File | Purpose |
|------|---------|
| `firebase_functions/functions/utils/muscle-taxonomy.js` | Canonical muscle groups/muscles |
| `firebase_functions/functions/training/set-facts-generator.js` | Core set_facts logic |
| `firebase_functions/functions/training/query-sets.js` | `training.sets.query` |
| `firebase_functions/functions/training/series-exercise.js` | `series.exercise.get` |
| `firebase_functions/functions/training/series-muscle-group.js` | `series.muscle_group.get` |
| `firebase_functions/functions/training/series-muscle.js` | `series.muscle.get` |
| `firebase_functions/functions/training/progress-summary.js` | Progress summary endpoints |
| `firebase_functions/functions/training/context-pack.js` | `context.coaching.pack` |
| `firebase_functions/functions/training/active-snapshot.js` | `active.snapshotLite` |
| `firebase_functions/functions/training/active-events.js` | `active.events.list` |
| `firebase_functions/functions/scripts/backfill-set-facts.js` | Historical backfill |
| `firebase_functions/functions/tests/training/*.js` | Test files |

### Files to Modify

| File | Changes |
|------|---------|
| `firebase_functions/functions/triggers/weekly-analytics.js` | Add set_facts generation |
| `firebase_functions/functions/utils/analytics-writes.js` | Add series_muscle_groups, series_muscles writes |
| `firebase_functions/functions/index.js` | Export new endpoints |
| `firebase_functions/firestore.indexes.json` | Add composite indexes |
| `adk_agent/canvas_orchestrator/app/shell/tools.py` | Add new tools, remove old |
| `adk_agent/canvas_orchestrator/app/skills/coach_skills.py` | Add new skill functions |
| `adk_agent/canvas_orchestrator/app/libs/tools_canvas/client.py` | Add new endpoint methods |

---

## 11. Authentication & Authorization

All training analytics endpoints use bearer-lane auth. See `docs/SECURITY.md` → "Authentication Model" for the authoritative reference on auth lanes and IDOR prevention.

All public endpoints derive `userId` from `request.auth.uid` (Firebase Auth token), never from request body. Backfill jobs use service account iteration. Triggers use `event.params.userId` from Firestore document paths.

---

**End of Training Analytics API v2 Spec**
