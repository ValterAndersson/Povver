/**
 * Tests for shared/artifacts.js — artifact action business logic.
 *
 * Uses require-cache stubbing to mock firebase-admin and subscription-gate
 * before loading the module under test.
 */

const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');

// ─── In-memory Firestore stub ───────────────────────────────────────────────

let firestoreDocs = {};

function createDocRef(docPath, id) {
  return {
    id: id || docPath.split('/').pop(),
    path: docPath,
    get: async () => {
      const data = firestoreDocs[docPath];
      return {
        exists: !!data,
        data: () => data ? { ...data } : undefined,
      };
    },
    set: async (data) => { firestoreDocs[docPath] = { ...data }; },
    update: async (data) => {
      if (!firestoreDocs[docPath]) throw new Error(`Doc not found: ${docPath}`);
      firestoreDocs[docPath] = { ...firestoreDocs[docPath], ...data };
    },
    collection: (sub) => createCollectionRef(`${docPath}/${sub}`),
  };
}

function createCollectionRef(collPath) {
  return {
    doc: (id) => {
      const docId = id || `auto_${Math.random().toString(36).slice(2, 10)}`;
      return createDocRef(`${collPath}/${docId}`, docId);
    },
  };
}

const mockDb = {
  collection: (p) => createCollectionRef(p),
  doc: (p) => createDocRef(p, p.split('/').pop()),
  batch: () => {
    const ops = [];
    return {
      set: (ref, data) => ops.push({ type: 'set', path: ref.path, data }),
      update: (ref, data) => ops.push({ type: 'update', path: ref.path, data }),
      commit: async () => {
        for (const op of ops) {
          if (op.type === 'set') {
            firestoreDocs[op.path] = { ...op.data };
          } else if (op.type === 'update') {
            firestoreDocs[op.path] = { ...(firestoreDocs[op.path] || {}), ...op.data };
          }
        }
      },
    };
  },
};

// ─── Stub firebase-admin in require cache ───────────────────────────────────

let mockIsPremium = true;

const adminStub = {
  apps: ['fake-app'],
  initializeApp: () => {},
  firestore: Object.assign(() => mockDb, {
    FieldValue: {
      serverTimestamp: () => 'SERVER_TIMESTAMP',
    },
  }),
};

// Pre-populate require cache before loading module under test
const adminPath = require.resolve('firebase-admin');
require.cache[adminPath] = {
  id: adminPath,
  filename: adminPath,
  loaded: true,
  exports: adminStub,
};

// The isPremiumUser stub closes over mockIsPremium, so changing the
// variable in beforeEach controls premium gate behavior at call time.
const subGatePath = require.resolve('../utils/subscription-gate');
require.cache[subGatePath] = {
  id: subGatePath,
  filename: subGatePath,
  loaded: true,
  exports: { isPremiumUser: async () => mockIsPremium },
};

// Now require the module under test — it will get our stubs
const {
  executeArtifactAction,
  CONVERSATION_COLLECTION,
} = require('../shared/artifacts');
const { ValidationError, NotFoundError, PremiumRequiredError } = require('../shared/errors');

// ─── Helpers ────────────────────────────────────────────────────────────────

const USER_ID = 'user-123';
const CONV_ID = 'conv-456';
const ART_ID = 'art-789';

function artifactPath() {
  return `users/${USER_ID}/${CONVERSATION_COLLECTION}/${CONV_ID}/artifacts/${ART_ID}`;
}

function seedArtifact(data) {
  firestoreDocs[artifactPath()] = { status: 'pending', ...data };
}

function seedUserDoc() {
  firestoreDocs[`users/${USER_ID}`] = { activeRoutineId: null };
}

function makeBlocks() {
  return [
    {
      exercise_id: 'ex-1',
      sets: [{ target: { reps: 10, rir: 2, weight: 50 } }],
    },
  ];
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe('executeArtifactAction — validation', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;
    // Update the subscription gate stub to reflect current mockIsPremium

  });

  test('throws ValidationError when userId is missing', async () => {
    await assert.rejects(
      () => executeArtifactAction(mockDb, null, CONV_ID, ART_ID, 'accept'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.equal(err.http, 400);
        return true;
      },
    );
  });

  test('throws ValidationError when action is missing', async () => {
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, null),
      (err) => {
        assert.ok(err instanceof ValidationError);
        return true;
      },
    );
  });

  test('throws ValidationError for unknown action', async () => {
    seedArtifact({ type: 'session_plan' });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'fly_to_moon'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /Unknown action/);
        return true;
      },
    );
  });
});

describe('executeArtifactAction — not found', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('throws NotFoundError when artifact does not exist', async () => {
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'accept'),
      (err) => {
        assert.ok(err instanceof NotFoundError);
        assert.equal(err.http, 404);
        return true;
      },
    );
  });
});

describe('accept action', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('sets status to accepted', async () => {
    seedArtifact({ type: 'session_plan' });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'accept');
    assert.equal(result.status, 'accepted');
    assert.equal(firestoreDocs[artifactPath()].status, 'accepted');
  });
});

describe('dismiss action', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('sets status to dismissed', async () => {
    seedArtifact({ type: 'session_plan' });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'dismiss');
    assert.equal(result.status, 'dismissed');
    assert.equal(firestoreDocs[artifactPath()].status, 'dismissed');
  });
});

describe('save_template action', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('rejects non-session_plan artifact', async () => {
    seedArtifact({ type: 'routine_summary', content: {} });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_template'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /session_plan/);
        return true;
      },
    );
  });

  test('creates new template from session_plan', async () => {
    seedArtifact({
      type: 'session_plan',
      content: {
        title: 'Test Workout',
        blocks: makeBlocks(),
      },
    });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_template');
    assert.ok(result.templateId);
    assert.equal(result.isUpdate, false);
    assert.equal(firestoreDocs[artifactPath()].status, 'accepted');
  });

  test('rejects when not premium', async () => {
    mockIsPremium = false;

    seedArtifact({
      type: 'session_plan',
      content: { title: 'Test', blocks: makeBlocks() },
    });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_template'),
      (err) => {
        assert.ok(err instanceof PremiumRequiredError);
        assert.equal(err.http, 403);
        return true;
      },
    );
  });
});

describe('start_workout action', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('returns plan from session_plan artifact', async () => {
    const blocks = makeBlocks();
    seedArtifact({
      type: 'session_plan',
      content: { title: 'Morning Push', blocks },
    });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'start_workout');
    assert.equal(result.plan.title, 'Morning Push');
    assert.deepEqual(result.plan.blocks, blocks);
    assert.equal(result.status, 'accepted');
  });

  test('returns plan for specific day from routine_summary', async () => {
    seedArtifact({
      type: 'routine_summary',
      content: {
        workouts: [
          { title: 'Day 1', day: 1, blocks: makeBlocks() },
          { title: 'Day 2', day: 2, blocks: makeBlocks() },
        ],
      },
    });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'start_workout', { day: 2 });
    assert.equal(result.plan.title, 'Day 2');
  });

  test('rejects invalid day index', async () => {
    seedArtifact({
      type: 'routine_summary',
      content: { workouts: [{ title: 'Day 1', day: 1, blocks: makeBlocks() }] },
    });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'start_workout', { day: 5 }),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /Invalid day/);
        return true;
      },
    );
  });

  test('rejects wrong artifact type', async () => {
    seedArtifact({ type: 'analysis', content: {} });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'start_workout'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        return true;
      },
    );
  });
});

describe('save_routine action', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('rejects non-routine_summary artifact', async () => {
    seedArtifact({ type: 'session_plan', content: {} });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_routine'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /routine_summary/);
        return true;
      },
    );
  });

  test('rejects routine with no workouts', async () => {
    seedArtifact({
      type: 'routine_summary',
      content: { workouts: [] },
    });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_routine'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /no workouts/);
        return true;
      },
    );
  });

  test('rejects routine with too many workouts', async () => {
    const workouts = Array.from({ length: 15 }, (_, i) => ({
      title: `Day ${i + 1}`,
      day: i + 1,
      blocks: makeBlocks(),
    }));
    seedArtifact({
      type: 'routine_summary',
      content: { name: 'Big Routine', workouts },
    });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_routine'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /too many/);
        return true;
      },
    );
  });

  test('creates routine and templates from routine_summary', async () => {
    seedUserDoc();
    seedArtifact({
      type: 'routine_summary',
      content: {
        name: 'PPL',
        workouts: [
          { title: 'Push', day: 1, blocks: makeBlocks() },
          { title: 'Pull', day: 2, blocks: makeBlocks() },
        ],
      },
    });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_routine');
    assert.ok(result.routineId);
    assert.equal(result.templateIds.length, 2);
    assert.equal(result.isUpdate, false);
  });
});

describe('save_as_new action', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = true;

  });

  test('creates new template from session_plan (ignores source)', async () => {
    seedArtifact({
      type: 'session_plan',
      content: {
        title: 'Fresh Workout',
        blocks: makeBlocks(),
        source_template_id: 'old-template-id',
      },
    });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_as_new');
    assert.ok(result.templateId);
    assert.equal(result.isUpdate, false);
  });

  test('creates new routine from routine_summary (ignores source)', async () => {
    seedUserDoc();
    seedArtifact({
      type: 'routine_summary',
      content: {
        name: 'New Routine',
        source_routine_id: 'old-routine-id',
        workouts: [{ title: 'Day 1', day: 1, blocks: makeBlocks() }],
      },
    });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_as_new');
    assert.ok(result.routineId);
    assert.equal(result.isUpdate, false);
  });

  test('rejects unsupported artifact type', async () => {
    seedArtifact({ type: 'analysis', content: {} });
    await assert.rejects(
      () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'save_as_new'),
      (err) => {
        assert.ok(err instanceof ValidationError);
        assert.match(err.message, /save_as_new requires/);
        return true;
      },
    );
  });
});

describe('premium gate', () => {
  beforeEach(() => {
    firestoreDocs = {};
    mockIsPremium = false;

  });

  test('accept does not require premium', async () => {
    seedArtifact({ type: 'session_plan' });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'accept');
    assert.equal(result.status, 'accepted');
  });

  test('dismiss does not require premium', async () => {
    seedArtifact({ type: 'session_plan' });
    const result = await executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, 'dismiss');
    assert.equal(result.status, 'dismissed');
  });

  for (const action of ['save_routine', 'save_template', 'start_workout', 'save_as_new']) {
    test(`${action} requires premium`, async () => {
      seedArtifact({ type: 'session_plan', content: { title: 'T', blocks: makeBlocks() } });
      await assert.rejects(
        () => executeArtifactAction(mockDb, USER_ID, CONV_ID, ART_ID, action),
        (err) => {
          assert.ok(err instanceof PremiumRequiredError);
          return true;
        },
      );
    });
  }
});

describe('CONVERSATION_COLLECTION constant', () => {
  test('defaults to canvases', () => {
    assert.equal(CONVERSATION_COLLECTION, 'canvases');
  });
});
