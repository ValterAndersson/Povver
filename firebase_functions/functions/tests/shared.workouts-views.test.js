const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

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
    assert.equal(summary.duration_min, 60);
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

  test('handles null/missing timestamps', () => {
    const workout = { id: 'w3' };
    const summary = summarizeWorkout(workout);
    assert.equal(summary.duration_min, null);
  });
});
