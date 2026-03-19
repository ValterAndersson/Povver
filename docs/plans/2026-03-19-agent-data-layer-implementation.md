# Agent-Optimized Data Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce agent tool calls from 7-20 to 1-2 per question by denormalizing names at write time and adding projection support to shared modules.

**Architecture:** Write-time denormalization ensures exercise names persist on templates and template names persist on routines. Shared module functions gain `view: "summary"` support so consumers get compact shapes without reimplementing summarization. MCP server becomes a thin wrapper over shared modules.

**Tech Stack:** Node.js 22, Firebase Admin SDK, Firestore, `node:test` runner, in-memory Firestore mocks.

**Spec:** `docs/plans/2026-03-19-agent-data-layer-design.md`

---

## File Structure

### New Files
- `firebase_functions/functions/tests/plan-to-template-converter.test.js` — Tests for converter (currently ZERO coverage)
- `scripts/backfill_template_exercise_names.js` — Backfill exercise names on templates
- `scripts/backfill_routine_template_names.js` — Backfill template names on routines

### Modified Files
- `firebase_functions/functions/utils/plan-to-template-converter.js` — Pass through `name` field
- `firebase_functions/functions/shared/templates.js` — Batch name resolution in `createTemplate`/`patchTemplate`, `resolveExerciseNames` batch optimization, `listTemplates` view support, `deleteTemplate` cleanup `template_names`
- `firebase_functions/functions/shared/routines.js` — Persist `template_names` in `createRoutine`/`patchRoutine`, `getRoutine` `include_templates` option
- `firebase_functions/functions/shared/artifacts.js` — Persist `template_names` in `saveRoutine`/`saveAsNew`
- `firebase_functions/functions/routines/create-routine-from-draft.js` — Persist `template_names`
- `firebase_functions/functions/shared/workouts.js` — `listWorkouts` view support
- `firebase_functions/functions/shared/planning-context.js` — `getPlanningContext` compact view
- `firebase_functions/functions/shared/training-queries.js` — `getAnalysisSummary` `include_expired` filter
- `firebase_functions/functions/exercises/search-exercises.js` — Cache key fix for `fields` param
- `firebase_functions/functions/tests/shared.templates.test.js` — New tests for name resolution, view support
- `firebase_functions/functions/tests/shared.routines.test.js` — New tests for `template_names`, `include_templates`
- `mcp_server/src/tools.ts` — Schema fixes, projection pass-through, delete summarization functions
- `docs/FIRESTORE_SCHEMA.md` — Add `template_names` field

---

## Phase 0: MCP Schema Fixes

### Task 1: Fix `query_sets` Target Schema

**Files:**
- Modify: `mcp_server/src/tools.ts:186-192`
- Test: `mcp_server` build check

- [ ] **Step 1: Update query_sets schema in tools.ts**

Replace the vague `z.record(z.string(), z.any())` target with explicit fields:

```typescript
server.tool('query_sets', 'Query raw set-level training data', {
  exercise_name: z.string().optional().describe('Exercise name (fuzzy match)'),
  muscle_group: z.string().optional().describe('Muscle group (e.g., "chest", "back", "shoulders")'),
  muscle: z.string().optional().describe('Specific muscle (e.g., "posterior deltoid")'),
  exercise_ids: z.array(z.string()).optional().describe('Exercise IDs (max 10)'),
  limit: z.number().default(50).describe('Max results')
}, async ({ exercise_name, muscle_group, muscle, exercise_ids, limit }) => {
  // Build target object from explicit fields
  const target: Record<string, any> = {};
  if (exercise_name) target.exercise = exercise_name;
  if (muscle_group) target.muscle_group = muscle_group;
  if (muscle) target.muscle = muscle;
  if (exercise_ids) target.exercise_ids = exercise_ids;

  const data = await trainingQueries.querySets(db, userId, { target, limit: limit || 50 });
  return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
});
```

- [ ] **Step 2: Build MCP server to verify**

Run: `cd mcp_server && npm run build`
Expected: Clean build, no type errors.

- [ ] **Step 3: Commit**

```bash
git add mcp_server/src/tools.ts
git commit -m "fix(mcp): replace vague query_sets target with explicit fields"
```

### Task 2: Type `create_template` and `update_template` Schemas

**Files:**
- Modify: `mcp_server/src/tools.ts:212-226`

- [ ] **Step 1: Update create_template schema**

```typescript
server.tool('create_template', 'Create a new workout template', {
  name: z.string().describe('Template name'),
  exercises: z.array(z.object({
    exercise_id: z.string().describe('Exercise ID from search_exercises'),
    name: z.string().optional().describe('Exercise name'),
    position: z.number().describe('Order in template (0-based)'),
    sets: z.array(z.object({
      type: z.enum(['warmup', 'working']).default('working'),
      reps: z.number().describe('Target reps'),
      weight: z.number().nullable().describe('Target weight (kg) or null for bodyweight'),
      rir: z.number().optional().describe('Reps in reserve (0-5)'),
    })),
  })).describe('Exercises with set prescriptions'),
}, async (args) => {
  const tmpl = await templates.createTemplate(db, userId, args);
  return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
});
```

- [ ] **Step 2: Update update_template schema**

```typescript
server.tool('update_template', 'Update an existing template', {
  template_id: z.string().describe('Template ID'),
  updates: z.object({
    name: z.string().optional(),
    description: z.string().optional(),
    exercises: z.array(z.object({
      exercise_id: z.string().describe('Exercise ID'),
      name: z.string().optional().describe('Exercise name'),
      position: z.number().describe('Order (0-based)'),
      sets: z.array(z.object({
        type: z.enum(['warmup', 'working']).default('working'),
        reps: z.number().describe('Target reps'),
        weight: z.number().nullable().describe('Target weight (kg)'),
        rir: z.number().optional().describe('Reps in reserve (0-5)'),
      })),
    })).optional(),
  }).describe('Fields to update'),
}, async ({ template_id, updates }) => {
  const tmpl = await templates.patchTemplate(db, userId, template_id, updates);
  return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
});
```

- [ ] **Step 3: Build and commit**

Run: `cd mcp_server && npm run build`

```bash
git add mcp_server/src/tools.ts
git commit -m "fix(mcp): type create_template and update_template exercise schemas"
```

### Task 3: Pass `fieldsMode: "lean"` for `search_exercises`

**Files:**
- Modify: `mcp_server/src/tools.ts:154-160`

- [ ] **Step 1: Add fields param to searchExercises call**

```typescript
server.tool('search_exercises', 'Search exercise catalog', {
  query: z.string().describe('Search query'),
  limit: z.number().default(10).describe('Max results')
}, async ({ query, limit }) => {
  const result = await exercises.searchExercises(db, { query, limit: limit || 10, fields: 'lean' });
  return { content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }] };
});
```

- [ ] **Step 2: Build and commit**

Run: `cd mcp_server && npm run build`

```bash
git add mcp_server/src/tools.ts
git commit -m "fix(mcp): use lean field projection for search_exercises"
```

### Task 4: Fix search-exercises Cache Key Bug

**Files:**
- Modify: `firebase_functions/functions/exercises/search-exercises.js:98-105`

- [ ] **Step 1: Add `fields` to cache key params**

In `search-exercises.js`, the `cacheParams` object at ~line 98 excludes `fields`. Add it:

```javascript
    const cacheParams = {
      query, category, movementType, split, equipment,
      muscleGroup, primaryMuscle, secondaryMuscle, difficulty,
      planeOfMotion, unilateral, stimulusTag, programmingUseCase,
      limit, includeMerged, canonicalOnly,
      fields,  // <-- add this
    };
```

- [ ] **Step 2: Run tests and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/exercises/search-exercises.js
git commit -m "fix(exercises): include fields param in search cache key"
```

### Task 5: Add `include_expired` Filter to `get_training_analysis`

**Files:**
- Modify: `mcp_server/src/tools.ts:163-168`

- [ ] **Step 1: Update MCP tool to pass include_expired**

```typescript
server.tool('get_training_analysis', 'Get training analysis insights', {
  sections: z.array(z.string()).optional().describe('Sections: insights, weekly_review, recommendation_history'),
  include_expired: z.boolean().default(false).describe('Include expired/applied recommendations')
}, async ({ sections, include_expired }) => {
  const analysis = await trainingQueries.getAnalysisSummary(db, userId, { sections, include_expired }, admin);
  return { content: [{ type: 'text' as const, text: JSON.stringify(analysis, null, 2) }] };
});
```

- [ ] **Step 2: Add filtering in getAnalysisSummary**

In `shared/training-queries.js`, at the END of the `recommendation_history` results block (~line 776), add a filter AFTER the existing recommendation assembly loop. Keep ALL existing field extraction code intact. Just add the filter before assigning to `response`:

```javascript
  if (results.recommendation_history) {
    // ... keep ALL existing code that builds the recommendations array ...
    // (lines 749-775 — the for loop that pushes to recommendations[])

    // ADD THIS after the existing loop, before response.recommendation_history = ...
    // Filter expired unless explicitly requested
    if (!options.include_expired) {
      recommendations = recommendations.filter(r => r.state === 'pending_review');
    }
    response.recommendation_history = recommendations;
  }
```

Note: `recommendations` must be declared with `let` (not `const`) at the top of the block. Currently it's `const recommendations = [];` — change to `let recommendations = [];`.

- [ ] **Step 3: Run tests and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/training-queries.js mcp_server/src/tools.ts
git commit -m "feat(analysis): filter expired recommendations by default"
```

---

## Phase 1: Write-Time Denormalization

### Task 6: Add Converter Tests (Zero → Baseline Coverage)

**Files:**
- Create: `firebase_functions/functions/tests/plan-to-template-converter.test.js`

These tests establish coverage BEFORE we change the converter code.

- [ ] **Step 1: Write tests for existing converter behavior**

```javascript
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const {
  convertPlanBlockToTemplateExercise,
  convertPlanToTemplate,
  convertPlanSetToTemplateSet,
  validatePlanContent,
} = require('../utils/plan-to-template-converter');

describe('convertPlanBlockToTemplateExercise', () => {
  test('extracts exercise_id and sets, ignores name field', () => {
    const block = {
      exercise_id: 'bench_press',
      name: 'Bench Press',
      sets: [{ target: { reps: 10, rir: 2 } }],
    };
    const result = convertPlanBlockToTemplateExercise(block, 0);
    assert.equal(result.exercise_id, 'bench_press');
    assert.equal(result.position, 0);
    assert.equal(result.sets.length, 1);
    // Currently name is NOT preserved — this test documents the gap
    assert.equal(result.name, undefined);
  });

  test('throws on missing exercise_id', () => {
    assert.throws(() => {
      convertPlanBlockToTemplateExercise({ sets: [{ target: { reps: 10, rir: 2 } }] }, 0);
    }, /missing required exercise_id/);
  });

  test('throws on empty sets array', () => {
    assert.throws(() => {
      convertPlanBlockToTemplateExercise({ exercise_id: 'x', sets: [] }, 0);
    }, /missing or empty sets/);
  });

  test('preserves rest_between_sets when present', () => {
    const block = {
      exercise_id: 'x',
      sets: [{ target: { reps: 8, rir: 1 } }],
      rest_between_sets: 120,
    };
    const result = convertPlanBlockToTemplateExercise(block, 0);
    assert.equal(result.rest_between_sets, 120);
  });
});

describe('convertPlanToTemplate', () => {
  test('converts plan with title and blocks to template', () => {
    const plan = {
      title: 'Push Day',
      blocks: [
        { exercise_id: 'bench', sets: [{ target: { reps: 8, rir: 2 } }] },
        { exercise_id: 'ohp', sets: [{ target: { reps: 10, rir: 3 } }] },
      ],
    };
    const result = convertPlanToTemplate(plan);
    assert.equal(result.name, 'Push Day');
    assert.equal(result.exercises.length, 2);
    assert.equal(result.exercises[0].exercise_id, 'bench');
    assert.equal(result.exercises[1].exercise_id, 'ohp');
    assert.equal(result.exercises[0].position, 0);
    assert.equal(result.exercises[1].position, 1);
  });
});

describe('convertPlanSetToTemplateSet', () => {
  test('preserves null weight for bodyweight exercises', () => {
    const set = { target: { reps: 12, rir: 1, weight: null } };
    const result = convertPlanSetToTemplateSet(set, 0, 0);
    assert.equal(result.weight, null);
    assert.equal(result.reps, 12);
  });

  test('preserves numeric weight', () => {
    const set = { target: { reps: 8, rir: 2, weight: 60 } };
    const result = convertPlanSetToTemplateSet(set, 0, 0);
    assert.equal(result.weight, 60);
  });

  test('defaults type to working', () => {
    const set = { target: { reps: 10, rir: 2 } };
    const result = convertPlanSetToTemplateSet(set, 0, 0);
    assert.equal(result.type, 'working');
  });

  test('preserves warmup type', () => {
    const set = { target: { reps: 10, rir: 2 }, type: 'warmup' };
    const result = convertPlanSetToTemplateSet(set, 0, 0);
    assert.equal(result.type, 'warmup');
  });
});
```

- [ ] **Step 2: Run tests to verify they pass (documenting current behavior)**

Run: `cd firebase_functions/functions && npx node --test tests/plan-to-template-converter.test.js`

Expected: All pass except the `name` assertion should confirm `undefined` (documenting the gap).

- [ ] **Step 3: Commit baseline tests**

```bash
git add firebase_functions/functions/tests/plan-to-template-converter.test.js
git commit -m "test: add baseline converter tests (zero coverage → baseline)"
```

### Task 7: Make Converter Pass Through Exercise Name

**Files:**
- Modify: `firebase_functions/functions/utils/plan-to-template-converter.js:72-96`
- Test: `firebase_functions/functions/tests/plan-to-template-converter.test.js`

- [ ] **Step 1: Write failing test for name pass-through**

Add to `plan-to-template-converter.test.js`:

```javascript
describe('convertPlanBlockToTemplateExercise - name pass-through', () => {
  test('preserves name from block when present', () => {
    const block = {
      exercise_id: 'bench_press',
      name: 'Bench Press (Barbell)',
      sets: [{ target: { reps: 10, rir: 2 } }],
    };
    const result = convertPlanBlockToTemplateExercise(block, 0);
    assert.equal(result.name, 'Bench Press (Barbell)');
  });

  test('preserves exercise_name from block when name is absent', () => {
    const block = {
      exercise_id: 'bench_press',
      exercise_name: 'Bench Press',
      sets: [{ target: { reps: 10, rir: 2 } }],
    };
    const result = convertPlanBlockToTemplateExercise(block, 0);
    assert.equal(result.name, 'Bench Press');
  });

  test('omits name field when block has no name', () => {
    const block = {
      exercise_id: 'bench_press',
      sets: [{ target: { reps: 10, rir: 2 } }],
    };
    const result = convertPlanBlockToTemplateExercise(block, 0);
    assert.equal(result.name, undefined);
  });
});

describe('convertPlanToTemplate - name pass-through', () => {
  test('exercises have names when blocks provide them', () => {
    const plan = {
      title: 'Push Day',
      blocks: [
        { exercise_id: 'bench', name: 'Bench Press', sets: [{ target: { reps: 8, rir: 2 } }] },
        { exercise_id: 'ohp', sets: [{ target: { reps: 10, rir: 3 } }] },
      ],
    };
    const result = convertPlanToTemplate(plan);
    assert.equal(result.exercises[0].name, 'Bench Press');
    assert.equal(result.exercises[1].name, undefined);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd firebase_functions/functions && npx node --test tests/plan-to-template-converter.test.js`
Expected: FAIL — `result.name` is `undefined` when `block.name` is `'Bench Press (Barbell)'`.

- [ ] **Step 3: Implement name pass-through in converter**

In `plan-to-template-converter.js`, modify `convertPlanBlockToTemplateExercise` (line 88-95):

```javascript
  const result = {
    id: block.id || uuidv4(),
    exercise_id: exerciseId,
    position: blockIndex,
    sets: templateSets,
    rest_between_sets: typeof block.rest_between_sets === 'number' ? block.rest_between_sets : null
  };

  // Pass through exercise name if available (name preferred, exercise_name as fallback)
  const exerciseName = block.name || block.exercise_name;
  if (exerciseName) {
    result.name = exerciseName;
  }

  return result;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd firebase_functions/functions && npx node --test tests/plan-to-template-converter.test.js`
Expected: All PASS.

- [ ] **Step 5: Run full test suite for regression check**

Run: `cd firebase_functions/functions && npm test`
Expected: All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add firebase_functions/functions/utils/plan-to-template-converter.js firebase_functions/functions/tests/plan-to-template-converter.test.js
git commit -m "feat(converter): pass through exercise name from plan blocks"
```

### Task 8: Batch-Resolve Exercise Names in `resolveExerciseNames`

**Files:**
- Modify: `firebase_functions/functions/shared/templates.js:46-55`
- Test: `firebase_functions/functions/tests/shared.templates.test.js`

- [ ] **Step 1: Write failing test for batch resolution**

Add to `shared.templates.test.js`. The mock db needs `getAll` support. Add this before the tests:

```javascript
// Add getAll support to the base createMockDb.
// IMPORTANT: This must be added to createMockDb itself (not a wrapper),
// because existing patchTemplate tests that patch exercises without names
// will trigger resolveExerciseNames → db.getAll after our changes.
// Add this inside createMockDb, after the db object is built:
//
//   db.getAll = async (...refs) => {
//     return refs.map(ref => {
//       const path = typeof ref.path === 'string' ? ref.path : ref.id;
//       const data = store[path];
//       return {
//         exists: !!data,
//         id: path.split('/').pop(),
//         data: () => (data ? { ...data } : undefined),
//       };
//     });
//   };
//
// This ensures ALL template tests (existing and new) work with getAll.
```

Add test:

```javascript
describe('createTemplate - exercise name resolution', () => {
  test('resolves missing exercise names from catalog via batch read', async () => {
    const store = {
      'exercises/bench_press': { name: 'Bench Press (Barbell)' },
      'exercises/lat_pulldown': { name: 'Lat Pulldown (Cable)' },
    };
    const db = createMockDbWithGetAll(store);

    const input = {
      name: 'Push Day',
      exercises: [
        { exercise_id: 'bench_press', position: 0, sets: [{ reps: 8, rir: 2 }] },
        { exercise_id: 'lat_pulldown', name: 'Already Named', position: 1, sets: [{ reps: 10, rir: 3 }] },
      ],
    };

    const result = await createTemplate(db, 'user1', input);
    // Fetch the stored template to check exercise names
    const templateId = result.id || result.templateId;
    const stored = store[`users/user1/templates/${templateId}`];
    assert.ok(stored, 'Template should be stored');

    // Exercise without name should have it resolved from catalog
    assert.equal(stored.exercises[0].name, 'Bench Press (Barbell)');
    // Exercise with existing name should keep it
    assert.equal(stored.exercises[1].name, 'Already Named');
  });

  test('exercises with name already set are not re-resolved', async () => {
    const store = {
      'exercises/bench_press': { name: 'Catalog Name' },
    };
    const db = createMockDbWithGetAll(store);

    const input = {
      name: 'Test',
      exercises: [
        { exercise_id: 'bench_press', name: 'Custom Name', position: 0, sets: [{ reps: 8, rir: 2 }] },
      ],
    };

    const result = await createTemplate(db, 'user1', input);
    const templateId = result.id || result.templateId;
    const stored = store[`users/user1/templates/${templateId}`];
    assert.equal(stored.exercises[0].name, 'Custom Name');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd firebase_functions/functions && npx node --test tests/shared.templates.test.js`
Expected: FAIL — `stored.exercises[0].name` is `undefined` (names not resolved at write time).

- [ ] **Step 3: Implement batch resolution in createTemplate**

In `shared/templates.js`, modify `resolveExerciseNames` to use `db.getAll`:

```javascript
async function resolveExerciseNames(db, exerciseIds) {
  if (exerciseIds.length === 0) return {};
  const refs = exerciseIds.map(id => db.collection('exercises').doc(id));
  const docs = await db.getAll(...refs);
  const names = {};
  docs.forEach((doc, i) => {
    if (doc.exists) {
      names[exerciseIds[i]] = doc.data().name || exerciseIds[i];
    }
  });
  return names;
}
```

In `createTemplate()`, after validation and before the Firestore write, add name resolution:

```javascript
  // Resolve missing exercise names from catalog
  if (Array.isArray(templateInput.exercises)) {
    const idsToResolve = templateInput.exercises
      .filter(ex => !ex.name && ex.exercise_id)
      .map(ex => ex.exercise_id);

    if (idsToResolve.length > 0) {
      const exerciseNames = await resolveExerciseNames(db, idsToResolve);
      templateInput.exercises = templateInput.exercises.map(ex => {
        if (!ex.name && ex.exercise_id && exerciseNames[ex.exercise_id]) {
          return { ...ex, name: exerciseNames[ex.exercise_id] };
        }
        return ex;
      });
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd firebase_functions/functions && npx node --test tests/shared.templates.test.js`
Expected: All PASS including new tests.

- [ ] **Step 5: Run full test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add firebase_functions/functions/shared/templates.js firebase_functions/functions/tests/shared.templates.test.js
git commit -m "feat(templates): batch-resolve exercise names at write time in createTemplate"
```

### Task 9: Resolve Exercise Names in `patchTemplate`

**Files:**
- Modify: `firebase_functions/functions/shared/templates.js` (`patchTemplate` function)
- Test: `firebase_functions/functions/tests/shared.templates.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('patchTemplate - exercise name resolution', () => {
  test('resolves missing names when exercises array is patched', async () => {
    const store = {
      'users/user1/templates/t1': {
        name: 'Old Template',
        exercises: [{ exercise_id: 'old_ex', name: 'Old Exercise', position: 0, sets: [] }],
      },
      'exercises/new_ex': { name: 'New Exercise Name' },
    };
    const db = createMockDbWithGetAll(store);

    await patchTemplate(db, 'user1', 't1', {
      exercises: [
        { exercise_id: 'new_ex', position: 0, sets: [{ reps: 8, rir: 2 }] },
      ],
    });

    const stored = store['users/user1/templates/t1'];
    assert.equal(stored.exercises[0].name, 'New Exercise Name');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd firebase_functions/functions && npx node --test tests/shared.templates.test.js`
Expected: FAIL — name is not resolved.

- [ ] **Step 3: Add resolution logic in patchTemplate**

In `patchTemplate()`, where the `exercises` field is being updated (inside the exercises validation block), add the same batch resolution logic:

```javascript
    // Resolve missing exercise names from catalog
    const idsToResolve = sanitizedPatch.exercises
      .filter(ex => !ex.name && ex.exercise_id)
      .map(ex => ex.exercise_id);

    if (idsToResolve.length > 0) {
      const exerciseNames = await resolveExerciseNames(db, idsToResolve);
      sanitizedPatch.exercises = sanitizedPatch.exercises.map(ex => {
        if (!ex.name && ex.exercise_id && exerciseNames[ex.exercise_id]) {
          return { ...ex, name: exerciseNames[ex.exercise_id] };
        }
        return ex;
      });
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd firebase_functions/functions && npm test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/shared/templates.js firebase_functions/functions/tests/shared.templates.test.js
git commit -m "feat(templates): batch-resolve exercise names in patchTemplate"
```

### Task 10: Persist `template_names` in `createRoutine`

**Files:**
- Modify: `firebase_functions/functions/shared/routines.js:94-170`
- Test: `firebase_functions/functions/tests/shared.routines.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('createRoutine - template_names', () => {
  test('persists template_names map from already-fetched template docs', async () => {
    const store = {
      'users/u1/templates/t1': { name: 'Push Day' },
      'users/u1/templates/t2': { name: 'Pull Day' },
    };
    const db = createMockDb(store);

    const result = await createRoutine(db, 'u1', {
      name: 'PPL Routine',
      template_ids: ['t1', 't2'],
      frequency: 2,
    });

    // Find the created routine in store
    const routineKey = Object.keys(store).find(k => k.startsWith('users/u1/routines/'));
    assert.ok(routineKey, 'Routine should be created');
    const routine = store[routineKey];
    assert.deepEqual(routine.template_names, { t1: 'Push Day', t2: 'Pull Day' });
  });

  test('handles templates without names gracefully', async () => {
    const store = {
      'users/u1/templates/t1': { name: 'Named' },
      'users/u1/templates/t2': { exercises: [] },  // no name
    };
    const db = createMockDb(store);

    const result = await createRoutine(db, 'u1', {
      name: 'Test',
      template_ids: ['t1', 't2'],
      frequency: 2,
    });

    const routineKey = Object.keys(store).find(k => k.startsWith('users/u1/routines/'));
    const routine = store[routineKey];
    assert.equal(routine.template_names.t1, 'Named');
    assert.equal(routine.template_names.t2, 'Untitled');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd firebase_functions/functions && npx node --test tests/shared.routines.test.js`
Expected: FAIL — `routine.template_names` is undefined.

- [ ] **Step 3: Implement template_names in createRoutine**

In `shared/routines.js` `createRoutine()`, declare `templateNames` BEFORE the `if (templateIds.length > 0)` block (~line 109), then populate it inside the block:

```javascript
  // Declare outside the if-block so it's always available for enhancedRoutine
  let templateNames = {};

  // Validate all template_ids exist
  if (templateIds.length > 0) {
    const templatesCol = db.collection('users').doc(userId).collection('templates');
    const templateRefs = templateIds.map(tid => templatesCol.doc(tid));
    const templateDocs = await db.getAll(...templateRefs);

    // ... existing validation logic ...

    // Extract template names from already-fetched docs (no additional reads)
    templateDocs.forEach((doc, idx) => {
      if (doc.exists) {
        const data = doc.data();
        templateNames[templateIds[idx]] = data.name || 'Untitled';
      }
    });
  }
```

Then add `template_names` to the `enhancedRoutine` object (~line 136):

```javascript
  const enhancedRoutine = {
    ...routineInput,
    frequency: routineInput.frequency || 3,
    template_ids: templateIds,
    template_names: templateNames,
    created_at: now,
    updated_at: now,
  };
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd firebase_functions/functions && npm test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/shared/routines.js firebase_functions/functions/tests/shared.routines.test.js
git commit -m "feat(routines): persist template_names on createRoutine"
```

### Task 11: Persist `template_names` in `patchRoutine`

**Files:**
- Modify: `firebase_functions/functions/shared/routines.js:187-275`
- Test: `firebase_functions/functions/tests/shared.routines.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('patchRoutine - template_names', () => {
  test('updates template_names when template_ids change', async () => {
    const store = {
      'users/u1/routines/r1': {
        name: 'My Routine',
        template_ids: ['t1'],
        template_names: { t1: 'Push Day' },
      },
      'users/u1/templates/t1': { name: 'Push Day' },
      'users/u1/templates/t2': { name: 'Pull Day' },
    };
    const db = createMockDb(store);

    await patchRoutine(db, 'u1', 'r1', { template_ids: ['t1', 't2'] });

    const routine = store['users/u1/routines/r1'];
    assert.deepEqual(routine.template_names, { t1: 'Push Day', t2: 'Pull Day' });
  });
});
```

- [ ] **Step 2: Run to verify fail, implement, verify pass**

In `patchRoutine()`, in the template_ids validation block (~line 236-261), after validating templates exist, resolve names:

```javascript
    // Resolve template names for denormalization
    const templateNames = {};
    for (const { tid, exists } of templateChecks) {
      if (exists) {
        const templateDoc = await db.collection('users').doc(userId)
          .collection('templates').doc(tid).get();
        if (templateDoc.exists) {
          templateNames[tid] = templateDoc.data().name || 'Untitled';
        }
      }
    }
    sanitizedPatch.template_names = templateNames;
```

Note: `patchRoutine` currently does parallel individual reads for validation. We already have the docs. But the current mock structure returns `{ tid, exists }` without the data. We need to change the validation to keep the template data:

```javascript
    // Validate all templates exist (parallel reads) and collect names
    const templateChecks = await Promise.all(
      sanitizedPatch.template_ids.map(async (tid) => {
        const templateDoc = await db.collection('users').doc(userId).collection('templates').doc(tid).get();
        return { tid, exists: templateDoc.exists, name: templateDoc.exists ? (templateDoc.data().name || 'Untitled') : null };
      })
    );

    const missing = templateChecks.filter(c => !c.exists);
    if (missing.length > 0) {
      throw new ValidationError(`Templates not found: ${missing.map(m => m.tid).join(', ')}`);
    }

    // Build template_names from already-fetched docs
    const templateNames = {};
    templateChecks.forEach(c => { templateNames[c.tid] = c.name; });
    sanitizedPatch.template_names = templateNames;
```

- [ ] **Step 3: Run full test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All PASS.

- [ ] **Step 4: Commit**

```bash
git add firebase_functions/functions/shared/routines.js firebase_functions/functions/tests/shared.routines.test.js
git commit -m "feat(routines): update template_names when template_ids change in patchRoutine"
```

### Task 12: Clean Up `template_names` in `deleteTemplate`

**Files:**
- Modify: `firebase_functions/functions/shared/templates.js:343-381`
- Test: `firebase_functions/functions/tests/shared.templates.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('deleteTemplate - template_names cleanup', () => {
  test('removes entry from template_names on affected routines', async () => {
    const store = {
      'users/u1/templates/t1': { name: 'Push Day', exercises: [] },
      'users/u1/routines/r1': {
        template_ids: ['t1', 't2'],
        template_names: { t1: 'Push Day', t2: 'Pull Day' },
      },
    };
    const db = createMockDb(store);

    await deleteTemplate(db, 'u1', 't1');

    const routine = store['users/u1/routines/r1'];
    assert.deepEqual(routine.template_ids, ['t2']);
    assert.deepEqual(routine.template_names, { t2: 'Pull Day' });
  });
});
```

- [ ] **Step 2: Run to verify fail, implement, verify pass**

In `deleteTemplate()`, after building `updatedTemplateIds` (~line 365), also update `template_names`:

```javascript
    const updateData = { template_ids: updatedTemplateIds };

    // Remove from template_names map if it exists
    if (routine.template_names && routine.template_names[templateId]) {
      const updatedNames = { ...routine.template_names };
      delete updatedNames[templateId];
      updateData.template_names = updatedNames;
    }
```

- [ ] **Step 3: Run full test suite and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/templates.js firebase_functions/functions/tests/shared.templates.test.js
git commit -m "fix(templates): clean up template_names on deleteTemplate"
```

### Task 13: Persist `template_names` in Artifact Write Paths

**Files:**
- Modify: `firebase_functions/functions/shared/artifacts.js:67-187` (`saveRoutine`), lines 285-361 (`saveAsNew`)
- Modify: `firebase_functions/functions/routines/create-routine-from-draft.js:196-237`

No new tests — these write paths have existing test coverage via integration tests, and the template names are derived from data already available in the same function scope.

- [ ] **Step 1: Add template_names to saveRoutine**

In `artifacts.js` `saveRoutine()`, after the template creation loop (~line 143), the `routineData` object needs `template_names`. Templates are created from `workout.title`, so names are known:

```javascript
  // Build template_names from created/updated templates
  const templateNames = {};
  workouts.forEach((workout, i) => {
    templateNames[templateIds[i]] = workout.title || `Day ${workout.day}`;
  });

  const routineData = {
    name: content.name || 'My Routine',
    description: content.description || null,
    frequency: content.frequency || templateIds.length,
    template_ids: templateIds,
    template_names: templateNames,
    updated_at: now,
  };
```

- [ ] **Step 2: Add template_names to saveAsNew for routine_summary**

In `saveAsNew()`, in the `routine_summary` branch (~line 316-330), add `template_names`:

```javascript
    const templateNames = {};
    workouts.forEach((workout, i) => {
      templateNames[templateIds[i]] = workout.title || `Day ${workout.day}`;
    });

    await newRoutineRef.set({
      id: routineId,
      user_id: userId,
      name: content.name || 'My Routine',
      description: content.description || null,
      frequency: content.frequency || templateIds.length,
      template_ids: templateIds,
      template_names: templateNames,
      cursor: 0,
      created_at: now,
      updated_at: now,
    });
```

- [ ] **Step 3: Add template_names to createRoutineFromDraftCore**

In `create-routine-from-draft.js`, after the template creation loop (~line 188), add `template_names`. The template names come from `workout.title`:

```javascript
  // Build template_names from created templates
  const templateNames = {};
  dayCards.forEach(({ workout }, i) => {
    templateNames[templateIds[i]] = workout.title || dayCards[i].data.content?.title || 'Workout';
  });

  const routineData = {
    name: summaryContent.name || 'My Routine',
    description: summaryContent.description || null,
    frequency: summaryContent.frequency || templateIds.length,
    template_ids: templateIds,
    template_names: templateNames,
    updated_at: now,
  };
```

- [ ] **Step 4: Run full test suite**

Run: `cd firebase_functions/functions && npm test`
Expected: All pass (no test breaks from additive changes).

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/shared/artifacts.js firebase_functions/functions/routines/create-routine-from-draft.js
git commit -m "feat(routines): persist template_names in artifact and draft write paths"
```

### Task 14: Template Rename Propagation in `patchTemplate`

**Files:**
- Modify: `firebase_functions/functions/shared/templates.js` (patchTemplate)
- Test: `firebase_functions/functions/tests/shared.templates.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('patchTemplate - template name propagation', () => {
  test('updates template_names on routines when template name changes', async () => {
    const store = {
      'users/u1/templates/t1': {
        name: 'Old Name',
        exercises: [{ exercise_id: 'ex1', name: 'Test', position: 0, sets: [{ reps: 8, rir: 2 }] }],
      },
      'users/u1/routines/r1': {
        template_ids: ['t1', 't2'],
        template_names: { t1: 'Old Name', t2: 'Other' },
      },
    };
    const db = createMockDb(store);

    await patchTemplate(db, 'u1', 't1', { name: 'New Name' });

    assert.equal(store['users/u1/templates/t1'].name, 'New Name');
    assert.equal(store['users/u1/routines/r1'].template_names.t1, 'New Name');
  });
});
```

- [ ] **Step 2: Run to verify fail, implement, verify pass**

In `patchTemplate()`, after the main update is applied, add name propagation when `name` was patched:

```javascript
  // Propagate name change to routines that reference this template
  if (sanitizedPatch.name) {
    const routinesSnap = await db.collection('users').doc(userId).collection('routines').get();
    for (const rDoc of routinesSnap.docs) {
      const rData = rDoc.data();
      const tids = rData.template_ids || rData.templateIds || [];
      if (tids.includes(templateId) && rData.template_names) {
        const updatedNames = { ...rData.template_names, [templateId]: sanitizedPatch.name };
        // Use db.collection(...).doc(id).update() — NOT rDoc.ref.update()
        // because the templates test mock's collection .get() returns docs
        // without a .ref property (unlike the routines mock).
        await db.collection('users').doc(userId).collection('routines').doc(rDoc.id).update({ template_names: updatedNames });
      }
    }
  }
```

Note: In production, a Firestore index on `template_ids` with `array-contains` would make this query efficient. For now, this reads all routines (typically < 5 per user). Add index later if needed.

- [ ] **Step 3: Run full test suite and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/templates.js firebase_functions/functions/tests/shared.templates.test.js
git commit -m "feat(templates): propagate name changes to routine template_names"
```

### Task 15: Update FIRESTORE_SCHEMA.md

**Files:**
- Modify: `docs/FIRESTORE_SCHEMA.md`

- [ ] **Step 1: Add template_names field to routines schema**

Find the routines section in `docs/FIRESTORE_SCHEMA.md` and add:

```markdown
  template_names: map<string, string>  // {templateId: templateName} — denormalized, updated on template rename
```

- [ ] **Step 2: Commit**

```bash
git add docs/FIRESTORE_SCHEMA.md
git commit -m "docs: add template_names field to routines schema"
```

### Task 16: Backfill Scripts

**Files:**
- Create: `scripts/backfill_template_exercise_names.js`
- Create: `scripts/backfill_routine_template_names.js`

- [ ] **Step 1: Write template exercise names backfill script**

```javascript
#!/usr/bin/env node
/**
 * Backfill exercise names on templates from the exercise catalog.
 * Idempotent — safe to re-run. Skips exercises that already have names.
 *
 * Usage: GOOGLE_APPLICATION_CREDENTIALS=$FIREBASE_SA_KEY node scripts/backfill_template_exercise_names.js [--dry-run]
 */
const admin = require('firebase-admin');
admin.initializeApp();
const db = admin.firestore();

const dryRun = process.argv.includes('--dry-run');

async function main() {
  console.log(`Backfill template exercise names${dryRun ? ' (DRY RUN)' : ''}`);

  const usersSnap = await db.collection('users').limit(10000).get();
  let usersProcessed = 0, templatesUpdated = 0, exercisesResolved = 0;

  // Pre-load exercise catalog into memory (< 2000 docs, ~1MB)
  const exerciseCatalog = new Map();
  const catSnap = await db.collection('exercises').limit(5000).get();
  catSnap.docs.forEach(d => exerciseCatalog.set(d.id, d.data().name || d.id));
  console.log(`Loaded ${exerciseCatalog.size} exercises from catalog`);

  for (const userDoc of usersSnap.docs) {
    const userId = userDoc.id;
    const templatesSnap = await db.collection('users').doc(userId)
      .collection('templates').limit(500).get();

    for (const tDoc of templatesSnap.docs) {
      const data = tDoc.data();
      const exercises = data.exercises || [];
      let needsUpdate = false;
      const updated = exercises.map(ex => {
        if (!ex.name && ex.exercise_id && exerciseCatalog.has(ex.exercise_id)) {
          needsUpdate = true;
          exercisesResolved++;
          return { ...ex, name: exerciseCatalog.get(ex.exercise_id) };
        }
        return ex;
      });

      if (needsUpdate) {
        if (!dryRun) {
          await tDoc.ref.update({ exercises: updated });
        }
        templatesUpdated++;
      }
    }
    usersProcessed++;
    if (usersProcessed % 100 === 0) console.log(`Processed ${usersProcessed} users...`);
  }

  console.log(`Done. Users: ${usersProcessed}, Templates updated: ${templatesUpdated}, Exercises resolved: ${exercisesResolved}`);
}

main().catch(e => { console.error(e); process.exit(1); });
```

- [ ] **Step 2: Write routine template names backfill script**

```javascript
#!/usr/bin/env node
/**
 * Backfill template_names on routines from template documents.
 * Idempotent — safe to re-run.
 *
 * Usage: GOOGLE_APPLICATION_CREDENTIALS=$FIREBASE_SA_KEY node scripts/backfill_routine_template_names.js [--dry-run]
 */
const admin = require('firebase-admin');
admin.initializeApp();
const db = admin.firestore();

const dryRun = process.argv.includes('--dry-run');

async function main() {
  console.log(`Backfill routine template_names${dryRun ? ' (DRY RUN)' : ''}`);

  const usersSnap = await db.collection('users').limit(10000).get();
  let usersProcessed = 0, routinesUpdated = 0;

  for (const userDoc of usersSnap.docs) {
    const userId = userDoc.id;
    const routinesSnap = await db.collection('users').doc(userId)
      .collection('routines').limit(100).get();

    for (const rDoc of routinesSnap.docs) {
      const data = rDoc.data();
      const templateIds = data.template_ids || data.templateIds || [];
      if (templateIds.length === 0) continue;

      // Batch-read all referenced templates
      const templateRefs = templateIds.map(tid =>
        db.collection('users').doc(userId).collection('templates').doc(tid)
      );
      const templateDocs = await db.getAll(...templateRefs);

      const templateNames = {};
      templateDocs.forEach((doc, i) => {
        templateNames[templateIds[i]] = doc.exists ? (doc.data().name || 'Untitled') : 'Deleted';
      });

      // Only update if template_names is missing or different
      const existing = data.template_names || {};
      const needsUpdate = JSON.stringify(existing) !== JSON.stringify(templateNames);

      if (needsUpdate) {
        if (!dryRun) {
          await rDoc.ref.update({ template_names: templateNames });
        }
        routinesUpdated++;
      }
    }
    usersProcessed++;
    if (usersProcessed % 100 === 0) console.log(`Processed ${usersProcessed} users...`);
  }

  console.log(`Done. Users: ${usersProcessed}, Routines updated: ${routinesUpdated}`);
}

main().catch(e => { console.error(e); process.exit(1); });
```

- [ ] **Step 3: Commit**

```bash
git add scripts/backfill_template_exercise_names.js scripts/backfill_routine_template_names.js
git commit -m "feat: add backfill scripts for template exercise names and routine template names"
```

---

## Phase 2: Shared Module Projections

### Task 17: Add `view: "summary"` to `listWorkouts`

**Files:**
- Modify: `firebase_functions/functions/shared/workouts.js`
- Test: Add to existing workout tests or create new test file

- [ ] **Step 1: Write test for summary view**

Add test (create `tests/shared.workouts-views.test.js` or add to existing):

```javascript
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

// We'll test the summarization function directly
const { summarizeWorkout } = require('../shared/workouts');

describe('summarizeWorkout', () => {
  test('returns compact shape with exercise names and set counts', () => {
    const workout = {
      id: 'w1',
      end_time: '2026-01-29T10:00:00Z',
      start_time: '2026-01-29T09:00:00Z',
      name: 'Push Day',
      source_template_id: 't1',
      exercises: [
        {
          name: 'Bench Press',
          exercise_id: 'bench',
          sets: [
            { reps: 8, weight_kg: 80, type: 'working' },
            { reps: 8, weight_kg: 80, type: 'working' },
            { reps: 6, weight_kg: 85, type: 'working' },
          ],
        },
        {
          name: 'Lateral Raise',
          exercise_id: 'lat_raise',
          sets: [
            { reps: 12, weight_kg: 10, type: 'working' },
          ],
        },
      ],
      analytics: {
        total_sets: 4,
        total_reps: 34,
        total_weight: 355,
      },
    };

    const summary = summarizeWorkout(workout);
    assert.equal(summary.id, 'w1');
    assert.equal(summary.name, 'Push Day');
    assert.equal(summary.exercises.length, 2);
    assert.equal(summary.exercises[0].name, 'Bench Press');
    assert.equal(summary.exercises[0].sets, 3);
    assert.equal(summary.total_sets, 4);
    assert.equal(summary.total_volume, 355);
    // Should NOT have per-set data
    assert.equal(summary.exercises[0].weight_kg, undefined);
    assert.equal(summary.exercises[0].reps, undefined);
  });

  test('handles workout with no exercises', () => {
    const workout = { id: 'w2', end_time: '2026-01-29T10:00:00Z' };
    const summary = summarizeWorkout(workout);
    assert.equal(summary.id, 'w2');
    assert.deepEqual(summary.exercises, []);
  });
});
```

- [ ] **Step 2: Add summarizeWorkout to shared/workouts.js and export it**

Add near the top of `shared/workouts.js`:

```javascript
/**
 * Compact a workout to summary shape for agent consumption.
 * Drops per-set data, keeps exercise names and counts.
 */
function summarizeWorkout(w) {
  const exercises = (w.exercises || []).map(ex => ({
    name: ex.name || null,
    exercise_id: ex.exercise_id || null,
    sets: (ex.sets || []).length,
  }));

  const startTime = w.start_time ? new Date(w.start_time) : null;
  const endTime = w.end_time ? new Date(w.end_time) : null;
  const durationMin = (startTime && endTime)
    ? Math.round((endTime - startTime) / (1000 * 60))
    : null;

  return {
    id: w.id,
    end_time: w.end_time,
    name: w.name || null,
    source_template_id: w.source_template_id || null,
    exercises,
    total_sets: w.analytics?.total_sets || null,
    total_volume: w.analytics?.total_weight || null,
    duration_min: durationMin,
  };
}
```

Export it: add `summarizeWorkout` to the module.exports.

- [ ] **Step 3: Add view parameter to listWorkouts**

In `listWorkouts()`, add `view` to the options destructure and apply summarization:

```javascript
async function listWorkouts(db, userId, opts = {}) {
  // ... existing query logic ...

  // Apply view projection
  const outputItems = opts.view === 'summary'
    ? items.map(summarizeWorkout)
    : items;

  return {
    items: outputItems,
    analytics: computeListAnalytics(items),
    hasMore,
    nextCursor: hasMore ? items[items.length - 1]?.start_time : null,
  };
}
```

- [ ] **Step 4: Run tests and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/workouts.js firebase_functions/functions/tests/shared.workouts-views.test.js
git commit -m "feat(workouts): add view=summary support to listWorkouts"
```

### Task 18: Add `view: "summary"` to `listTemplates`

**Files:**
- Modify: `firebase_functions/functions/shared/templates.js:110-114`
- Test: `firebase_functions/functions/tests/shared.templates.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('listTemplates - view support', () => {
  test('view=summary returns compact shape with exercise names', async () => {
    const store = {
      'users/u1/templates/t1': {
        name: 'Push Day',
        description: 'Chest and shoulders',
        exercises: [
          { exercise_id: 'bench', name: 'Bench Press', position: 0, sets: [{ reps: 8 }, { reps: 8 }] },
          { exercise_id: 'ohp', name: 'Overhead Press', position: 1, sets: [{ reps: 10 }] },
        ],
        analytics: { total_volume: 5000 },
        created_at: 'ts',
      },
    };
    const db = createMockDb(store);

    const result = await listTemplates(db, 'u1', { view: 'summary' });
    assert.equal(result.items.length, 1);
    const t = result.items[0];
    assert.equal(t.name, 'Push Day');
    assert.equal(t.exercise_count, 2);
    assert.deepEqual(t.exercise_names, ['Bench Press', 'Overhead Press']);
    // Should NOT have full exercise objects
    assert.equal(t.exercises, undefined);
    assert.equal(t.analytics, undefined);
  });

  test('default view returns full documents (backwards compatible)', async () => {
    const store = {
      'users/u1/templates/t1': {
        name: 'Push Day',
        exercises: [{ exercise_id: 'bench', sets: [{ reps: 8 }] }],
      },
    };
    const db = createMockDb(store);

    const result = await listTemplates(db, 'u1');
    assert.ok(result.items[0].exercises, 'Default view should include exercises');
  });
});
```

- [ ] **Step 2: Implement view support in listTemplates**

```javascript
async function listTemplates(db, userId, opts = {}) {
  const snapshot = await templatesCol(db, userId).limit(500).get();
  const items = snapshot.docs.map(doc => ({ id: doc.id, ...doc.data() }));

  if (opts.view === 'summary') {
    const summaries = items.map(t => ({
      id: t.id,
      name: t.name,
      description: t.description || null,
      exercise_count: (t.exercises || []).length,
      exercise_names: (t.exercises || []).map(ex => ex.name || ex.exercise_id || 'Unknown'),
    }));
    return { items: summaries, count: summaries.length };
  }

  return { items, count: items.length };
}
```

- [ ] **Step 3: Run tests and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/templates.js firebase_functions/functions/tests/shared.templates.test.js
git commit -m "feat(templates): add view=summary support to listTemplates"
```

### Task 19: Add `include_templates` to `getRoutine`

**Files:**
- Modify: `firebase_functions/functions/shared/routines.js`
- Test: `firebase_functions/functions/tests/shared.routines.test.js`

- [ ] **Step 1: Write failing test**

```javascript
describe('getRoutine - include_templates', () => {
  test('returns inline template summaries when include_templates=true', async () => {
    const store = {
      'users/u1': { activeRoutineId: 'r1' },  // needed for is_active enrichment
      'users/u1/routines/r1': {
        name: 'PPL',
        template_ids: ['t1', 't2'],
        template_names: { t1: 'Push Day', t2: 'Pull Day' },
        frequency: 2,
      },
      'users/u1/templates/t1': {
        name: 'Push Day',
        exercises: [
          { exercise_id: 'bench', name: 'Bench Press', sets: [{}, {}] },
          { exercise_id: 'ohp', name: 'Overhead Press', sets: [{}] },
        ],
      },
      'users/u1/templates/t2': {
        name: 'Pull Day',
        exercises: [
          { exercise_id: 'row', name: 'Barbell Row', sets: [{}, {}, {}] },
        ],
      },
    };
    const db = createMockDb(store);

    const result = await getRoutine(db, 'u1', 'r1', { include_templates: true });
    assert.equal(result.name, 'PPL');
    assert.equal(result.is_active, true);  // verify is_active preserved
    assert.equal(result.templates.length, 2);
    assert.equal(result.templates[0].name, 'Push Day');
    assert.deepEqual(result.templates[0].exercise_names, ['Bench Press', 'Overhead Press']);
    assert.equal(result.templates[0].exercise_count, 2);
    assert.equal(result.templates[1].name, 'Pull Day');
    // Should NOT include full exercise objects
    assert.equal(result.templates[0].exercises, undefined);
  });

  test('returns routine without templates by default, with is_active', async () => {
    const store = {
      'users/u1': { activeRoutineId: 'r1' },
      'users/u1/routines/r1': {
        name: 'PPL',
        template_ids: ['t1'],
        frequency: 1,
      },
    };
    const db = createMockDb(store);

    const result = await getRoutine(db, 'u1', 'r1');
    assert.equal(result.templates, undefined);
    assert.equal(result.is_active, true);  // verify is_active preserved
  });
});
```

- [ ] **Step 2: Implement include_templates in getRoutine**

Add an `opts` parameter to `getRoutine`, preserving the existing `is_active` enrichment:

```javascript
async function getRoutine(db, userId, routineId, opts = {}) {
  if (!routineId) {
    throw new ValidationError('Missing required parameters', ['routineId']);
  }

  // Preserve existing parallel fetch for is_active enrichment
  const [routineSnap, userSnap] = await Promise.all([
    db.collection('users').doc(userId).collection('routines').doc(routineId).get(),
    db.collection('users').doc(userId).get(),
  ]);

  if (!routineSnap.exists) {
    throw new NotFoundError('Routine not found');
  }

  const routine = { id: routineSnap.id, ...routineSnap.data() };
  const activeRoutineId = userSnap.exists ? userSnap.data().activeRoutineId : null;
  routine.is_active = routine.id === activeRoutineId;

  // Optional: include inline template summaries
  if (opts.include_templates) {
    const templateIds = routine.template_ids || [];
    if (templateIds.length > 0) {
      const templateDocs = await Promise.all(
        templateIds.map(tid =>
          db.collection('users').doc(userId).collection('templates').doc(tid).get()
        )
      );

      routine.templates = templateDocs
        .filter(d => d.exists)
        .map((d, i) => {
          const t = d.data();
          return {
            id: d.id,
            name: t.name || 'Untitled',
            position: i,
            exercise_names: (t.exercises || []).map(ex => ex.name || ex.exercise_id || 'Unknown'),
            exercise_count: (t.exercises || []).length,
          };
        });
    } else {
      routine.templates = [];
    }
  }

  return routine;
}
```

- [ ] **Step 3: Run tests and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/routines.js firebase_functions/functions/tests/shared.routines.test.js
git commit -m "feat(routines): add include_templates option to getRoutine"
```

### Task 20: Add Compact View to `getPlanningContext`

**Files:**
- Modify: `firebase_functions/functions/shared/planning-context.js`
- Test: Create `firebase_functions/functions/tests/shared.planning-context.test.js`

- [ ] **Step 1: Write test for compact view**

```javascript
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const { compactPlanningContext } = require('../shared/planning-context');

describe('compactPlanningContext', () => {
  test('returns compact shape from full planning context', () => {
    const fullCtx = {
      user: {
        id: 'u1',
        name: 'Valter',
        email: 'valter@example.com',  // should be excluded
        subscription_tier: 'premium',  // should be excluded
        attributes: {
          fitness_level: 'intermediate',
          fitness_goal: 'strength',
          weight_format: 'pounds',
        },
      },
      weight_unit: 'lbs',
      activeRoutine: {
        id: 'r1',
        name: 'Full Body A/B/C',
        template_ids: ['t1', 't2'],
        template_names: { t1: 'Workout A1', t2: 'Workout B1' },
        frequency: 3,
        cursor: 1,  // should be excluded
      },
      nextWorkout: {
        templateId: 't2',
        templateIndex: 1,
        templateCount: 2,
        selectionMethod: 'cursor',
        template: { id: 't2', name: 'Workout B1', exercises: [{ name: 'Row' }] },
      },
      templates: [
        { id: 't1', name: 'Workout A1', exerciseCount: 4 },
        { id: 't2', name: 'Workout B1', exerciseCount: 3 },
      ],
      recentWorkoutsSummary: [
        {
          id: 'w1',
          end_time: '2026-01-29',
          source_template_id: 't1',
          exercises: [{ name: 'Bench', working_sets: 3 }],
          total_sets: 20,
          total_volume: 5000,
        },
      ],
      strengthSummary: [
        { id: 'bench', name: 'Bench Press', e1rm: 100, weight: 90, reps: 5 },
      ],
    };

    const compact = compactPlanningContext(fullCtx);

    // User — only essential fields
    assert.equal(compact.user.name, 'Valter');
    assert.equal(compact.user.weight_unit, 'lbs');
    assert.equal(compact.user.fitness_level, 'intermediate');
    assert.equal(compact.user.email, undefined);
    assert.equal(compact.user.subscription_tier, undefined);

    // Active routine — with template names
    assert.equal(compact.activeRoutine.name, 'Full Body A/B/C');
    assert.ok(compact.activeRoutine.template_names);

    // Next workout — template name
    assert.equal(compact.nextWorkout.templateName, 'Workout B1');

    // Recent workouts — compact
    assert.equal(compact.recentWorkouts.length, 1);
    assert.equal(compact.recentWorkouts[0].exercises[0].name, 'Bench');

    // Strength summary — passed through
    assert.equal(compact.strengthSummary.length, 1);
  });
});
```

- [ ] **Step 2: Implement compactPlanningContext**

Add to `shared/planning-context.js`:

```javascript
/**
 * Compact planning context for agent consumption.
 * Matches the shape currently produced by MCP tools.ts compactSnapshot().
 * Uses camelCase field names for MCP compatibility.
 *
 * @param {Object} ctx - Full planning context from getPlanningContext()
 * @returns {Object} Compact context (~2KB)
 */
function compactPlanningContext(ctx) {
  const user = ctx.user ? {
    id: ctx.user.id,
    name: ctx.user.name,
    weight_unit: ctx.weight_unit,
    fitness_level: ctx.user.attributes?.fitness_level || null,
    fitness_goal: ctx.user.attributes?.fitness_goal || null,
  } : null;

  const activeRoutine = ctx.activeRoutine ? {
    id: ctx.activeRoutine.id,
    name: ctx.activeRoutine.name,
    template_ids: ctx.activeRoutine.template_ids,
    template_names: ctx.activeRoutine.template_names || null,
    frequency: ctx.activeRoutine.frequency,
  } : null;

  const nextWorkout = ctx.nextWorkout ? {
    templateId: ctx.nextWorkout.templateId,
    templateIndex: ctx.nextWorkout.templateIndex,
    templateCount: ctx.nextWorkout.templateCount,
    templateName: ctx.nextWorkout.template?.name || null,
  } : null;

  const recentWorkouts = (ctx.recentWorkoutsSummary || []).slice(0, 10).map(w => ({
    id: w.id,
    end_time: w.end_time,
    source_template_id: w.source_template_id,
    exercises: (w.exercises || []).map(ex => ({
      name: ex.name,
      working_sets: ex.working_sets,
    })),
  }));

  // Compute days since last workout
  let daysSinceLastWorkout = null;
  if (recentWorkouts.length > 0 && recentWorkouts[0].end_time) {
    const lastDate = new Date(recentWorkouts[0].end_time);
    daysSinceLastWorkout = Math.floor((Date.now() - lastDate.getTime()) / (1000 * 60 * 60 * 24));
  }

  return {
    user,
    activeRoutine,
    nextWorkout,
    templates: (ctx.templates || []).map(t => ({
      id: t.id,
      name: t.name,
      exerciseCount: t.exerciseCount || t.exercises?.length || 0,
    })),
    recentWorkouts,
    strengthSummary: ctx.strengthSummary || [],
    daysSinceLastWorkout,
  };
}
```

Add `view` support to `getPlanningContext`:

```javascript
async function getPlanningContext(db, userId, options = {}) {
  // ... existing code ...

  const result = { /* ... existing assembly ... */ };

  // Apply view projection
  if (options.view === 'compact') {
    return compactPlanningContext(result);
  }

  return result;
}
```

Export `compactPlanningContext`.

- [ ] **Step 3: Run tests and commit**

Run: `cd firebase_functions/functions && npm test`

```bash
git add firebase_functions/functions/shared/planning-context.js firebase_functions/functions/tests/shared.planning-context.test.js
git commit -m "feat(planning): add compact view to getPlanningContext"
```

### Task 21: Add `include_expired` to `getAnalysisSummary`

Already implemented in Task 5 (Phase 0). The shared module change was included there. No additional work needed.

---

## Phase 3: MCP Consumer Simplification

### Task 22: Simplify MCP tools.ts — Use Shared Projections

**Files:**
- Modify: `mcp_server/src/tools.ts`

- [ ] **Step 1: Delete summarizeWorkout and compactSnapshot from tools.ts**

Remove functions at lines 21-82.

- [ ] **Step 2: Update get_training_snapshot to use shared compact view**

```typescript
server.tool('get_training_snapshot', 'Get compact overview: user profile, active routine, next workout, recent workouts (summary), strength records', {},
  async () => {
    const ctx = await planningContext.getPlanningContext(db, userId, {
      includeTemplateExercises: false,
      workoutLimit: 10,
      view: 'compact',
    });
    return { content: [{ type: 'text' as const, text: JSON.stringify(ctx, null, 2) }] };
  }
);
```

- [ ] **Step 3: Update list_workouts to use shared summary view**

```typescript
server.tool('list_workouts', 'List recent workouts (summaries: date, exercises, set counts). Use get_workout for full set data.', {
  limit: z.number().default(10).describe('Max results (default 10)')
}, async ({ limit }) => {
  const result = await workouts.listWorkouts(db, userId, { limit: limit || 10, view: 'summary' });
  return { content: [{ type: 'text' as const, text: JSON.stringify({
    workouts: result.items,
    analytics: result.analytics,
    hasMore: result.hasMore,
  }, null, 2) }] };
});
```

- [ ] **Step 4: Update list_templates to use shared summary view**

```typescript
server.tool('list_templates', 'List all workout templates (names + IDs, no exercises). Use get_template for full exercise list.', {},
  async () => {
    const result = await templates.listTemplates(db, userId, { view: 'summary' });
    return { content: [{ type: 'text' as const, text: JSON.stringify(result.items, null, 2) }] };
  }
);
```

- [ ] **Step 5: Update get_routine to use include_templates**

```typescript
server.tool('get_routine', 'Get a specific routine with template names and exercise summaries', {
  routine_id: z.string().describe('Routine ID'),
  include_templates: z.boolean().default(true).describe('Include template exercise summaries')
}, async ({ routine_id, include_templates }) => {
  const routine = await routines.getRoutine(db, userId, routine_id, { include_templates });
  return { content: [{ type: 'text' as const, text: JSON.stringify(routine, null, 2) }] };
});
```

- [ ] **Step 6: Build and commit**

Run: `cd mcp_server && npm run build`

```bash
git add mcp_server/src/tools.ts
git commit -m "refactor(mcp): use shared module projections, delete ad-hoc summarization"
```

---

## Phase 4: Documentation

### Task 23: Update Architecture Docs

**Files:**
- Modify: `docs/SYSTEM_ARCHITECTURE.md` — Add data access layer section
- Create: `firebase_functions/functions/shared/ARCHITECTURE.md` — Document projection layer and denormalization policy

- [ ] **Step 1: Create shared module architecture doc**

Write `firebase_functions/functions/shared/ARCHITECTURE.md` covering:
- Module inventory (templates, routines, workouts, planning-context, training-queries, exercises, artifacts)
- View parameter pattern (`view: "summary"` vs default detail)
- Denormalization policy (exercise names on templates, template names on routines)
- Consumer mapping (MCP → summary views, iOS → default detail, agent service → will migrate later)

- [ ] **Step 2: Update SYSTEM_ARCHITECTURE.md data flow section**

Add a "Data Access Patterns" section explaining the three consumption tiers and how shared modules serve them.

- [ ] **Step 3: Commit**

```bash
git add firebase_functions/functions/shared/ARCHITECTURE.md docs/SYSTEM_ARCHITECTURE.md
git commit -m "docs: document shared module projection layer and denormalization policy"
```

---

## Regression Safety: Real-World Test Scenarios

These tests (embedded in Tasks 6-20 above) are designed to catch actual regressions, not just confirm happy paths:

### Exercise Name Scenarios
1. **Name available from block** — converter passes it through (Task 7)
2. **Name missing, catalog has it** — createTemplate resolves from catalog (Task 8)
3. **Name already set by caller** — NOT overwritten by catalog (Task 8)
4. **Catalog entry doesn't exist** — exercise_id used as-is, no error (Task 8)
5. **patchTemplate replaces exercises** — new exercises get names resolved (Task 9)

### Template Name on Routines Scenarios
6. **createRoutine** — names extracted from already-fetched template docs (Task 10)
7. **Template without a name** — defaults to "Untitled" (Task 10)
8. **patchRoutine changes template_ids** — template_names fully rebuilt (Task 11)
9. **deleteTemplate** — entry removed from template_names on affected routines (Task 12)
10. **Template renamed** — template_names updated on referencing routines (Task 14)

### Projection Scenarios
11. **listWorkouts view=summary** — per-set data stripped, exercise names and counts preserved (Task 17)
12. **listTemplates view=summary** — exercise_names array, no full exercise objects (Task 18)
13. **getRoutine include_templates** — inline template summaries with exercise names (Task 19)
14. **getPlanningContext view=compact** — matches current MCP compactSnapshot shape (Task 20)
15. **Default views unchanged** — backwards compatibility: omitting view parameter returns full data (Tasks 17, 18, 20)

### Backwards Compatibility
16. **Existing MCP response shapes** — camelCase field names maintained (Task 22)
17. **listTemplates default** — returns full docs, existing tests still pass (Task 18)
18. **getRoutine without options** — returns same shape as before (Task 19)
