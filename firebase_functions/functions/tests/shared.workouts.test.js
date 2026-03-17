const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizeExercises,
  computeWorkoutMetrics,
  computeListAnalytics,
  toTimestamp,
  getWorkout,
  listWorkouts,
  deleteWorkout,
  upsertWorkout,
  DEFAULT_LIST_LIMIT,
  MAX_LIST_LIMIT,
} = require('../shared/workouts');

// ---------------------------------------------------------------------------
// Fake Firestore helpers
// ---------------------------------------------------------------------------

/**
 * Build a minimal fake Firestore db for unit tests.
 * Supports collection().doc().get(), collection chaining with orderBy/where/
 * limit/startAfter, and batch writes.
 */
function fakeDb(docs = {}) {
  // docs shape: { 'users/u1/workouts/w1': { id: 'w1', ...data } }
  const deleted = [];
  const written = {};

  function buildDocRef(path) {
    return {
      id: path.split('/').pop(),
      get: async () => {
        const d = docs[path];
        return {
          exists: !!d,
          id: path.split('/').pop(),
          data: () => d || null,
          ref: buildDocRef(path),
        };
      },
      set: async (data, _opts) => { written[path] = data; },
      delete: async () => { deleted.push(path); },
    };
  }

  function buildQuery(collectionPath, constraints = {}) {
    return {
      orderBy: (field, dir) => buildQuery(collectionPath, { ...constraints, orderByField: field, orderByDir: dir }),
      where: (field, op, value) => {
        const wheres = [...(constraints.wheres || []), { field, op, value }];
        return buildQuery(collectionPath, { ...constraints, wheres });
      },
      limit: (n) => buildQuery(collectionPath, { ...constraints, limit: n }),
      startAfter: (cursor) => buildQuery(collectionPath, { ...constraints, startAfter: cursor }),
      get: async () => {
        // Collect docs matching the collection path prefix
        const prefix = collectionPath + '/';
        let matches = Object.entries(docs)
          .filter(([k]) => k.startsWith(prefix) && k.split('/').length === prefix.split('/').length)
          .map(([k, v]) => ({
            id: k.split('/').pop(),
            data: () => v,
            ref: buildDocRef(k),
          }));

        // Apply limit
        if (constraints.limit) matches = matches.slice(0, constraints.limit);

        return {
          docs: matches,
          empty: matches.length === 0,
          size: matches.length,
        };
      },
    };
  }

  return {
    collection: (name) => ({
      doc: (id) => {
        const path = `${name}/${id}`;
        return {
          ...buildDocRef(path),
          collection: (sub) => ({
            doc: (subId) => {
              const subPath = `${path}/${sub}/${subId}`;
              return buildDocRef(subPath);
            },
            orderBy: (field, dir) => buildQuery(`${path}/${sub}`, { orderByField: field, orderByDir: dir }),
            where: (field, op, value) => buildQuery(`${path}/${sub}`, { wheres: [{ field, op, value }] }),
          }),
        };
      },
    }),
    batch: () => {
      const ops = [];
      return {
        delete: (ref) => ops.push({ type: 'delete', ref }),
        commit: async () => { for (const op of ops) if (op.type === 'delete') deleted.push('batch-deleted'); },
      };
    },
    _deleted: deleted,
    _written: written,
  };
}

// ---------------------------------------------------------------------------
// normalizeExercises
// ---------------------------------------------------------------------------

describe('normalizeExercises', () => {
  test('converts weight_kg directly', () => {
    const result = normalizeExercises([{
      exercise_id: 'bench',
      sets: [{ weight_kg: 80, reps: 8 }],
    }]);
    assert.equal(result[0].sets[0].weight_kg, 80);
    assert.equal(result[0].sets[0].reps, 8);
  });

  test('converts weight (legacy) in kg by default', () => {
    const result = normalizeExercises([{
      exercise_id: 'squat',
      sets: [{ weight: 100, reps: 5 }],
    }]);
    assert.equal(result[0].sets[0].weight_kg, 100);
  });

  test('converts weight in lbs to kg', () => {
    const result = normalizeExercises([{
      exercise_id: 'deadlift',
      sets: [{ weight: 225, unit: 'lbs', reps: 3 }],
    }]);
    // 225 / 2.2046226218 ≈ 102.058
    assert.ok(result[0].sets[0].weight_kg > 102 && result[0].sets[0].weight_kg < 103);
  });

  test('converts weight_lbs to kg', () => {
    const result = normalizeExercises([{
      exercise_id: 'press',
      sets: [{ weight_lbs: 135, reps: 10 }],
    }]);
    assert.ok(result[0].sets[0].weight_kg > 61 && result[0].sets[0].weight_kg < 62);
  });

  test('defaults to 0 when no weight provided', () => {
    const result = normalizeExercises([{
      exercise_id: 'pullup',
      sets: [{ reps: 10 }],
    }]);
    assert.equal(result[0].sets[0].weight_kg, 0);
  });

  test('handles empty/non-array input', () => {
    assert.deepEqual(normalizeExercises(null), []);
    assert.deepEqual(normalizeExercises(undefined), []);
    assert.deepEqual(normalizeExercises('not an array'), []);
  });

  test('normalises exerciseId to exercise_id', () => {
    const result = normalizeExercises([{ exerciseId: 'curl', sets: [] }]);
    assert.equal(result[0].exercise_id, 'curl');
  });

  test('defaultCompleted controls is_completed', () => {
    const resultTrue = normalizeExercises([{ exercise_id: 'x', sets: [{ reps: 1 }] }], true);
    assert.equal(resultTrue[0].sets[0].is_completed, true);

    const resultFalse = normalizeExercises([{ exercise_id: 'x', sets: [{ reps: 1 }] }], false);
    assert.equal(resultFalse[0].sets[0].is_completed, false);
  });
});

// ---------------------------------------------------------------------------
// computeWorkoutMetrics
// ---------------------------------------------------------------------------

describe('computeWorkoutMetrics', () => {
  test('computes totals from weight_kg', () => {
    const m = computeWorkoutMetrics({
      exercises: [{
        sets: [
          { weight_kg: 100, reps: 5 },
          { weight_kg: 80, reps: 8 },
        ],
      }],
    });
    assert.equal(m.totalSets, 2);
    assert.equal(m.totalReps, 13);
    assert.equal(m.totalVolume, 100 * 5 + 80 * 8);
    assert.equal(m.exerciseCount, 1);
  });

  test('falls back to weight if weight_kg is absent', () => {
    const m = computeWorkoutMetrics({
      exercises: [{
        sets: [{ weight: 60, reps: 10 }],
      }],
    });
    assert.equal(m.totalVolume, 600);
  });

  test('computes duration from start_time/end_time', () => {
    const m = computeWorkoutMetrics({
      start_time: '2025-01-01T10:00:00Z',
      end_time: '2025-01-01T11:30:00Z',
      exercises: [],
    });
    assert.equal(m.duration, 90);
  });

  test('handles missing exercises', () => {
    const m = computeWorkoutMetrics({});
    assert.equal(m.totalSets, 0);
    assert.equal(m.totalVolume, 0);
    assert.equal(m.exerciseCount, 0);
  });
});

// ---------------------------------------------------------------------------
// computeListAnalytics
// ---------------------------------------------------------------------------

describe('computeListAnalytics', () => {
  test('returns zeroed analytics for empty list', () => {
    const a = computeListAnalytics([]);
    assert.equal(a.totalWorkouts, 0);
    assert.equal(a.totalVolume, 0);
    assert.equal(a.averageDuration, null);
  });

  test('aggregates volume from weight_kg', () => {
    const a = computeListAnalytics([
      { exercises: [{ exercise_id: 'bench', sets: [{ weight_kg: 80, reps: 5 }] }] },
      { exercises: [{ exercise_id: 'bench', sets: [{ weight_kg: 90, reps: 3 }] }] },
    ]);
    assert.equal(a.totalVolume, 80 * 5 + 90 * 3);
    assert.equal(a.totalWorkouts, 2);
  });

  test('counts exercise frequency', () => {
    const a = computeListAnalytics([
      { exercises: [{ exercise_id: 'bench', sets: [] }, { exercise_id: 'squat', sets: [] }] },
      { exercises: [{ exercise_id: 'bench', sets: [] }] },
    ]);
    assert.equal(a.exerciseFrequency['bench'], 2);
    assert.equal(a.exerciseFrequency['squat'], 1);
  });
});

// ---------------------------------------------------------------------------
// getWorkout
// ---------------------------------------------------------------------------

describe('getWorkout', () => {
  test('throws INVALID_ARGUMENT if userId missing', async () => {
    const db = fakeDb();
    await assert.rejects(() => getWorkout(db, null, 'w1'), (err) => {
      assert.equal(err.code, 'INVALID_ARGUMENT');
      assert.equal(err.httpStatus, 400);
      return true;
    });
  });

  test('throws INVALID_ARGUMENT if workoutId missing', async () => {
    const db = fakeDb();
    await assert.rejects(() => getWorkout(db, 'u1', ''), (err) => {
      assert.equal(err.code, 'INVALID_ARGUMENT');
      return true;
    });
  });

  test('throws NOT_FOUND for non-existent workout', async () => {
    const db = fakeDb();
    await assert.rejects(() => getWorkout(db, 'u1', 'missing'), (err) => {
      assert.equal(err.code, 'NOT_FOUND');
      assert.equal(err.httpStatus, 404);
      return true;
    });
  });

  test('returns workout with metrics for existing doc', async () => {
    const db = fakeDb({
      'users/u1/workouts/w1': {
        exercises: [{ sets: [{ weight_kg: 50, reps: 10 }] }],
        start_time: '2025-01-01T10:00:00Z',
        end_time: '2025-01-01T11:00:00Z',
      },
    });
    const result = await getWorkout(db, 'u1', 'w1');
    assert.equal(result.workout.id, 'w1');
    assert.equal(result.metrics.totalVolume, 500);
    assert.equal(result.metrics.duration, 60);
    assert.equal(result.template, null);
  });
});

// ---------------------------------------------------------------------------
// listWorkouts
// ---------------------------------------------------------------------------

describe('listWorkouts', () => {
  test('throws INVALID_ARGUMENT if userId missing', async () => {
    const db = fakeDb();
    await assert.rejects(() => listWorkouts(db, null), (err) => {
      assert.equal(err.code, 'INVALID_ARGUMENT');
      return true;
    });
  });

  test('returns empty items for no workouts', async () => {
    const db = fakeDb();
    const result = await listWorkouts(db, 'u1');
    assert.deepEqual(result.items, []);
    assert.equal(result.hasMore, false);
    assert.equal(result.nextCursor, null);
  });

  test('clamps limit to MAX_LIST_LIMIT', async () => {
    // Just verify the function does not throw with extreme limits
    const db = fakeDb();
    const result = await listWorkouts(db, 'u1', { limit: 9999 });
    assert.deepEqual(result.items, []);
  });

  test('clamps limit minimum to 1', async () => {
    const db = fakeDb();
    const result = await listWorkouts(db, 'u1', { limit: -5 });
    assert.deepEqual(result.items, []);
  });
});

// ---------------------------------------------------------------------------
// deleteWorkout
// ---------------------------------------------------------------------------

describe('deleteWorkout', () => {
  test('throws if userId missing', async () => {
    const db = fakeDb();
    await assert.rejects(() => deleteWorkout(db, null, 'w1'), (err) => {
      assert.equal(err.httpStatus, 401);
      return true;
    });
  });

  test('throws if workoutId missing', async () => {
    const db = fakeDb();
    await assert.rejects(() => deleteWorkout(db, 'u1', ''), (err) => {
      assert.equal(err.code, 'INVALID_ARGUMENT');
      return true;
    });
  });

  test('throws NOT_FOUND for non-existent workout', async () => {
    const db = fakeDb();
    await assert.rejects(() => deleteWorkout(db, 'u1', 'gone'), (err) => {
      assert.equal(err.code, 'NOT_FOUND');
      assert.equal(err.httpStatus, 404);
      return true;
    });
  });

  test('deletes existing workout', async () => {
    const db = fakeDb({ 'users/u1/workouts/w1': { name: 'Leg Day' } });
    const result = await deleteWorkout(db, 'u1', 'w1');
    assert.equal(result.deleted, true);
    assert.equal(result.workout_id, 'w1');
  });
});

// ---------------------------------------------------------------------------
// upsertWorkout — validation only (no Firestore admin mocking needed)
// ---------------------------------------------------------------------------

describe('upsertWorkout validation', () => {
  const fakeDeps = {
    AnalyticsCalc: { calculateWorkoutAnalytics: async () => ({ workoutAnalytics: {}, updatedExercises: null }) },
    generateSetFactsForWorkout: () => [],
    writeSetFactsInChunks: async () => {},
    updateSeriesForWorkout: async () => {},
  };

  test('throws if userId missing', async () => {
    const db = fakeDb();
    await assert.rejects(
      () => upsertWorkout(db, null, { exercises: [] }, fakeDeps),
      (err) => { assert.equal(err.code, 'INVALID_ARGUMENT'); return true; }
    );
  });

  test('throws if exercises not an array', async () => {
    const db = fakeDb();
    await assert.rejects(
      () => upsertWorkout(db, 'u1', { exercises: 'not-array' }, fakeDeps),
      (err) => { assert.equal(err.code, 'INVALID_ARGUMENT'); return true; }
    );
  });

  test('throws if end_time missing', async () => {
    const db = fakeDb();
    await assert.rejects(
      () => upsertWorkout(db, 'u1', { exercises: [] }, fakeDeps),
      (err) => {
        assert.match(err.message, /end_time/);
        return true;
      }
    );
  });
});
