const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const {
  buildStrengthSummary,
  sanitizeUserProfile,
  SENSITIVE_USER_FIELDS,
} = require('../shared/planning-context');

// --- buildStrengthSummary ---

describe('buildStrengthSummary', () => {
  test('returns empty array for no workouts', () => {
    assert.deepEqual(buildStrengthSummary([]), []);
  });

  test('returns empty array for workouts without exercises', () => {
    const workouts = [{ id: 'w1' }, { id: 'w2', exercises: [] }];
    assert.deepEqual(buildStrengthSummary(workouts), []);
  });

  test('extracts top exercise by e1rm', () => {
    const workouts = [{
      exercises: [{
        exercise_id: 'bench',
        name: 'Bench Press',
        sets: [
          { weight_kg: 100, reps: 5 },
          { weight_kg: 80, reps: 10 },
        ],
      }],
    }];

    const result = buildStrengthSummary(workouts);
    assert.equal(result.length, 1);
    assert.equal(result[0].id, 'bench');
    assert.equal(result[0].name, 'Bench Press');
    assert.equal(result[0].weight, 100);
    assert.equal(result[0].reps, 5);
    // e1rm = 100 * (1 + 5/30) = 116.7
    assert.equal(result[0].e1rm, 116.7);
  });

  test('skips exercises without exercise_id', () => {
    const workouts = [{
      exercises: [{
        name: 'Mystery Exercise',
        sets: [{ weight_kg: 50, reps: 8 }],
      }],
    }];

    assert.deepEqual(buildStrengthSummary(workouts), []);
  });

  test('skips bodyweight exercises (zero weight)', () => {
    const workouts = [{
      exercises: [{
        exercise_id: 'pullup',
        name: 'Pull-up',
        sets: [{ weight_kg: 0, reps: 10 }],
      }],
    }];

    assert.deepEqual(buildStrengthSummary(workouts), []);
  });

  test('skips sets with reps > 12 for e1rm calculation', () => {
    const workouts = [{
      exercises: [{
        exercise_id: 'curl',
        name: 'Curl',
        sets: [{ weight_kg: 20, reps: 15 }],
      }],
    }];

    // High rep set: maxWeight=20 but e1rm won't be computed (reps > 12)
    // So e1rm = 0 and it gets filtered out
    assert.deepEqual(buildStrengthSummary(workouts), []);
  });

  test('keeps best e1rm across multiple workouts', () => {
    const workouts = [
      {
        exercises: [{
          exercise_id: 'squat',
          name: 'Squat',
          sets: [{ weight_kg: 120, reps: 3 }],
        }],
      },
      {
        exercises: [{
          exercise_id: 'squat',
          name: 'Squat',
          sets: [{ weight_kg: 100, reps: 8 }],
        }],
      },
    ];

    const result = buildStrengthSummary(workouts);
    assert.equal(result.length, 1);
    // First workout: 120 * (1 + 3/30) = 132
    // Second workout: 100 * (1 + 8/30) = 126.7
    // Best = 132
    assert.equal(result[0].e1rm, 132);
    assert.equal(result[0].weight, 120);
  });

  test('sorts by e1rm descending and limits to 15', () => {
    const exercises = [];
    for (let i = 0; i < 20; i++) {
      exercises.push({
        exercise_id: `ex-${i}`,
        name: `Exercise ${i}`,
        sets: [{ weight_kg: (i + 1) * 10, reps: 5 }],
      });
    }

    const result = buildStrengthSummary([{ exercises }]);
    assert.equal(result.length, 15);
    // Highest e1rm first: ex-19 (200kg * 1.167 = 233.3)
    assert.equal(result[0].id, 'ex-19');
    // Lowest of top 15: ex-5 (60kg * 1.167 = 70)
    assert.equal(result[14].id, 'ex-5');
  });
});

// --- sanitizeUserProfile ---

describe('sanitizeUserProfile', () => {
  test('removes all sensitive fields', () => {
    const user = {
      name: 'Alice',
      email: 'alice@example.com',
      subscription_original_transaction_id: 'txn123',
      subscription_app_account_token: 'token456',
      apple_authorization_code: 'auth789',
      subscription_environment: 'Production',
    };

    const result = sanitizeUserProfile(user);
    assert.equal(result.name, 'Alice');
    assert.equal(result.email, 'alice@example.com');

    for (const field of SENSITIVE_USER_FIELDS) {
      assert.equal(result[field], undefined, `${field} should be removed`);
    }
  });

  test('does not modify input object', () => {
    const user = {
      name: 'Bob',
      subscription_environment: 'Sandbox',
    };

    sanitizeUserProfile(user);
    assert.equal(user.subscription_environment, 'Sandbox');
  });

  test('handles empty object', () => {
    assert.deepEqual(sanitizeUserProfile({}), {});
  });

  test('preserves non-sensitive fields unchanged', () => {
    const user = {
      uid: 'u1',
      name: 'Charlie',
      activeRoutineId: 'r1',
      week_starts_on_monday: true,
      subscription_status: 'active',
      subscription_tier: 'premium',
    };

    const result = sanitizeUserProfile(user);
    assert.equal(result.uid, 'u1');
    assert.equal(result.name, 'Charlie');
    assert.equal(result.activeRoutineId, 'r1');
    // subscription_status and subscription_tier are NOT sensitive
    assert.equal(result.subscription_status, 'active');
    assert.equal(result.subscription_tier, 'premium');
  });
});

// --- Field name contract verification ---

describe('field name contract', () => {
  test('uses name not display_name in sanitized output', () => {
    const user = { name: 'Diana', display_name: 'Di' };
    const result = sanitizeUserProfile(user);
    // Both should pass through — the schema field is `name`
    assert.equal(result.name, 'Diana');
  });

  test('SENSITIVE_USER_FIELDS does not include subscription_status or subscription_tier', () => {
    // These are needed by agents for premium gating context
    assert.ok(!SENSITIVE_USER_FIELDS.includes('subscription_status'));
    assert.ok(!SENSITIVE_USER_FIELDS.includes('subscription_tier'));
  });
});
