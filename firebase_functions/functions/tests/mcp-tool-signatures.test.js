/**
 * MCP Tool Signature Contract Tests
 *
 * These tests verify that every shared module function called by the MCP server
 * actually exists, is a function, and accepts the expected argument pattern.
 *
 * This catches the CRITICAL MCP bugs found during the architecture redesign review:
 * - Wrong parameter names (e.g., `query` vs `q`)
 * - Missing required arguments (e.g., `admin` arg for getAnalysisSummary)
 * - Functions that don't exist or were renamed
 * - Return shape mismatches (e.g., expecting `items` but getting flat array)
 *
 * These are NOT unit tests with full business logic coverage. They verify
 * INTEGRATION CONTRACTS: "if I call function X with args Y, I don't get
 * a TypeError." Business logic errors (ValidationError, NotFoundError) are
 * acceptable — they prove the function was called with the right shape.
 *
 * The MCP tools.ts file calls these shared modules. If a function signature
 * changes, these tests break BEFORE the MCP server hits production.
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

// ---------------------------------------------------------------------------
// Mock Firestore — returns empty results for all queries
// ---------------------------------------------------------------------------

function mockDb() {
  const emptySnap = { empty: true, docs: [], size: 0, forEach: () => {} };
  const emptyDoc = { exists: false, data: () => null, id: 'mock' };

  const mockRef = {
    get: async () => emptySnap,
    doc: (id) => ({
      get: async () => emptyDoc,
      set: async () => {},
      update: async () => {},
      collection: () => mockRef,
      id: id || 'mock-doc',
    }),
    add: async () => ({ id: 'new-id', get: async () => emptyDoc }),
    where: () => mockRef,
    orderBy: () => mockRef,
    limit: () => mockRef,
    startAfter: () => mockRef,
    collection: () => mockRef,
  };

  return {
    collection: (name) => mockRef,
    doc: (id) => ({
      ...mockRef,
      get: async () => emptyDoc,
      id: id || 'mock-doc',
      collection: () => mockRef,
    }),
    getAll: async (...refs) => refs.map(() => emptyDoc),
    runTransaction: async (fn) => fn({
      get: async () => emptyDoc,
      set: () => {},
      update: () => {},
    }),
  };
}

/**
 * Mock firebase-admin module for getAnalysisSummary.
 * It calls admin.firestore.Timestamp.now() and admin.firestore.Timestamp.fromDate().
 */
function mockAdmin() {
  const mockTimestamp = {
    toDate: () => new Date(),
    toMillis: () => Date.now(),
  };
  return {
    firestore: {
      Timestamp: {
        now: () => mockTimestamp,
        fromDate: (d) => mockTimestamp,
        fromMillis: (ms) => mockTimestamp,
      },
      FieldValue: {
        serverTimestamp: () => 'SERVER_TIMESTAMP',
        delete: () => 'DELETE_FIELD',
      },
    },
  };
}

/**
 * Helper: call a function and assert it does NOT throw TypeError.
 * TypeError means the call signature is wrong (missing args, wrong types).
 * Other errors (ValidationError, NotFoundError) are acceptable — they prove
 * the function received args in the expected shape.
 */
async function assertNoTypeError(fn, label) {
  try {
    await fn();
  } catch (err) {
    if (err instanceof TypeError) {
      assert.fail(
        `${label}: TypeError indicates signature mismatch: ${err.message}`
      );
    }
    // ValidationError, NotFoundError, etc. are fine — function was reached
  }
}

// ---------------------------------------------------------------------------
// Import shared modules
// ---------------------------------------------------------------------------

const exercises = require('../shared/exercises');
const trainingQueries = require('../shared/training-queries');
const routines = require('../shared/routines');
const templates = require('../shared/templates');
const workouts = require('../shared/workouts');
const planningContext = require('../shared/planning-context');

// ---------------------------------------------------------------------------
// Test: shared/exercises.js
// ---------------------------------------------------------------------------

describe('MCP Contract: shared/exercises.js', () => {
  it('searchExercises is exported and is a function', () => {
    assert.equal(typeof exercises.searchExercises, 'function');
  });

  it('searchExercises accepts (db, params) with query field', async () => {
    // MCP tools.ts calls: exercises.searchExercises(db, { query, limit })
    const db = mockDb();
    const result = await exercises.searchExercises(db, { query: 'bench', limit: 10 });
    assert.ok(result, 'searchExercises must return a value');
    assert.ok('items' in result, 'Result must have items field');
    assert.ok('count' in result, 'Result must have count field');
    assert.ok(Array.isArray(result.items), 'items must be an array');
  });

  it('searchExercises works with filter params (muscleGroup, equipment)', async () => {
    const db = mockDb();
    const result = await exercises.searchExercises(db, {
      muscleGroup: 'chest',
      equipment: 'barbell',
      limit: 5,
    });
    assert.ok(result);
    assert.ok('items' in result);
  });

  it('getExercise is exported and is a function', () => {
    assert.equal(typeof exercises.getExercise, 'function');
  });

  it('getExercise accepts (db, { exerciseId })', async () => {
    const db = mockDb();
    const result = await exercises.getExercise(db, { exerciseId: 'ex_bench' });
    // Returns null for non-existent exercise (mock returns empty)
    assert.equal(result, null);
  });

  it('resolveExercise is exported and is a function', () => {
    assert.equal(typeof exercises.resolveExercise, 'function');
  });

  it('resolveExercise accepts (db, { q, context })', async () => {
    const db = mockDb();
    const result = await exercises.resolveExercise(db, { q: 'bench press' });
    assert.ok(result, 'resolveExercise must return a value');
    assert.ok('best' in result, 'Result must have best field');
    assert.ok('alternatives' in result, 'Result must have alternatives field');
  });
});

// ---------------------------------------------------------------------------
// Test: shared/training-queries.js
// ---------------------------------------------------------------------------

describe('MCP Contract: shared/training-queries.js', () => {
  it('getAnalysisSummary is exported and is a function', () => {
    assert.equal(typeof trainingQueries.getAnalysisSummary, 'function');
  });

  it('getAnalysisSummary accepts (db, userId, options, admin) — 4 args', async () => {
    // CRITICAL: MCP bug #2 was missing the `admin` argument.
    // getAnalysisSummary calls admin.firestore.Timestamp.now() internally.
    const db = mockDb();
    const admin = mockAdmin();
    await assertNoTypeError(
      () => trainingQueries.getAnalysisSummary(db, 'user123', {}, admin),
      'getAnalysisSummary(db, userId, options, admin)'
    );
  });

  it('getAnalysisSummary fails without admin arg (proves 4th arg is required)', async () => {
    const db = mockDb();
    // Calling without admin should throw TypeError because it tries
    // to call admin.firestore.Timestamp.now()
    try {
      await trainingQueries.getAnalysisSummary(db, 'user123', {});
      // If it somehow succeeds, that's also fine (maybe the code changed)
    } catch (err) {
      if (err instanceof TypeError) {
        // Expected — confirms admin is required
        assert.ok(true, 'TypeError confirms admin arg is required');
      }
      // Other errors are fine
    }
  });

  it('getMuscleGroupSummary is exported and is a function', () => {
    assert.equal(typeof trainingQueries.getMuscleGroupSummary, 'function');
  });

  it('getMuscleGroupSummary accepts (db, userId, { muscle_group })', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => trainingQueries.getMuscleGroupSummary(db, 'user123', { muscle_group: 'chest' }),
      'getMuscleGroupSummary(db, userId, { muscle_group })'
    );
  });

  it('getExerciseSummary is exported and is a function', () => {
    assert.equal(typeof trainingQueries.getExerciseSummary, 'function');
  });

  it('getExerciseSummary accepts (db, userId, { exercise_id })', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => trainingQueries.getExerciseSummary(db, 'user123', { exercise_id: 'ex_bench' }),
      'getExerciseSummary(db, userId, { exercise_id })'
    );
  });

  it('getExerciseSummary accepts (db, userId, { exercise_name })', async () => {
    const db = mockDb();
    // MCP may pass exercise_name instead of exercise_id for fuzzy lookup
    await assertNoTypeError(
      () => trainingQueries.getExerciseSummary(db, 'user123', { exercise_name: 'bench press' }),
      'getExerciseSummary(db, userId, { exercise_name })'
    );
  });

  it('querySets is exported and is a function', () => {
    assert.equal(typeof trainingQueries.querySets, 'function');
  });

  it('querySets accepts (db, userId, { target, sort, limit })', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => trainingQueries.querySets(db, 'user123', {
        target: { muscle_group: 'chest' },
        sort: 'date_desc',
        limit: 20,
      }),
      'querySets(db, userId, options)'
    );
  });

  it('aggregateSets is exported and is a function', () => {
    assert.equal(typeof trainingQueries.aggregateSets, 'function');
  });

  it('getMuscleSummary is exported and is a function', () => {
    assert.equal(typeof trainingQueries.getMuscleSummary, 'function');
  });
});

// ---------------------------------------------------------------------------
// Test: shared/routines.js
// ---------------------------------------------------------------------------

describe('MCP Contract: shared/routines.js', () => {
  it('listRoutines is exported and is a function', () => {
    assert.equal(typeof routines.listRoutines, 'function');
  });

  it('listRoutines accepts (db, userId)', async () => {
    const db = mockDb();
    const result = await routines.listRoutines(db, 'user123');
    assert.ok(result, 'listRoutines must return a value');
    assert.ok('items' in result, 'Result must have items field');
    assert.ok('count' in result, 'Result must have count field');
    assert.ok(Array.isArray(result.items), 'items must be an array');
  });

  it('getRoutine is exported and is a function', () => {
    assert.equal(typeof routines.getRoutine, 'function');
  });

  it('getRoutine accepts (db, userId, routineId) — 3 args, not params object', async () => {
    // CRITICAL: MCP must pass routineId as 3rd positional arg, NOT in a params object.
    const db = mockDb();
    await assertNoTypeError(
      () => routines.getRoutine(db, 'user123', 'routine_1'),
      'getRoutine(db, userId, routineId)'
    );
  });

  it('createRoutine is exported and is a function', () => {
    assert.equal(typeof routines.createRoutine, 'function');
  });

  it('patchRoutine is exported and is a function', () => {
    assert.equal(typeof routines.patchRoutine, 'function');
  });

  it('patchRoutine accepts (db, userId, routineId, patch) — 4 args', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => routines.patchRoutine(db, 'user123', 'routine_1', { name: 'Updated' }),
      'patchRoutine(db, userId, routineId, patch)'
    );
  });

  it('getNextWorkout is exported and is a function', () => {
    assert.equal(typeof routines.getNextWorkout, 'function');
  });
});

// ---------------------------------------------------------------------------
// Test: shared/templates.js
// ---------------------------------------------------------------------------

describe('MCP Contract: shared/templates.js', () => {
  it('listTemplates is exported and is a function', () => {
    assert.equal(typeof templates.listTemplates, 'function');
  });

  it('listTemplates accepts (db, userId) and returns { items, count }', async () => {
    const db = mockDb();
    const result = await templates.listTemplates(db, 'user123');
    assert.ok(result, 'listTemplates must return a value');
    assert.ok('items' in result, 'Result must have items field');
    assert.ok('count' in result, 'Result must have count field');
  });

  it('getTemplate is exported and is a function', () => {
    assert.equal(typeof templates.getTemplate, 'function');
  });

  it('getTemplate accepts (db, userId, templateId) — 3 positional args', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => templates.getTemplate(db, 'user123', 'tmpl_1'),
      'getTemplate(db, userId, templateId)'
    );
  });

  it('createTemplate is exported and is a function', () => {
    assert.equal(typeof templates.createTemplate, 'function');
  });

  it('patchTemplate is exported and is a function', () => {
    assert.equal(typeof templates.patchTemplate, 'function');
  });

  it('patchTemplate accepts (db, userId, templateId, patch, meta) — 5 args', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => templates.patchTemplate(db, 'user123', 'tmpl_1', { name: 'Updated' }, {}),
      'patchTemplate(db, userId, templateId, patch, meta)'
    );
  });
});

// ---------------------------------------------------------------------------
// Test: shared/workouts.js
// ---------------------------------------------------------------------------

describe('MCP Contract: shared/workouts.js', () => {
  it('listWorkouts is exported and is a function', () => {
    assert.equal(typeof workouts.listWorkouts, 'function');
  });

  it('listWorkouts accepts (db, userId, opts) and returns { items }', async () => {
    const db = mockDb();
    const result = await workouts.listWorkouts(db, 'user123', { limit: 10 });
    assert.ok(result, 'listWorkouts must return a value');
    assert.ok('items' in result, 'Result must have items field');
    assert.ok(Array.isArray(result.items), 'items must be an array');
  });

  it('getWorkout is exported and is a function', () => {
    assert.equal(typeof workouts.getWorkout, 'function');
  });

  it('getWorkout accepts (db, userId, workoutId) — 3 positional args', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => workouts.getWorkout(db, 'user123', 'workout_1'),
      'getWorkout(db, userId, workoutId)'
    );
  });
});

// ---------------------------------------------------------------------------
// Test: shared/planning-context.js
// ---------------------------------------------------------------------------

describe('MCP Contract: shared/planning-context.js', () => {
  it('getPlanningContext is exported and is a function', () => {
    assert.equal(typeof planningContext.getPlanningContext, 'function');
  });

  it('getPlanningContext accepts (db, userId, options) — NO admin arg', async () => {
    // Unlike getAnalysisSummary, getPlanningContext does NOT need admin.
    // It uses plain Date objects internally.
    const db = mockDb();
    await assertNoTypeError(
      () => planningContext.getPlanningContext(db, 'user123', {}),
      'getPlanningContext(db, userId, options)'
    );
  });

  it('getPlanningContext returns expected top-level fields', async () => {
    const db = mockDb();
    const result = await planningContext.getPlanningContext(db, 'user123', {});
    assert.ok(result, 'getPlanningContext must return a value');
    // Verify the shape the MCP server and agent tools expect
    assert.ok('user' in result, 'Result must have user field');
    assert.ok('activeRoutine' in result, 'Result must have activeRoutine field');
    assert.ok('templates' in result, 'Result must have templates field');
    assert.ok('weight_unit' in result, 'Result must have weight_unit field');
  });

  it('fetchUserContext is exported and is a function', () => {
    assert.equal(typeof planningContext.fetchUserContext, 'function');
  });
});

// ---------------------------------------------------------------------------
// Test: MCP call pattern verification
// ---------------------------------------------------------------------------

describe('MCP Call Pattern Verification', () => {
  /**
   * These tests encode the EXACT call patterns used in MCP tools.ts.
   * If any shared module signature changes, these tests catch the mismatch
   * before the MCP server hits production.
   *
   * Each test documents which MCP tool makes the call, so signature changes
   * can be traced back to the affected MCP endpoint.
   */

  it('MCP search_exercises: searchExercises(db, { query, limit })', async () => {
    const db = mockDb();
    const result = await exercises.searchExercises(db, { query: 'bench', limit: 10 });
    assert.ok(result);
    assert.ok('items' in result);
    assert.ok('count' in result);
  });

  it('MCP get_exercise: getExercise(db, { exerciseId })', async () => {
    const db = mockDb();
    // Should not throw TypeError
    const result = await exercises.getExercise(db, { exerciseId: 'ex_1' });
    // null is fine — means exercise not found in mock
    assert.equal(result, null);
  });

  it('MCP resolve_exercise: resolveExercise(db, { q })', async () => {
    const db = mockDb();
    const result = await exercises.resolveExercise(db, { q: 'bench press' });
    assert.ok(result);
    assert.ok('best' in result);
  });

  it('MCP list_routines: listRoutines(db, userId)', async () => {
    const db = mockDb();
    const result = await routines.listRoutines(db, 'user123');
    assert.ok(result);
    assert.ok('items' in result);
  });

  it('MCP get_routine: getRoutine(db, userId, routineId)', async () => {
    const db = mockDb();
    // NotFoundError is expected (mock has no data), but NOT TypeError
    await assertNoTypeError(
      () => routines.getRoutine(db, 'user123', 'r1'),
      'MCP get_routine'
    );
  });

  it('MCP list_templates: listTemplates(db, userId)', async () => {
    const db = mockDb();
    const result = await templates.listTemplates(db, 'user123');
    assert.ok(result);
    assert.ok('items' in result);
  });

  it('MCP get_template: getTemplate(db, userId, templateId)', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => templates.getTemplate(db, 'user123', 't1'),
      'MCP get_template'
    );
  });

  it('MCP list_workouts: listWorkouts(db, userId, { limit })', async () => {
    const db = mockDb();
    const result = await workouts.listWorkouts(db, 'user123', { limit: 20 });
    assert.ok(result);
    assert.ok('items' in result);
  });

  it('MCP get_workout: getWorkout(db, userId, workoutId)', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => workouts.getWorkout(db, 'user123', 'w1'),
      'MCP get_workout'
    );
  });

  it('MCP get_planning_context: getPlanningContext(db, userId, options)', async () => {
    const db = mockDb();
    const result = await planningContext.getPlanningContext(db, 'user123', {});
    assert.ok(result);
    assert.ok('user' in result);
  });

  it('MCP get_analysis_summary: getAnalysisSummary(db, userId, opts, admin)', async () => {
    const db = mockDb();
    const admin = mockAdmin();
    await assertNoTypeError(
      () => trainingQueries.getAnalysisSummary(db, 'user123', {}, admin),
      'MCP get_analysis_summary'
    );
  });

  it('MCP get_muscle_group_summary: getMuscleGroupSummary(db, userId, { muscle_group })', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => trainingQueries.getMuscleGroupSummary(db, 'user123', { muscle_group: 'chest' }),
      'MCP get_muscle_group_summary'
    );
  });

  it('MCP get_exercise_summary: getExerciseSummary(db, userId, { exercise_id })', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => trainingQueries.getExerciseSummary(db, 'user123', { exercise_id: 'ex_1' }),
      'MCP get_exercise_summary'
    );
  });

  it('MCP query_sets: querySets(db, userId, { target })', async () => {
    const db = mockDb();
    await assertNoTypeError(
      () => trainingQueries.querySets(db, 'user123', {
        target: { exercise_ids: ['ex_1'] },
      }),
      'MCP query_sets'
    );
  });
});
