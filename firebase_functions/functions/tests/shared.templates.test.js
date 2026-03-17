const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

// Stub firebase-admin before requiring shared/templates
const stubFieldValue = {
  serverTimestamp: () => ({ _type: 'serverTimestamp' }),
  delete: () => ({ _type: 'deleteField' }),
};

// Minimal mock for admin.firestore used by shared/templates.js
const mockAdmin = require('firebase-admin');
if (!mockAdmin.apps?.length) {
  mockAdmin.initializeApp({ projectId: 'test-project' });
}

const {
  getTemplate,
  listTemplates,
  createTemplate,
  patchTemplate,
  deleteTemplate,
  createTemplateFromPlan,
} = require('../shared/templates');

const { ValidationError, NotFoundError, ConflictError, PermissionDeniedError } = require('../shared/errors');

// ---------------------------------------------------------------------------
// In-memory Firestore mock
// ---------------------------------------------------------------------------

/**
 * Builds a minimal in-memory Firestore mock that supports:
 *   collection().doc().get/set/update/delete
 *   collection().add()
 *   collection().get() (list all docs)
 *   db.batch() with set/update and commit
 *
 * Populate via store: { 'col/docId': { ...data } }
 */
function createMockDb(store = {}) {
  function makeDocRef(path) {
    return {
      id: path.split('/').pop(),
      get: async () => {
        const data = store[path];
        return {
          exists: !!data,
          id: path.split('/').pop(),
          data: () => (data ? { ...data } : undefined),
        };
      },
      set: async (data) => { store[path] = { ...data }; },
      update: async (data) => {
        if (!store[path]) throw new Error(`Doc ${path} not found for update`);
        store[path] = { ...store[path], ...data };
      },
      delete: async () => { delete store[path]; },
      collection: (sub) => makeColRef(`${path}/${sub}`),
    };
  }

  function makeColRef(path) {
    return {
      doc: (id) => {
        const docId = id || `auto_${Math.random().toString(36).slice(2, 8)}`;
        return makeDocRef(`${path}/${docId}`);
      },
      add: async (data) => {
        const docId = `auto_${Math.random().toString(36).slice(2, 8)}`;
        const fullPath = `${path}/${docId}`;
        store[fullPath] = { ...data };
        return makeDocRef(fullPath);
      },
      limit: () => makeColRef(path),
      get: async () => {
        const prefix = path + '/';
        const docs = Object.keys(store)
          .filter(k => k.startsWith(prefix) && k.replace(prefix, '').indexOf('/') === -1)
          .map(k => ({
            id: k.split('/').pop(),
            data: () => ({ ...store[k] }),
          }));
        return { docs };
      },
    };
  }

  const db = {
    collection: (col) => makeColRef(col),
    batch: () => {
      const ops = [];
      return {
        set: (ref, data) => ops.push({ type: 'set', ref, data }),
        update: (ref, data) => ops.push({ type: 'update', ref, data }),
        commit: async () => {
          for (const op of ops) {
            if (op.type === 'set') await op.ref.set(op.data);
            if (op.type === 'update') await op.ref.update(op.data);
          }
        },
      };
    },
  };

  return db;
}

// ---------------------------------------------------------------------------
// getTemplate
// ---------------------------------------------------------------------------

describe('getTemplate', () => {
  test('throws ValidationError when templateId is missing', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => getTemplate(db, 'user1', ''),
      (err) => err instanceof ValidationError && /templateId/.test(err.message)
    );
  });

  test('throws NotFoundError when template does not exist', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => getTemplate(db, 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError
    );
  });

  test('returns template with resolved exercise names', async () => {
    const store = {
      'users/user1/templates/t1': {
        name: 'Push Day',
        exercises: [
          { exercise_id: 'ex1', sets: [{ reps: 10, rir: 2, weight: 60 }] },
          { exercise_id: 'ex2', name: 'Already Named', sets: [{ reps: 8, rir: 1, weight: 80 }] },
        ],
      },
      'exercises/ex1': { name: 'Bench Press' },
    };
    const db = createMockDb(store);
    const result = await getTemplate(db, 'user1', 't1');

    assert.equal(result.id, 't1');
    assert.equal(result.name, 'Push Day');
    assert.equal(result.exercises[0].name, 'Bench Press');
    assert.equal(result.exercises[1].name, 'Already Named');
  });
});

// ---------------------------------------------------------------------------
// listTemplates
// ---------------------------------------------------------------------------

describe('listTemplates', () => {
  test('returns empty list when no templates exist', async () => {
    const db = createMockDb();
    const result = await listTemplates(db, 'user1');
    assert.equal(result.count, 0);
    assert.deepEqual(result.items, []);
  });

  test('returns all templates for user', async () => {
    const store = {
      'users/user1/templates/t1': { name: 'Push Day' },
      'users/user1/templates/t2': { name: 'Pull Day' },
    };
    const db = createMockDb(store);
    const result = await listTemplates(db, 'user1');
    assert.equal(result.count, 2);
  });
});

// ---------------------------------------------------------------------------
// createTemplate
// ---------------------------------------------------------------------------

describe('createTemplate', () => {
  test('throws ValidationError for invalid template data', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => createTemplate(db, 'user1', { name: '' }),
      (err) => err instanceof ValidationError && /Invalid template data/.test(err.message)
    );
  });

  test('throws ValidationError for missing exercises', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => createTemplate(db, 'user1', { name: 'Test' }),
      (err) => err instanceof ValidationError
    );
  });

  test('creates template and returns it', async () => {
    const store = {};
    const db = createMockDb(store);
    const templateData = {
      name: 'Push Day',
      exercises: [
        { exercise_id: 'ex1', sets: [{ reps: 10, rir: 2, weight: 60 }] },
      ],
    };
    const result = await createTemplate(db, 'user1', templateData);

    assert.ok(result.templateId);
    assert.equal(result.template.name, 'Push Day');
    assert.equal(result.template.id, result.templateId);
  });
});

// ---------------------------------------------------------------------------
// patchTemplate
// ---------------------------------------------------------------------------

describe('patchTemplate', () => {
  test('throws ValidationError when templateId is missing', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => patchTemplate(db, 'user1', '', { name: 'X' }),
      (err) => err instanceof ValidationError
    );
  });

  test('throws ValidationError when patch is not an object', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => patchTemplate(db, 'user1', 't1', null),
      (err) => err instanceof ValidationError && /patch/.test(err.message)
    );
  });

  test('throws NotFoundError when template does not exist', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => patchTemplate(db, 'user1', 't1', { name: 'X' }),
      (err) => err instanceof NotFoundError
    );
  });

  test('throws ValidationError when no valid fields provided', async () => {
    const store = { 'users/user1/templates/t1': { name: 'Old' } };
    const db = createMockDb(store);
    await assert.rejects(
      () => patchTemplate(db, 'user1', 't1', { bogus: 123 }),
      (err) => err instanceof ValidationError && /No valid fields/.test(err.message)
    );
  });

  test('throws ValidationError for empty name', async () => {
    const store = { 'users/user1/templates/t1': { name: 'Old' } };
    const db = createMockDb(store);
    await assert.rejects(
      () => patchTemplate(db, 'user1', 't1', { name: '   ' }),
      (err) => err instanceof ValidationError && /non-empty/.test(err.message)
    );
  });

  test('throws ValidationError for empty exercises array', async () => {
    const store = { 'users/user1/templates/t1': { name: 'Old', exercises: [] } };
    const db = createMockDb(store);
    await assert.rejects(
      () => patchTemplate(db, 'user1', 't1', { exercises: [] }),
      (err) => err instanceof ValidationError && /empty/.test(err.message)
    );
  });

  test('throws ConflictError on concurrent modification', async () => {
    const store = {
      'users/user1/templates/t1': {
        name: 'Old',
        updated_at: { toMillis: () => 1000 },
      },
    };
    const db = createMockDb(store);
    await assert.rejects(
      () => patchTemplate(db, 'user1', 't1', { name: 'New', expected_updated_at: 999 }),
      (err) => err instanceof ConflictError
    );
  });

  test('patches name successfully', async () => {
    const store = { 'users/user1/templates/t1': { name: 'Old', exercises: [] } };
    const db = createMockDb(store);
    const result = await patchTemplate(db, 'user1', 't1', { name: 'New Name' });

    assert.equal(result.templateId, 't1');
    assert.deepEqual(result.patchedFields, ['name']);
    assert.equal(result.analyticsWillRecompute, false);
  });

  test('patches exercises and marks analytics for recompute', async () => {
    const oldExercises = [{ exercise_id: 'ex1', sets: [{ reps: 10, rir: 2, weight: 60 }] }];
    const newExercises = [{ exercise_id: 'ex2', sets: [{ reps: 8, rir: 1, weight: 80 }] }];
    const store = { 'users/user1/templates/t1': { name: 'Test', exercises: oldExercises } };
    const db = createMockDb(store);
    const result = await patchTemplate(db, 'user1', 't1', { exercises: newExercises });

    assert.deepEqual(result.patchedFields, ['exercises']);
    assert.equal(result.analyticsWillRecompute, true);
  });
});

// ---------------------------------------------------------------------------
// deleteTemplate
// ---------------------------------------------------------------------------

describe('deleteTemplate', () => {
  test('throws ValidationError when parameters are missing', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => deleteTemplate(db, '', 't1'),
      (err) => err instanceof ValidationError
    );
  });

  test('throws NotFoundError when template does not exist', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => deleteTemplate(db, 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError
    );
  });

  test('deletes template and cleans up routine references', async () => {
    const store = {
      'users/user1/templates/t1': { name: 'Push Day' },
      'users/user1/routines/r1': { template_ids: ['t1', 't2'], last_completed_template_id: 't1' },
      'users/user1/routines/r2': { template_ids: ['t3'] },
    };
    const db = createMockDb(store);
    const result = await deleteTemplate(db, 'user1', 't1');

    assert.equal(result.templateId, 't1');
    assert.equal(result.routinesUpdated, 1);
    // Template should be deleted
    assert.equal(store['users/user1/templates/t1'], undefined);
    // Routine r1 should have t1 removed and cursor cleared
    assert.deepEqual(store['users/user1/routines/r1'].template_ids, ['t2']);
    assert.equal(store['users/user1/routines/r1'].last_completed_template_id, null);
    // Routine r2 should be unchanged
    assert.deepEqual(store['users/user1/routines/r2'].template_ids, ['t3']);
  });
});

// ---------------------------------------------------------------------------
// createTemplateFromPlan
// ---------------------------------------------------------------------------

describe('createTemplateFromPlan', () => {
  test('throws ValidationError when required params are missing', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', { canvasId: 'c1' }),
      (err) => err instanceof ValidationError && /Missing required/.test(err.message)
    );
  });

  test('throws ValidationError for invalid mode', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', {
        canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'invalid',
      }),
      (err) => err instanceof ValidationError && /mode/.test(err.message)
    );
  });

  test('throws ValidationError when update mode missing existingTemplateId', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', {
        canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'update',
      }),
      (err) => err instanceof ValidationError && /existingTemplateId/.test(err.message)
    );
  });

  test('returns cached result on idempotent call', async () => {
    const idempotencyKey = 'createTemplateFromPlan:c1:card1:create:new';
    const store = {
      [`users/user1/idempotency/${idempotencyKey}`]: { result: 'cached-t1' },
    };
    const db = createMockDb(store);
    const result = await createTemplateFromPlan(db, 'user1', {
      canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'create',
    });

    assert.equal(result.templateId, 'cached-t1');
    assert.equal(result.idempotent, true);
  });

  test('throws NotFoundError when canvas does not exist', async () => {
    const db = createMockDb();
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', {
        canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'create',
      }),
      (err) => err instanceof NotFoundError && /Canvas/.test(err.message)
    );
  });

  test('throws PermissionDeniedError when canvas belongs to different user', async () => {
    const store = {
      'users/user1/canvases/c1': { meta: { user_id: 'other-user' } },
    };
    const db = createMockDb(store);
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', {
        canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'create',
      }),
      (err) => err instanceof PermissionDeniedError
    );
  });

  test('throws NotFoundError when card does not exist', async () => {
    const store = {
      'users/user1/canvases/c1': { meta: { user_id: 'user1' } },
    };
    const db = createMockDb(store);
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', {
        canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'create',
      }),
      (err) => err instanceof NotFoundError && /Card/.test(err.message)
    );
  });

  test('throws ValidationError for non-session_plan card type', async () => {
    const store = {
      'users/user1/canvases/c1': { meta: { user_id: 'user1' } },
      'users/user1/canvases/c1/cards/card1': { type: 'text', content: {} },
    };
    const db = createMockDb(store);
    await assert.rejects(
      () => createTemplateFromPlan(db, 'user1', {
        canvasId: 'c1', cardId: 'card1', name: 'Test', mode: 'create',
      }),
      (err) => err instanceof ValidationError && /session_plan/.test(err.message)
    );
  });

  test('creates template from valid plan in create mode', async () => {
    const store = {
      'users/user1/canvases/c1': { meta: { user_id: 'user1' } },
      'users/user1/canvases/c1/cards/card1': {
        type: 'session_plan',
        content: {
          coach_notes: 'Focus on form',
          blocks: [
            {
              exercise_id: 'ex1',
              sets: [
                { target: { reps: 10, rir: 2 } },
                { target: { reps: 8, rir: 1 } },
              ],
            },
          ],
        },
      },
    };
    const db = createMockDb(store);
    const result = await createTemplateFromPlan(db, 'user1', {
      canvasId: 'c1', cardId: 'card1', name: 'New Push Day', mode: 'create',
    });

    assert.ok(result.templateId);
    assert.equal(result.mode, 'create');
    assert.equal(result.exerciseCount, 1);
    assert.equal(result.message, 'Template created');
  });
});
