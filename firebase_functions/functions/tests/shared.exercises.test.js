const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

const {
  buildFilters,
  applyTextSearch,
  applyMemoryFilters,
  filterCanonical,
  projectFields,
  scoreCandidate,
} = require('../shared/exercises');

// ---------------------------------------------------------------------------
// Sample data
// ---------------------------------------------------------------------------

function makeExercise(overrides = {}) {
  return {
    id: 'ex_bench',
    name: 'Bench Press',
    category: 'compound',
    equipment: ['barbell'],
    muscles: {
      primary: ['chest'],
      secondary: ['triceps', 'front_delt'],
      category: ['chest', 'arms'],
    },
    movement: { type: 'push', split: 'upper' },
    metadata: { level: 'intermediate', plane_of_motion: 'sagittal', unilateral: false },
    execution_notes: ['Keep shoulder blades retracted'],
    common_mistakes: ['Bouncing bar off chest'],
    programming_use_cases: ['strength', 'hypertrophy'],
    stimulus_tags: ['horizontal_push'],
    status: 'approved',
    ...overrides,
  };
}

const EXERCISES = [
  makeExercise(),
  makeExercise({
    id: 'ex_squat',
    name: 'Back Squat',
    category: 'compound',
    equipment: ['barbell'],
    muscles: { primary: ['quads'], secondary: ['glutes', 'hamstrings'], category: ['legs'] },
    movement: { type: 'squat', split: 'lower' },
    metadata: { level: 'intermediate', plane_of_motion: 'sagittal', unilateral: false },
    stimulus_tags: ['knee_dominant'],
    programming_use_cases: ['strength'],
    status: 'approved',
  }),
  makeExercise({
    id: 'ex_curl',
    name: 'Dumbbell Biceps Curl',
    category: 'isolation',
    equipment: ['dumbbell'],
    muscles: { primary: ['biceps'], secondary: [], category: ['arms'] },
    movement: { type: 'curl', split: 'upper' },
    metadata: { level: 'beginner', plane_of_motion: 'sagittal', unilateral: true },
    stimulus_tags: ['biceps_isolation'],
    programming_use_cases: ['hypertrophy'],
    status: 'approved',
  }),
  makeExercise({
    id: 'ex_merged',
    name: 'Flat Bench Press',
    status: 'merged',
    merged_into: 'ex_bench',
    muscles: { primary: ['chest'], secondary: [], category: ['chest'] },
  }),
];

// ---------------------------------------------------------------------------
// buildFilters
// ---------------------------------------------------------------------------

describe('buildFilters', () => {
  it('returns empty arrays when no params provided', () => {
    const { where, memoryFilters } = buildFilters({});
    assert.deepStrictEqual(where, []);
    assert.deepStrictEqual(memoryFilters, []);
  });

  it('places first array filter in Firestore where clause', () => {
    const { where, memoryFilters } = buildFilters({ muscleGroup: 'chest' });
    assert.equal(where.length, 1);
    assert.equal(where[0].field, 'muscles.category');
    assert.equal(where[0].operator, 'array-contains');
    assert.equal(where[0].value, 'chest');
    assert.equal(memoryFilters.length, 0);
  });

  it('sends second array filter to memoryFilters', () => {
    const { where, memoryFilters } = buildFilters({
      muscleGroup: 'chest',
      primaryMuscle: 'pectoralis',
    });
    assert.equal(where.length, 1);
    assert.equal(memoryFilters.length, 1);
    assert.equal(memoryFilters[0].field, 'muscles.primary');
  });

  it('handles comma-separated values as array-contains-any', () => {
    const { where } = buildFilters({ muscleGroup: 'chest,back' });
    assert.equal(where[0].operator, 'array-contains-any');
    assert.deepStrictEqual(where[0].value, ['chest', 'back']);
  });

  it('adds equality filters for non-array fields', () => {
    const { where } = buildFilters({ difficulty: 'beginner', category: 'isolation' });
    assert.equal(where.length, 2);
    assert.ok(where.some(w => w.field === 'metadata.level' && w.value === 'beginner'));
    assert.ok(where.some(w => w.field === 'category' && w.value === 'isolation'));
  });

  it('handles unilateral boolean conversion', () => {
    const { where } = buildFilters({ unilateral: 'true' });
    const f = where.find(w => w.field === 'metadata.unilateral');
    assert.ok(f);
    assert.strictEqual(f.value, true);
  });
});

// ---------------------------------------------------------------------------
// applyTextSearch
// ---------------------------------------------------------------------------

describe('applyTextSearch', () => {
  it('returns all exercises when query is falsy', () => {
    const result = applyTextSearch(EXERCISES, '');
    assert.equal(result.length, EXERCISES.length);
  });

  it('filters by name substring', () => {
    const result = applyTextSearch(EXERCISES, 'bench');
    assert.ok(result.some(ex => ex.id === 'ex_bench'));
    assert.ok(result.some(ex => ex.id === 'ex_merged')); // "Flat Bench Press"
    assert.ok(!result.some(ex => ex.id === 'ex_squat'));
  });

  it('strips equipment prefix for fuzzy matching', () => {
    const result = applyTextSearch(EXERCISES, 'barbell bench press');
    // "barbell" is equipment prefix, stripped to "bench press", matches name
    assert.ok(result.some(ex => ex.id === 'ex_bench'));
  });

  it('matches across name + equipment fields (multi-word)', () => {
    const result = applyTextSearch(EXERCISES, 'barbell squat');
    // "barbell" in equipment, "squat" in name "Back Squat"
    assert.ok(result.some(ex => ex.id === 'ex_squat'));
  });

  it('searches in category', () => {
    const result = applyTextSearch(EXERCISES, 'isolation');
    assert.ok(result.some(ex => ex.id === 'ex_curl'));
  });

  it('searches in muscles.primary', () => {
    const result = applyTextSearch(EXERCISES, 'quads');
    assert.ok(result.some(ex => ex.id === 'ex_squat'));
  });

  it('searches in execution_notes', () => {
    const result = applyTextSearch(EXERCISES, 'shoulder blades');
    assert.ok(result.some(ex => ex.id === 'ex_bench'));
  });

  it('searches in common_mistakes', () => {
    const result = applyTextSearch(EXERCISES, 'bouncing');
    assert.ok(result.some(ex => ex.id === 'ex_bench'));
  });

  it('searches in programming_use_cases', () => {
    const result = applyTextSearch(EXERCISES, 'hypertrophy');
    assert.ok(result.some(ex => ex.id === 'ex_bench'));
    assert.ok(result.some(ex => ex.id === 'ex_curl'));
  });

  it('searches in stimulus_tags', () => {
    const result = applyTextSearch(EXERCISES, 'knee_dominant');
    assert.ok(result.some(ex => ex.id === 'ex_squat'));
  });
});

// ---------------------------------------------------------------------------
// applyMemoryFilters
// ---------------------------------------------------------------------------

describe('applyMemoryFilters', () => {
  it('returns all when no filters', () => {
    assert.equal(applyMemoryFilters(EXERCISES, []).length, EXERCISES.length);
  });

  it('filters array-contains (single value)', () => {
    const result = applyMemoryFilters(EXERCISES, [
      { field: 'muscles.primary', value: 'biceps', isArray: false },
    ]);
    assert.equal(result.length, 1);
    assert.equal(result[0].id, 'ex_curl');
  });

  it('filters array-contains-any (multiple values)', () => {
    const result = applyMemoryFilters(EXERCISES, [
      { field: 'muscles.primary', value: ['biceps', 'quads'], isArray: true },
    ]);
    assert.equal(result.length, 2);
  });

  it('handles nested fields', () => {
    const result = applyMemoryFilters(EXERCISES, [
      { field: 'muscles.category', value: 'legs', isArray: false },
    ]);
    assert.equal(result.length, 1);
    assert.equal(result[0].id, 'ex_squat');
  });

  it('returns empty when field does not exist', () => {
    const result = applyMemoryFilters(EXERCISES, [
      { field: 'nonexistent.field', value: 'x', isArray: false },
    ]);
    assert.equal(result.length, 0);
  });
});

// ---------------------------------------------------------------------------
// filterCanonical
// ---------------------------------------------------------------------------

describe('filterCanonical', () => {
  it('removes merged exercises', () => {
    const result = filterCanonical(EXERCISES);
    assert.ok(!result.some(ex => ex.id === 'ex_merged'));
    assert.equal(result.length, 3);
  });

  it('removes exercises with status "merged"', () => {
    const data = [
      makeExercise({ id: 'a', status: 'merged' }),
      makeExercise({ id: 'b', status: 'approved' }),
    ];
    const result = filterCanonical(data);
    assert.equal(result.length, 1);
    assert.equal(result[0].id, 'b');
  });
});

// ---------------------------------------------------------------------------
// projectFields
// ---------------------------------------------------------------------------

describe('projectFields', () => {
  it('"minimal" returns only id and name', () => {
    const result = projectFields(EXERCISES, 'minimal');
    assert.deepStrictEqual(Object.keys(result[0]).sort(), ['id', 'name']);
  });

  it('"lean" returns id, name, category, equipment', () => {
    const result = projectFields(EXERCISES, 'lean');
    assert.deepStrictEqual(Object.keys(result[0]).sort(), ['category', 'equipment', 'id', 'name']);
    // equipment is sliced to max 1
    assert.ok(result[0].equipment.length <= 1);
  });

  it('"full" returns all fields', () => {
    const result = projectFields(EXERCISES, 'full');
    assert.ok(Object.keys(result[0]).length > 4);
  });
});

// ---------------------------------------------------------------------------
// scoreCandidate
// ---------------------------------------------------------------------------

describe('scoreCandidate', () => {
  it('gives +1 for approved status', () => {
    const score = scoreCandidate(makeExercise({ status: 'approved' }), {});
    assert.ok(score >= 1);
  });

  it('gives +1 for bodyweight (empty equipment)', () => {
    const score = scoreCandidate(makeExercise({ equipment: [] }), {});
    // approved (+1) + bodyweight (+1) = 2
    assert.equal(score, 2);
  });

  it('gives +2 when equipment matches context', () => {
    const score = scoreCandidate(
      makeExercise({ equipment: ['barbell'], status: 'draft' }),
      { available_equipment: ['barbell'] }
    );
    // equipment match (+2), no approved bonus
    assert.equal(score, 2);
  });

  it('gives 0 for non-approved, non-matching, non-bodyweight', () => {
    const score = scoreCandidate(
      makeExercise({ equipment: ['cable'], status: 'draft' }),
      { available_equipment: ['barbell'] }
    );
    assert.equal(score, 0);
  });
});
