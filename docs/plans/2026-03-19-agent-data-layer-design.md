# Agent-Optimized Data Layer Design

**Date:** 2026-03-19
**Status:** Draft
**Problem:** Agents answering user questions about training data require 7-20 tool calls and 15-65K input tokens for common questions. The shared business logic layer returns full Firestore documents with no projection support, and exercise/template names are inconsistently denormalized, forcing agents into N+1 lookup chains.

---

## Context

### The Core Problem

The shared business logic modules (`firebase_functions/functions/shared/`) were designed for a UI client that caches and renders. They return full Firestore documents — every set, every analytics breakdown, every exercise catalog field. This worked fine when the only consumer was the iOS app making one-shot reads with client-side caching.

Now there are three consumers:

1. **iOS app** — needs full documents for CRUD views. Well-served by current layer.
2. **MCP server** — serves external AI agents. Token-constrained (~4-8K per response). Currently overflows on 6 of 15 endpoints.
3. **Internal agent service** — serves the in-app AI coach. Has its own Python Firestore client (`firestore_client.py`) that reimplements data access from scratch, missing features the shared JS modules have (exercise name resolution, flexible query filtering, projection modes).

The MCP server and agent service have independently implemented summarization logic for the same data:

| Summarization | MCP (TypeScript) | Agent Service (Python) |
|---|---|---|
| Workout summary | `summarizeWorkout()` in tools.ts | `list_recent_workouts()` in firestore_client.py |
| Template summary | `list_templates` mapping in tools.ts | `list_templates(include_exercises=False)` in firestore_client.py |
| Planning snapshot | `compactSnapshot()` in tools.ts | `get_planning_context()` in firestore_client.py |

Three implementations of the same shapes. They drift silently. Schema changes must be propagated to three codebases.

### Exercise Name Gap

Template documents store exercises with `exercise_id` but `name` is optional. Whether `name` is present depends on how the template was created:

| Write Path | exercise_name persisted? |
|---|---|
| `createTemplate()` / `patchTemplate()` | Only if caller provides it |
| `convertPlanBlockToTemplateExercise()` (5 write paths) | Never |
| iOS app direct creation | Usually yes |

`getTemplate()` patches this gap at read time with `resolveExerciseNames()` (N+1 catalog reads). `listTemplates()` does not resolve names. The Python agent service never resolves names.

Result: an agent asking "what does my routine look like?" gets opaque IDs like `K21gndDYgWE25mFmPamH` instead of "Chest Press (Machine)" — and there's no reliable single-call way to resolve them.

### Template Name Gap

Routines store `template_ids` (array of strings). No routine write path stores template names. Every consumer that displays routine contents must make N additional template reads.

---

## Design

### Principles

1. **Fix data at the source.** Denormalize names at write time so every consumer — JS, Python, iOS, future — gets complete data from the document itself.
2. **Project at the shared layer.** Summary shapes are defined once in the shared modules, not reinvented by each consumer.
3. **Consumers become thin.** MCP tools.ts and agent service tools become wrappers that call shared functions with the right view parameter.
4. **iOS keeps full access.** No changes to iOS data paths. iOS benefits from denormalization (names always present) but doesn't need projection changes.
5. **Pipeline consumers unchanged.** set_facts generator, training analyst, Firestore triggers continue reading full documents. They're data producers, not token-constrained readers.

### Non-Goals

- Changing the iOS app's data access patterns (future optimization, separate project)
- Building new composite endpoints like `answer_question` (premature — get the fundamentals right first)
- Migrating the training analyst to shared modules (it reads pre-aggregated pipeline collections, not the CRUD layer)
- Migrating agent service Python reads to HTTP (separate spec — see Investment 3; the denormalization and projection work delivers value independently)
- Resolving duplicate exercise IDs or muscle group casing inconsistency (data quality issues, separate project)
- Normalizing `exercise_name` vs `name` on analytics_series documents (deferred to data quality project)

---

## Investment 1: Write-Time Denormalization

### 1a. Exercise Names on Templates

**Change:** When an exercise is added to a template via any write path, resolve and persist `name` from the exercise catalog alongside `exercise_id`.

**Implementation:**

1. **`convertPlanBlockToTemplateExercise()`** (`utils/plan-to-template-converter.js`):
   - Pass through `name` from the block if present (e.g., `block.exercise_name` or `block.name`). Currently the converter extracts only `exercise_id`, `position`, `sets`, `rest_between_sets` — it drops any name field even if the caller provides one.
   - The higher-level wrapper `convertPlanToTemplate()` also needs to propagate `name` from workout plan blocks.
   - This covers 5 write paths that use the converter: `createTemplateFromPlan`, `createRoutineFromDraftCore`, `saveRoutine`, `saveTemplate`, `saveAsNew` (artifacts).
   - Note: plan blocks may or may not have a name field depending on the source. The converter should pass it through when available; the catalog batch resolution in `createTemplate()` (below) serves as the catch-all.

2. **`createTemplate()`** (`shared/templates.js`):
   - After validation, check each exercise. If `exercise_id` is present but `name` is missing, batch-resolve names from the `exercises` catalog collection using `db.getAll(...refs)` (true batch read, not N parallel individual reads).

3. **`patchTemplate()`** (`shared/templates.js`):
   - When `exercises` array is in the patch, apply the same batch resolution for any exercise missing `name`.

4. **Backfill script** (`scripts/backfill_template_exercise_names.js`):
   - Read all templates across all users.
   - For each template with exercises missing `name`, resolve from catalog via `db.getAll()` and batch-update.
   - Idempotent, safe to re-run.

**Other template write paths (safe, no changes needed):**
- `syncTemplateWeightsFromWorkout()` (`active_workout/complete-active-workout.js`): Only modifies `weight` values on existing sets. Reads the exercises array and writes it back with updated weights — existing `name` fields are preserved. Safe only if backfill runs first (otherwise writes back exercises without names).
- `applyChangesToTarget()` (`shared/progressions.js`): Applies path-based changes (e.g., `exercises[0].sets[0].reps`). Writes back the full document after applying the patch — existing `name` fields are preserved.

**Staleness:** Exercise catalog names are effectively immutable (we control the catalog, names don't change). No staleness propagation mechanism needed. If a name ever changes, a one-time backfill script updates affected templates.

**After this change:** `resolveExerciseNames()` in `getTemplate()` becomes a no-op for any template written after the fix. It remains as a fallback for templates not yet backfilled.

### 1b. Template Names on Routines

**Change:** Add a `template_names` field to routine documents: `{templateId: "Workout A1", ...}`.

**Implementation:**

1. **`createRoutine()`** (`shared/routines.js`):
   - This function already calls `db.getAll(...templateRefs)` to validate template existence. Reuse the already-fetched template docs to extract names — no additional Firestore reads needed.
   - Persist `template_names` map on the routine document.

2. **`patchRoutine()`** (`shared/routines.js`):
   - When `template_ids` changes, batch-read new template docs and re-resolve template names.
   - Update `template_names` map.

3. **`createRoutineFromDraftCore()`** (`routines/create-routine-from-draft.js`):
   - Templates are created in the same operation. Names are available. Persist them.

4. **`saveRoutine()`** and **`saveAsNew()`** (`shared/artifacts.js`):
   - Both create routines with `template_ids`. Templates are created or known in the same operation. Persist names.

5. **`deleteTemplate()`** (`shared/templates.js`):
   - Already cleans up routine `template_ids` references. Must also remove the corresponding entry from `template_names` to avoid orphaned entries.

6. **Template rename propagation** (add to `patchTemplate()`):
   - When `name` changes on a template, query routines where `template_ids` array-contains the template ID. Update `template_names[templateId]` on each.
   - Requires a Firestore index on `template_ids` with `array-contains` (add to firestore.indexes.json).
   - Typically affects 0-1 routine docs per rename. Eventual consistency is acceptable — if the routine update fails, the name is stale until the next routine edit or a manual backfill. Template renames are rare enough that this tradeoff is fine.

7. **Backfill script** (`scripts/backfill_routine_template_names.js`):
   - Read all routines, resolve template names, update `template_names` map.

**Schema update** — add to `FIRESTORE_SCHEMA.md`:
```
routines/{routineId}:
  ...existing fields...
  template_names: map<string, string>  // {templateId: templateName} — denormalized
```

### 1c. Normalize Exercise Name Field

**Change:** Standardize on `name` (not `exercise_name`) for exercise sub-objects everywhere.

The field inconsistency causes defensive code (`ex.get("exercise_name") or ex.get("name")` in the training analyst). Workouts use `name`. Templates should match. set_facts use `exercise_name` (this is fine — it's a different document type with a flat schema).

No breaking change needed — just ensure all template write paths use `name`.

---

## Investment 2: Shared Module Projection Layer

### Design Pattern

Each list/summary function gains an optional `view` parameter:
- `"summary"` — compact shape for agent consumption. ~200-500 bytes per entity.
- `"detail"` — current full response. Default for backwards compatibility.

The summary shapes are designed to answer the most common agent questions in a single call.

### 2a. `listWorkouts(db, userId, { view, limit })`

**Summary shape** (~300 bytes/workout):
```json
{
  "id": "...",
  "end_time": "2026-01-29T...",
  "name": "Workout B",
  "source_template_id": "...",
  "exercises": [
    { "name": "Seated Row", "exercise_id": "...", "sets": 4 },
    { "name": "Incline Bench Press", "exercise_id": "...", "sets": 5 }
  ],
  "total_sets": 28,
  "total_volume": 12600,
  "duration_min": 60
}
```

**What gets dropped:** Per-set data (`weight_kg`, `reps`, `rir`), per-exercise analytics, `template_diff`, `analytics.intensity`, per-muscle breakdowns.

**Answers:** "What did I do last time?" in one call.

### 2b. `listTemplates(db, userId, { view })`

**Summary shape** (~200 bytes/template):
```json
{
  "id": "...",
  "name": "Workout A1",
  "description": "...",
  "exercise_count": 6,
  "exercise_names": ["Chest Press", "Lat Pulldown", "Incline Bench Press", "Hammer Curl", "Lateral Raise", "Skullcrusher"]
}
```

**What gets dropped:** Full exercise objects with sets, analytics, timestamps.

**Answers:** "What templates do I have?" in one call.

### 2c. `getRoutine(db, userId, routineId, { include_templates })`

When `include_templates: true`, returns the routine with inline template summaries:

```json
{
  "id": "...",
  "name": "Alternating Full Body A/B/C",
  "frequency": 3,
  "template_ids": ["...", "..."],
  "template_names": { "id1": "Workout A1", "id2": "Workout B1" },
  "is_active": true,
  "templates": [
    {
      "id": "...",
      "name": "Workout A1",
      "position": 0,
      "exercise_names": ["Chest Press", "Lat Pulldown", "Incline Bench", "Hammer Curl", "Lateral Raise", "Skullcrusher"],
      "exercise_count": 6
    }
  ]
}
```

**Answers:** "What does my routine look like?" in one call.

### 2d. `getPlanningContext(db, userId, { view })`

Move `compactSnapshot()` from MCP `tools.ts` into `shared/planning-context.js` as the `"compact"` view. Enhance it with:
- Exercise names on templates (available from Investment 1a)
- Template name on `nextWorkout`
- Template name on recent workouts (match `source_template_id` against known templates)

**Compact shape** (~2KB):
```json
{
  "user": { "name": "Valter", "weight_unit": "lbs", "fitness_level": "intermediate", "fitness_goal": "strength" },
  "active_routine": {
    "id": "...", "name": "Alternating Full Body A/B/C", "frequency": 3,
    "templates": [
      { "id": "...", "name": "Workout A1", "exercise_names": ["Chest Press", "Lat Pulldown", ...] },
      { "id": "...", "name": "Workout B1", "exercise_names": ["Incline Bench", "Seated Row", ...] }
    ]
  },
  "next_workout": { "template_id": "...", "template_name": "Workout A1", "selection_method": "cursor" },
  "recent_workouts": [
    { "id": "...", "end_time": "2026-01-29T...", "template_name": "Workout B", "exercises": ["Seated Row", "Incline Bench", ...], "total_sets": 28, "total_volume": 12600, "duration_min": 60 }
  ],
  "strength_summary": [
    { "name": "Deadlift", "e1rm": 165.3, "weight": 160, "reps": 1 },
    { "name": "Chest Press", "e1rm": 133.3, "weight": 100, "reps": 10 }
  ],
  "days_since_last_workout": 48
}
```

**Answers:** "What should I do today?" + general orientation in one call.

### 2e. `searchExercises(db, { query, limit, fieldsMode })`

Change default `fieldsMode` from `"full"` to `"lean"` for agent callers.

**Lean shape** (~150 bytes/exercise):
```json
{
  "id": "rear_delt_fly__rear-delt-fly-cable",
  "name": "Rear Delt Fly (Cable)",
  "category": "isolation",
  "equipment": ["cable"]
}
```

The shared module already supports `"minimal"`, `"lean"`, `"full"` via `projectFields()`. The MCP server just needs to pass the parameter.

**Also fix:** search_exercises cache bug — `fields` parameter is excluded from cache key, so cached results return full documents even when `fields=lean` was requested.

### 2f. `getAnalysisSummary(db, userId, { sections, include_expired })`

Add `include_expired` parameter (default `false`). When false, filter `recommendation_history` to `state === "pending_review"` only.

**Impact:** Cuts response from ~12KB to ~4KB by removing expired duplicate recommendations.

### 2g. MCP Tool Schema Improvements

These are schema/description fixes in `mcp_server/src/tools.ts`, independent of the projection work:

**`query_sets`** — replace vague target schema:
```typescript
// Before
target: z.record(z.string(), z.any()).describe('Target filter')

// After
exercise_name: z.string().optional().describe('Exercise name (fuzzy match)'),
muscle_group: z.string().optional().describe('Muscle group (e.g., "chest", "back", "shoulders")'),
muscle: z.string().optional().describe('Specific muscle (e.g., "posterior deltoid")'),
exercise_ids: z.array(z.string()).optional().describe('Exercise IDs (max 10)'),
```

**`create_template`** — type the exercises array:
```typescript
exercises: z.array(z.object({
  exercise_id: z.string().describe('Exercise ID from search_exercises'),
  position: z.number().describe('Order in template (0-based)'),
  sets: z.array(z.object({
    type: z.enum(['warmup', 'working']).default('working'),
    reps: z.number().describe('Target reps'),
    weight: z.number().describe('Target weight (kg)'),
    rir: z.number().optional().describe('Reps in reserve (0-5)'),
  })),
})).describe('Exercises with set prescriptions'),
```

**`update_template`** — type the updates:
```typescript
updates: z.object({
  name: z.string().optional(),
  description: z.string().optional(),
  exercises: z.array(z.object({ /* same as create */ })).optional(),
}).describe('Fields to update'),
```

---

## Investment 3: Agent Service Unification (Deferred — Separate Spec)

**This investment is intentionally deferred.** Investments 1 and 2 deliver value independently: write-time denormalization fixes data quality for all consumers (including the Python agent), and shared module projections are directly consumed by the MCP server. The agent service migration is a separate project with different risks.

### Why Defer

- Changes the agent service's runtime dependency graph (direct Firestore → HTTP to Firebase Functions)
- Introduces network latency (~20-50ms per call, plus potential Cloud Functions cold starts of 2-5s)
- Requires careful auth header handling (server-to-server API key lane)
- Requires latency testing and fallback strategy
- The agent service already benefits from Investment 1 passively — exercise names appear on template documents via denormalization, so `firestore_client.py` reads better data without code changes

### Direction (for future spec)

The agent service already calls Firebase Functions HTTP endpoints for all writes. Reads should follow the same pattern:

| Python Method | Target Firebase Function | View |
|---|---|---|
| `get_planning_context()` | `getPlanningContext` | `view=compact` |
| `list_templates()` | `getUserTemplates` | `view=summary` |
| `list_recent_workouts()` | `getUserWorkouts` | `view=summary` |
| `get_template()` | `getTemplate` | default (full, with name resolution) |
| `get_muscle_group_progress()` | `getMuscleGroupSummary` | default |
| `get_exercise_progress()` | `getExerciseSummary` | default |
| `search_exercises()` | `searchExercises` | `fields=lean` |
| `get_training_analysis()` | `getAnalysisSummary` | `sections` filter |
| `query_training_sets()` | `querySets` | default |

Also update agent service tool descriptions in `app/skills/coach_skills.py` to reflect richer data (exercise names always present, template names on routines) so the LLM knows it can skip follow-up lookups.

---

## Data Flow After Changes

### "What does my routine look like?" — Before

```
Agent → get_routine → {template_ids: ["id1", "id2", ...]}
     → get_template(id1) → {exercises: [{exercise_id: "abc", name: null}, ...]}
     → get_template(id2) → {exercises: [{exercise_id: "def", name: null}, ...]}
     → ... (4 more get_template calls)
     → search_exercises("abc") → 59KB overflow → bash parse
     → search_exercises("def") → 108KB overflow → bash parse
     → ... still can't resolve all names
Result: 7-15 calls, ~40K tokens, incomplete
```

### "What does my routine look like?" — After

```
Agent → get_routine(include_templates=true) → {
  name: "Full Body A/B/C",
  templates: [
    { name: "Workout A1", exercise_names: ["Chest Press", "Lat Pulldown", ...] },
    { name: "Workout B1", exercise_names: ["Incline Bench", "Seated Row", ...] }
  ]
}
Result: 1 call, ~1.5K tokens, complete
```

### "How's my bench progressing?" — Before

```
Agent → get_exercise_progress("incline bench") → {weekly_points: [], summary: {all zeros}}
     → query_sets(exercise_name="incline bench", limit=50) → 8KB raw sets
     → manually reconstruct trend from raw data
Result: 2 calls, ~10K tokens, manual aggregation
```

### "How's my bench progressing?" — After

```
Agent → get_exercise_progress("incline bench") → {
  exercise_name: "Incline Bench Press",
  weekly_points: [{week: "W01", e1rm: 72.8}, {week: "W02", e1rm: 71.1}, ...],
  trend: "improving", slope: 0.59,
  last_session: {date: "2026-01-29", top_set: {weight_kg: 60, reps: 8, e1rm: 76}},
  pr: {e1rm: 76, date: "2026-01-29"},
  plateau: false
}
Result: 1 call, ~1.5K tokens, complete with computed insights
```

Note: The progress endpoints (`getExerciseSummary`, `getMuscleGroupSummary`) already return this data when the series docs are populated. The agent service just needs to call them instead of reading raw Firestore docs.

---

## Execution Phases

### Phase 0: MCP Schema Fixes (no dependencies, immediate impact)
- Fix `query_sets` target schema with explicit fields
- Type `create_template` / `update_template` exercise schemas
- Pass `fieldsMode: "lean"` to `searchExercises`
- Add `include_expired` param to `get_training_analysis`
- Expose `sections` filter more clearly

**Tests:** MCP server build + manual validation against real data.
**Estimated scope:** ~100 lines changed in tools.ts.

### Phase 1: Write-Time Denormalization
- Exercise names on templates: update converter, `createTemplate()`, `patchTemplate()` with `db.getAll()` batch resolution
- Template names on routines: update `createRoutine()` (reuse existing template reads), `patchRoutine()`, `createRoutineFromDraftCore()`, `saveRoutine()`, `saveAsNew()`
- `deleteTemplate()`: clean up `template_names` entries on affected routines
- Add Firestore index for `template_ids` `array-contains` (needed for rename propagation)
- Backfill scripts: `backfill_template_exercise_names.js`, `backfill_routine_template_names.js`
- Update FIRESTORE_SCHEMA.md with `template_names` on routines

**Tests:** Firebase Functions test suite. Verify names persist through all write paths. Run backfill on staging.
**Estimated scope:** ~250 lines across shared/templates.js, shared/routines.js, shared/artifacts.js, utils/plan-to-template-converter.js. Two new scripts.

### Phase 2: Shared Module Projections
- `listWorkouts({ view: "summary" })` — summary shape in shared/workouts.js
- `listTemplates({ view: "summary" })` — summary shape in shared/templates.js
- `getRoutine({ include_templates: true })` — composite query in shared/routines.js
- `getPlanningContext({ view: "compact" })` — absorb compactSnapshot logic from MCP tools.ts into shared/planning-context.js
- `searchExercises` cache key fix: include `fieldsMode` in cache key
- `getAnalysisSummary({ include_expired: false })` — filter recommendation_history by default
- Firebase Function handlers: add `view` parameter pass-through in HTTP request parsing

**Tests:** Firebase Functions test suite. Verify summary shapes match documented contracts. Verify backwards compatibility (default `view: "detail"` unchanged).
**Estimated scope:** ~300 lines across shared modules + ~50 lines in Function handlers. Mainly additive.

### Phase 3: MCP Consumer Simplification
- Delete `summarizeWorkout()` and `compactSnapshot()` from tools.ts
- Call shared module functions with `view: "summary"` / `view: "compact"`
- Use camelCase field names consistent with existing MCP responses (the shared module compact view should use the same casing as the current `compactSnapshot()` to avoid breaking external agents)

**Tests:** MCP server build. End-to-end validation against real data. Compare response shapes before/after.
**Estimated scope:** ~100 lines removed from tools.ts, ~50 lines updated.

### Phase 4: Documentation
- ARCHITECTURE.md for `firebase_functions/functions/shared/` — document the projection layer, view contracts, denormalization policy
- ARCHITECTURE.md for `mcp_server/` — document tool design, how tools map to shared modules
- Update SYSTEM_ARCHITECTURE.md data flow section

### Future: Agent Service Unification (separate spec)
- Migrate Python `firestore_client.py` read methods to HTTP calls to Firebase Functions
- Update agent tool descriptions to reflect richer data
- See Investment 3 section for direction

---

## Expected Outcomes

### Agent Efficiency (primary goal)

| Question | Calls Before | Calls After | Tokens Before | Tokens After |
|---|---|---|---|---|
| "What should I do today?" | 1 MCP + bash parse | 1 | ~35K | ~0.6K |
| "What did I do last time?" | 1 MCP + bash parse | 1 | ~35K | ~1K |
| "How's my bench progressing?" | 2 | 1 | ~10K | ~1.5K |
| "What does my routine look like?" | 7-15 | 1 | ~40K | ~1.5K |
| "Am I doing enough chest work?" | 2-3 | 1 | ~5K | ~0.5K |
| "Am I overtraining?" | 1 | 1 | ~12K | ~4K |
| "Add rear delt flyes to push day" | 3-5 + bash | 2 | ~60K | ~1K |
| Overall "how am I progressing?" | ~20 | 7 | ~65K | ~6K |

### Maintenance

- **Before:** 3 independent summarization implementations (MCP TS, Agent Python, shared JS none). Schema changes propagated manually.
- **After:** 1 implementation in shared modules. MCP and agent service are thin wrappers.

### Data Quality

- **Before:** Exercise names on templates: sometimes present, sometimes not. Template names on routines: never present.
- **After:** Always present. Written at creation time, backfilled for existing data.
