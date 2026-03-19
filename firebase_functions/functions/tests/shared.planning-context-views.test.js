const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const { compactPlanningContext } = require('../shared/planning-context');

describe('compactPlanningContext', () => {
  test('returns compact shape from full planning context', () => {
    const fullCtx = {
      user: {
        id: 'u1',
        name: 'Valter',
        email: 'valter@example.com',
        subscription_tier: 'premium',
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
        cursor: 1,
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
          end_time: '2026-01-29T10:00:00Z',
          source_template_id: 't1',
          exercises: [{ name: 'Bench Press', working_sets: 3 }],
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

    // Active routine — with template names, no cursor
    assert.equal(compact.activeRoutine.name, 'Full Body A/B/C');
    assert.ok(compact.activeRoutine.template_names);
    assert.equal(compact.activeRoutine.cursor, undefined);

    // Next workout — template name from nested template
    assert.equal(compact.nextWorkout.templateName, 'Workout B1');
    assert.equal(compact.nextWorkout.selectionMethod, undefined);

    // Recent workouts — compact with exercise summaries
    assert.equal(compact.recentWorkouts.length, 1);
    assert.equal(compact.recentWorkouts[0].exercises[0].name, 'Bench Press');
    assert.equal(compact.recentWorkouts[0].total_sets, undefined);

    // Strength summary — passed through
    assert.equal(compact.strengthSummary.length, 1);

    // Days since last workout — computed
    assert.equal(typeof compact.daysSinceLastWorkout, 'number');
    assert.ok(compact.daysSinceLastWorkout > 0);
  });

  test('handles null/missing sections', () => {
    const compact = compactPlanningContext({});
    assert.equal(compact.user, null);
    assert.equal(compact.activeRoutine, null);
    assert.equal(compact.nextWorkout, null);
    assert.deepEqual(compact.templates, []);
    assert.deepEqual(compact.recentWorkouts, []);
    assert.deepEqual(compact.strengthSummary, []);
    assert.equal(compact.daysSinceLastWorkout, null);
  });
});
