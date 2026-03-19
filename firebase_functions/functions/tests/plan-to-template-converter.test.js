const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const {
  convertPlanBlockToTemplateExercise,
  convertPlanToTemplate,
  convertPlanSetToTemplateSet,
  validatePlanContent,
} = require('../utils/plan-to-template-converter');

describe('convertPlanBlockToTemplateExercise', () => {
  test('extracts exercise_id and sets', () => {
    const block = {
      exercise_id: 'bench_press',
      sets: [{ target: { reps: 10, rir: 2 } }],
    };
    const result = convertPlanBlockToTemplateExercise(block, 0);
    assert.equal(result.exercise_id, 'bench_press');
    assert.equal(result.position, 0);
    assert.equal(result.sets.length, 1);
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
