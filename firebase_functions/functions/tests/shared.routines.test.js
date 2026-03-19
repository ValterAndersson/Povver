const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

// ---------------------------------------------------------------------------
// Mock Firestore
// ---------------------------------------------------------------------------

/**
 * Minimal Firestore mock that supports chained collection/doc/get/set/update/
 * delete/orderBy/limit/where operations. Data is stored in a flat map keyed
 * by the full document path (e.g. "users/u1/routines/r1").
 */
function createMockDb(initialDocs = {}) {
  const docs = { ...initialDocs };

  function docSnapshot(path) {
    const data = docs[path];
    const id = path.split('/').pop();
    return {
      exists: !!data,
      id,
      data: () => (data ? { ...data } : undefined),
      ref: { path },
    };
  }

  function buildRef(pathParts) {
    const fullPath = pathParts.join('/');

    return {
      id: pathParts[pathParts.length - 1],
      path: fullPath,

      collection(name) {
        return buildCollection([...pathParts, name]);
      },

      get() {
        return Promise.resolve(docSnapshot(fullPath));
      },

      set(data, _opts) {
        docs[fullPath] = { ...data };
        return Promise.resolve();
      },

      update(data) {
        if (!docs[fullPath]) {
          return Promise.reject(new Error(`Document ${fullPath} does not exist`));
        }
        docs[fullPath] = { ...docs[fullPath], ...data };
        return Promise.resolve();
      },

      delete() {
        delete docs[fullPath];
        return Promise.resolve();
      },
    };
  }

  function buildCollection(pathParts) {
    const collPath = pathParts.join('/');
    let _orderField = null;
    let _orderDir = null;
    let _limit = null;
    let _wheres = [];

    const q = {
      doc(id) {
        return buildRef([...pathParts, id]);
      },

      orderBy(field, dir) {
        _orderField = field;
        _orderDir = dir;
        return q;
      },

      limit(n) {
        _limit = n;
        return q;
      },

      where(field, op, value) {
        _wheres.push({ field, op, value });
        return q;
      },

      get() {
        // Find docs whose path starts with collPath + '/' and has no further sub-collections
        const matching = [];
        for (const [path, data] of Object.entries(docs)) {
          if (path.startsWith(collPath + '/')) {
            const remainder = path.slice(collPath.length + 1);
            // Only direct children (no further '/')
            if (!remainder.includes('/')) {
              const id = remainder;

              // Apply where filters
              let pass = true;
              for (const w of _wheres) {
                const val = getNestedField(data, w.field);
                if (w.op === '==' && val !== w.value) pass = false;
              }

              if (pass) {
                matching.push({
                  id,
                  exists: true,
                  data: () => ({ ...data }),
                  ref: { path },
                });
              }
            }
          }
        }

        // Sort if orderBy specified
        if (_orderField) {
          matching.sort((a, b) => {
            const va = a.data()[_orderField];
            const vb = b.data()[_orderField];
            return _orderDir === 'desc' ? (vb - va) : (va - vb);
          });
        }

        const limited = _limit ? matching.slice(0, _limit) : matching;

        return Promise.resolve({
          docs: limited,
          empty: limited.length === 0,
        });
      },
    };

    // Auto-generate id for new doc refs
    let _autoCounter = 0;
    const origDoc = q.doc;
    q.doc = function (id) {
      if (id === undefined) {
        _autoCounter++;
        return origDoc.call(this, `auto_${_autoCounter}`);
      }
      return origDoc.call(this, id);
    };

    return q;
  }

  function getNestedField(obj, path) {
    return path.split('.').reduce((o, k) => (o ? o[k] : undefined), obj);
  }

  return {
    collection(name) {
      return buildCollection([name]);
    },

    // getAll(...refs) — used by createRoutine to batch-check templates
    getAll(...refs) {
      return Promise.resolve(refs.map(ref => docSnapshot(ref.path)));
    },

    // Expose for test inspection
    _docs: docs,
  };
}

// ---------------------------------------------------------------------------
// Stub admin.firestore.FieldValue.serverTimestamp before requiring module
// ---------------------------------------------------------------------------

const admin = require('firebase-admin');
// Ensure serverTimestamp is available (it's a static method on the class)
// It should already be present from the firebase-admin package, but we
// confirm it returns a sentinel value we can detect in tests.
const TIMESTAMP_SENTINEL = admin.firestore.FieldValue.serverTimestamp();

// Now require the module under test
const {
  getRoutine,
  listRoutines,
  createRoutine,
  patchRoutine,
  deleteRoutine,
  getActiveRoutine,
  setActiveRoutine,
  getNextWorkout,
} = require('../shared/routines');

const { ValidationError, NotFoundError } = require('../shared/errors');

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('shared/routines', () => {

  // -----------------------------------------------------------------------
  // getRoutine
  // -----------------------------------------------------------------------
  describe('getRoutine', () => {
    test('throws ValidationError when routineId is missing', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => getRoutine(db, 'u1', null),
        (err) => err instanceof ValidationError
      );
    });

    test('throws NotFoundError when routine does not exist', async () => {
      const db = createMockDb({ 'users/u1': { activeRoutineId: null } });
      await assert.rejects(
        () => getRoutine(db, 'u1', 'missing'),
        (err) => err instanceof NotFoundError
      );
    });

    test('returns routine with is_active=true when active', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': { name: 'PPL' },
      });
      const result = await getRoutine(db, 'u1', 'r1');
      assert.equal(result.id, 'r1');
      assert.equal(result.name, 'PPL');
      assert.equal(result.is_active, true);
    });

    test('returns routine with is_active=false when not active', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'other' },
        'users/u1/routines/r1': { name: 'PPL' },
      });
      const result = await getRoutine(db, 'u1', 'r1');
      assert.equal(result.is_active, false);
    });
  });

  // -----------------------------------------------------------------------
  // listRoutines
  // -----------------------------------------------------------------------
  describe('listRoutines', () => {
    test('returns empty list when user has no routines', async () => {
      const db = createMockDb({ 'users/u1': { activeRoutineId: null } });
      const result = await listRoutines(db, 'u1');
      assert.equal(result.count, 0);
      assert.deepEqual(result.items, []);
    });

    test('enriches routines with is_active flag', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r2' },
        'users/u1/routines/r1': { name: 'A' },
        'users/u1/routines/r2': { name: 'B' },
      });
      const result = await listRoutines(db, 'u1');
      assert.equal(result.count, 2);
      const r1 = result.items.find(r => r.id === 'r1');
      const r2 = result.items.find(r => r.id === 'r2');
      assert.equal(r1.is_active, false);
      assert.equal(r2.is_active, true);
    });
  });

  // -----------------------------------------------------------------------
  // createRoutine
  // -----------------------------------------------------------------------
  describe('createRoutine', () => {
    test('throws ValidationError when userId is missing', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => createRoutine(db, '', { name: 'X' }),
        (err) => err instanceof ValidationError
      );
    });

    test('throws ValidationError for invalid routine data (missing name)', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => createRoutine(db, 'u1', {}),
        (err) => err instanceof ValidationError && err.message === 'Invalid routine data'
      );
    });

    test('throws ValidationError when template_ids reference missing templates', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'existing' },
      });
      await assert.rejects(
        () => createRoutine(db, 'u1', { name: 'Test', template_ids: ['t1', 't2'] }),
        (err) => {
          return err instanceof ValidationError &&
            err.details?.missing_template_ids?.length === 2;
        }
      );
    });

    test('creates routine and auto-activates when no active routine', async () => {
      const db = createMockDb({
        'users/u1': {},
      });
      const result = await createRoutine(db, 'u1', { name: 'New Routine' });
      assert.equal(result.activated, true);
      assert.ok(result.routineId);
      assert.equal(result.routine.name, 'New Routine');
    });

    test('creates routine without auto-activating when active routine exists', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'existing' },
      });
      const result = await createRoutine(db, 'u1', { name: 'Second Routine' });
      assert.equal(result.activated, false);
    });
  });

  // -----------------------------------------------------------------------
  // createRoutine - template_names
  // -----------------------------------------------------------------------
  describe('createRoutine - template_names', () => {
    test('persists template_names map from already-fetched template docs', async () => {
      const db = createMockDb({
        'users/u1': {},
        'users/u1/templates/t1': { name: 'Push Day' },
        'users/u1/templates/t2': { name: 'Pull Day' },
      });

      const result = await createRoutine(db, 'u1', {
        name: 'PPL Routine',
        template_ids: ['t1', 't2'],
        frequency: 2,
      });

      const routineKey = Object.keys(db._docs).find(k => k.startsWith('users/u1/routines/'));
      assert.ok(routineKey, 'Routine should be created');
      const routine = db._docs[routineKey];
      assert.deepEqual(routine.template_names, { t1: 'Push Day', t2: 'Pull Day' });
    });

    test('handles templates without names gracefully', async () => {
      const db = createMockDb({
        'users/u1': {},
        'users/u1/templates/t1': { name: 'Named' },
        'users/u1/templates/t2': { exercises: [] },  // no name
      });

      const result = await createRoutine(db, 'u1', {
        name: 'Test',
        template_ids: ['t1', 't2'],
        frequency: 2,
      });

      const routineKey = Object.keys(db._docs).find(k => k.startsWith('users/u1/routines/'));
      const routine = db._docs[routineKey];
      assert.equal(routine.template_names.t1, 'Named');
      assert.equal(routine.template_names.t2, 'Untitled');
    });

    test('sets empty template_names when no template_ids provided', async () => {
      const db = createMockDb({
        'users/u1': {},
      });

      const result = await createRoutine(db, 'u1', {
        name: 'Empty Routine',
        frequency: 3,
      });

      const routineKey = Object.keys(db._docs).find(k => k.startsWith('users/u1/routines/'));
      const routine = db._docs[routineKey];
      assert.deepEqual(routine.template_names, {});
    });
  });

  // -----------------------------------------------------------------------
  // patchRoutine
  // -----------------------------------------------------------------------
  describe('patchRoutine', () => {
    test('throws ValidationError when routineId is missing', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => patchRoutine(db, 'u1', null, { name: 'X' }),
        (err) => err instanceof ValidationError
      );
    });

    test('throws ValidationError when patch is not an object', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => patchRoutine(db, 'u1', 'r1', null),
        (err) => err instanceof ValidationError
      );
    });

    test('throws NotFoundError when routine does not exist', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => patchRoutine(db, 'u1', 'missing', { name: 'X' }),
        (err) => err instanceof NotFoundError
      );
    });

    test('throws ValidationError when no valid fields provided', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': { name: 'Old' },
      });
      await assert.rejects(
        () => patchRoutine(db, 'u1', 'r1', { bogus: 'field' }),
        (err) => err instanceof ValidationError && err.message.includes('No valid fields')
      );
    });

    test('throws ValidationError for empty name', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': { name: 'Old' },
      });
      await assert.rejects(
        () => patchRoutine(db, 'u1', 'r1', { name: '   ' }),
        (err) => err instanceof ValidationError && err.message.includes('non-empty string')
      );
    });

    test('throws ValidationError for frequency out of range', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': { name: 'Old' },
      });
      await assert.rejects(
        () => patchRoutine(db, 'u1', 'r1', { frequency: 10 }),
        (err) => err instanceof ValidationError && err.message.includes('frequency')
      );
    });

    test('patches name successfully', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': { name: 'Old' },
      });
      const result = await patchRoutine(db, 'u1', 'r1', { name: 'New Name' });
      assert.deepEqual(result.patchedFields, ['name']);
      assert.equal(result.routineId, 'r1');
      assert.equal(db._docs['users/u1/routines/r1'].name, 'New Name');
    });

    test('clears cursor when last_completed_template_id is removed', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': {
          name: 'PPL',
          template_ids: ['t1', 't2', 't3'],
          last_completed_template_id: 't2',
        },
        'users/u1/templates/t1': { name: 'Push' },
        'users/u1/templates/t3': { name: 'Legs' },
      });
      // Removing t2 from template_ids should clear the cursor
      const result = await patchRoutine(db, 'u1', 'r1', { template_ids: ['t1', 't3'] });
      assert.equal(result.cursorCleared, true);
    });

    test('updates template_names when template_ids change', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': {
          name: 'My Routine',
          template_ids: ['t1'],
          template_names: { t1: 'Push Day' },
        },
        'users/u1/templates/t1': { name: 'Push Day' },
        'users/u1/templates/t2': { name: 'Pull Day' },
      });

      await patchRoutine(db, 'u1', 'r1', { template_ids: ['t1', 't2'] });

      const routine = db._docs['users/u1/routines/r1'];
      assert.deepEqual(routine.template_names, { t1: 'Push Day', t2: 'Pull Day' });
    });

    test('uses Untitled for templates without names in patch', async () => {
      const db = createMockDb({
        'users/u1/routines/r1': {
          name: 'My Routine',
          template_ids: ['t1'],
          template_names: { t1: 'Push Day' },
        },
        'users/u1/templates/t1': { exercises: [] },  // no name
      });

      await patchRoutine(db, 'u1', 'r1', { template_ids: ['t1'] });

      const routine = db._docs['users/u1/routines/r1'];
      assert.deepEqual(routine.template_names, { t1: 'Untitled' });
    });
  });

  // -----------------------------------------------------------------------
  // deleteRoutine
  // -----------------------------------------------------------------------
  describe('deleteRoutine', () => {
    test('throws ValidationError when params missing', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => deleteRoutine(db, '', 'r1'),
        (err) => err instanceof ValidationError
      );
    });

    test('throws NotFoundError when routine does not exist', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => deleteRoutine(db, 'u1', 'missing'),
        (err) => err instanceof NotFoundError
      );
    });

    test('deletes routine and clears active if was active', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': { name: 'PPL' },
      });
      const result = await deleteRoutine(db, 'u1', 'r1');
      assert.equal(result.activeRoutineCleared, true);
      assert.equal(db._docs['users/u1'].activeRoutineId, null);
      assert.equal(db._docs['users/u1/routines/r1'], undefined);
    });

    test('deletes routine without clearing active if was not active', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'other' },
        'users/u1/routines/r1': { name: 'PPL' },
      });
      const result = await deleteRoutine(db, 'u1', 'r1');
      assert.equal(result.activeRoutineCleared, false);
      assert.equal(db._docs['users/u1'].activeRoutineId, 'other');
    });
  });

  // -----------------------------------------------------------------------
  // getActiveRoutine
  // -----------------------------------------------------------------------
  describe('getActiveRoutine', () => {
    test('throws NotFoundError when user does not exist', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => getActiveRoutine(db, 'missing'),
        (err) => err instanceof NotFoundError
      );
    });

    test('returns null routine when no active routine set', async () => {
      const db = createMockDb({ 'users/u1': {} });
      const result = await getActiveRoutine(db, 'u1');
      assert.equal(result.routine, null);
      assert.ok(result.message);
    });

    test('returns active routine', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': { name: 'PPL' },
      });
      const result = await getActiveRoutine(db, 'u1');
      assert.equal(result.routine.id, 'r1');
      assert.equal(result.routine.name, 'PPL');
    });
  });

  // -----------------------------------------------------------------------
  // setActiveRoutine
  // -----------------------------------------------------------------------
  describe('setActiveRoutine', () => {
    test('throws ValidationError when params missing', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => setActiveRoutine(db, '', 'r1'),
        (err) => err instanceof ValidationError
      );
    });

    test('throws NotFoundError when routine does not exist', async () => {
      const db = createMockDb();
      await assert.rejects(
        () => setActiveRoutine(db, 'u1', 'missing'),
        (err) => err instanceof NotFoundError
      );
    });

    test('sets active routine on existing user', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: null },
        'users/u1/routines/r1': { name: 'PPL' },
      });
      const result = await setActiveRoutine(db, 'u1', 'r1');
      assert.equal(result.routineId, 'r1');
      assert.equal(result.routine.name, 'PPL');
    });
  });

  // -----------------------------------------------------------------------
  // getNextWorkout
  // -----------------------------------------------------------------------
  describe('getNextWorkout', () => {
    test('returns no_active_routine when user has none', async () => {
      const db = createMockDb({ 'users/u1': {} });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.reason, 'no_active_routine');
      assert.equal(result.template, null);
    });

    test('returns empty_routine when routine has no template_ids', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': { name: 'Empty', template_ids: [] },
      });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.reason, 'empty_routine');
    });

    test('uses cursor to pick next template', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': {
          name: 'PPL',
          template_ids: ['t1', 't2', 't3'],
          last_completed_template_id: 't1',
        },
        'users/u1/templates/t2': { name: 'Pull' },
      });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.selectionMethod, 'cursor');
      assert.equal(result.template.id, 't2');
      assert.equal(result.templateIndex, 1);
      assert.equal(result.templateCount, 3);
    });

    test('wraps around when cursor is at last template', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': {
          name: 'PPL',
          template_ids: ['t1', 't2', 't3'],
          last_completed_template_id: 't3',
        },
        'users/u1/templates/t1': { name: 'Push' },
      });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.selectionMethod, 'cursor');
      assert.equal(result.template.id, 't1');
      assert.equal(result.templateIndex, 0);
    });

    test('falls back to default_first when no cursor and no history', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': {
          name: 'PPL',
          template_ids: ['t1', 't2'],
        },
        'users/u1/templates/t1': { name: 'Push' },
      });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.selectionMethod, 'default_first');
      assert.equal(result.template.id, 't1');
    });

    test('falls back when referenced template is missing', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': {
          name: 'PPL',
          template_ids: ['t1', 't2'],
        },
        // t1 does not exist, t2 does
        'users/u1/templates/t2': { name: 'Pull' },
      });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.selectionMethod, 'fallback_first_available');
      assert.equal(result.template.id, 't2');
    });

    test('returns no_valid_templates when all templates missing', async () => {
      const db = createMockDb({
        'users/u1': { activeRoutineId: 'r1' },
        'users/u1/routines/r1': {
          name: 'PPL',
          template_ids: ['t1', 't2'],
        },
        // No templates exist
      });
      const result = await getNextWorkout(db, 'u1');
      assert.equal(result.reason, 'no_valid_templates');
      assert.equal(result.template, null);
    });
  });
});
