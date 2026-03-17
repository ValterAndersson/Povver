const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const {
  setNestedValue,
  resolvePathValue,
  applyChangesToObject,
  inferRecommendationType,
  applyProgression,
} = require('../shared/progressions');
const { ValidationError } = require('../shared/errors');

// ── Pure helpers ─────────────────────────────────────────────────────────────

describe('setNestedValue', () => {
  test('sets a top-level field', () => {
    const obj = { name: 'old' };
    setNestedValue(obj, 'name', 'new');
    assert.equal(obj.name, 'new');
  });

  test('sets a dotted path', () => {
    const obj = { a: { b: { c: 1 } } };
    setNestedValue(obj, 'a.b.c', 42);
    assert.equal(obj.a.b.c, 42);
  });

  test('sets a bracket-indexed array element', () => {
    const obj = { exercises: [{ weight: 50 }, { weight: 60 }] };
    setNestedValue(obj, 'exercises[1].weight', 65);
    assert.equal(obj.exercises[1].weight, 65);
  });

  test('handles deep nested bracket path (exercises[0].sets[0].weight)', () => {
    const obj = {
      exercises: [{
        name: 'Squat',
        sets: [{ weight: 100, reps: 5 }, { weight: 100, reps: 5 }],
      }],
    };
    setNestedValue(obj, 'exercises[0].sets[1].weight', 105);
    assert.equal(obj.exercises[0].sets[1].weight, 105);
    // Other values untouched
    assert.equal(obj.exercises[0].sets[0].weight, 100);
  });

  test('creates intermediate objects when missing', () => {
    const obj = {};
    setNestedValue(obj, 'a.b.c', 'deep');
    assert.equal(obj.a.b.c, 'deep');
  });

  test('creates intermediate arrays when next segment is numeric', () => {
    const obj = {};
    setNestedValue(obj, 'items[0].name', 'first');
    assert.ok(Array.isArray(obj.items));
    assert.equal(obj.items[0].name, 'first');
  });
});

describe('resolvePathValue', () => {
  test('resolves a top-level field', () => {
    assert.equal(resolvePathValue({ x: 42 }, 'x'), 42);
  });

  test('resolves a dotted path', () => {
    assert.equal(resolvePathValue({ a: { b: 3 } }, 'a.b'), 3);
  });

  test('resolves bracket path', () => {
    const obj = { exercises: [{ sets: [{ weight: 80 }] }] };
    assert.equal(resolvePathValue(obj, 'exercises[0].sets[0].weight'), 80);
  });

  test('returns undefined for missing path', () => {
    assert.equal(resolvePathValue({ a: 1 }, 'b.c'), undefined);
  });

  test('returns undefined when intermediate is null', () => {
    assert.equal(resolvePathValue({ a: null }, 'a.b'), undefined);
  });
});

describe('applyChangesToObject', () => {
  test('returns deep copy with changes applied', () => {
    const original = { exercises: [{ sets: [{ weight: 100 }] }] };
    const result = applyChangesToObject(original, [
      { path: 'exercises[0].sets[0].weight', to: 105 },
    ]);
    assert.equal(result.exercises[0].sets[0].weight, 105);
    // Original untouched
    assert.equal(original.exercises[0].sets[0].weight, 100);
  });

  test('applies multiple changes', () => {
    const obj = { a: 1, b: 2 };
    const result = applyChangesToObject(obj, [
      { path: 'a', to: 10 },
      { path: 'b', to: 20 },
    ]);
    assert.equal(result.a, 10);
    assert.equal(result.b, 20);
  });
});

describe('inferRecommendationType', () => {
  test('returns progression for weight changes', () => {
    const changes = [{ path: 'exercises[0].sets[0].weight', from: 100, to: 105 }];
    assert.equal(inferRecommendationType(changes), 'progression');
  });

  test('returns volume_adjustment for reps-only changes', () => {
    const changes = [{ path: 'exercises[0].sets[0].reps', from: 8, to: 10 }];
    assert.equal(inferRecommendationType(changes), 'volume_adjustment');
  });

  test('returns exercise_swap for exercise path', () => {
    const changes = [{ path: 'exercises[0].exercise_id', from: 'a', to: 'b' }];
    assert.equal(inferRecommendationType(changes), 'exercise_swap');
  });

  test('returns deload when to < from', () => {
    const changes = [{ path: 'some.field', from: 10, to: 5 }];
    assert.equal(inferRecommendationType(changes), 'deload');
  });

  test('defaults to progression for unknown paths', () => {
    const changes = [{ path: 'some.other.field', from: 'a', to: 'b' }];
    assert.equal(inferRecommendationType(changes), 'progression');
  });
});

// ── applyProgression validation (no Firestore needed) ────────────────────────

describe('applyProgression validation', () => {
  // These tests verify that validation throws before touching Firestore,
  // so we pass a null db — it should never be reached.

  test('throws ValidationError when userId is missing', async () => {
    await assert.rejects(
      () => applyProgression(null, '', {
        targetType: 'template',
        targetId: 't1',
        changes: [{ path: 'a', to: 1 }],
        summary: 'test',
      }),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.ok(err.details.missing.includes('userId'));
        return true;
      },
    );
  });

  test('throws ValidationError for invalid targetType', async () => {
    await assert.rejects(
      () => applyProgression(null, 'user1', {
        targetType: 'invalid',
        targetId: 't1',
        changes: [{ path: 'a', to: 1 }],
        summary: 'test',
      }),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.ok(err.message.includes('targetType'));
        return true;
      },
    );
  });

  test('throws ValidationError for empty changes array', async () => {
    await assert.rejects(
      () => applyProgression(null, 'user1', {
        targetType: 'template',
        targetId: 't1',
        changes: [],
        summary: 'test',
      }),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.ok(err.message.includes('changes'));
        return true;
      },
    );
  });

  test('throws ValidationError when summary is missing', async () => {
    await assert.rejects(
      () => applyProgression(null, 'user1', {
        targetType: 'template',
        targetId: 't1',
        changes: [{ path: 'a', to: 1 }],
        summary: '',
      }),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.ok(err.details.missing.includes('summary'));
        return true;
      },
    );
  });
});
