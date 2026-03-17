# Architecture Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure Povver into a shared business logic layer, stateless Cloud Run agent, MCP server, and job queue — replacing Vertex AI Agent Engine and eliminating the circular HTTP dependency.

**Architecture:** Extract pure business logic from Firebase Function handlers into `shared/` modules. Build a new Python Cloud Run agent service with direct Firestore access and model-agnostic LLM client. Add an MCP server (Node.js) importing the same shared modules. Replace the workout completion trigger cascade with a lease-based job queue worker.

**Tech Stack:** Node.js (Firebase Functions, MCP Server), Python 3.11 (Agent Service), Firestore, Cloud Run, `google-genai` SDK, `@modelcontextprotocol/sdk`, Starlette (ASGI)

**Spec:** `docs/plans/2026-03-17-architecture-redesign-design.md`

---

## File Structure

### New Files

**Phase 2 — Shared Business Logic:**
```
firebase_functions/functions/shared/
  errors.js                    # ValidationError, NotFoundError, PermissionError
  routines.js                  # get, list, create, patch, delete, getActive, setActive, getNextWorkout
  templates.js                 # get, list, create, patch, delete, createFromPlan
  workouts.js                  # get, list (paginated), upsert, delete
  exercises.js                 # get, list, search, resolve
  training-queries.js          # querySets, aggregateSets, getAnalysisSummary, getMuscleGroupSummary
  planning-context.js          # getPlanningContext (user + history + routine + strength)
  artifacts.js                 # getArtifact, acceptArtifact, dismissArtifact, saveRoutineFromArtifact, saveTemplateFromArtifact
  progressions.js              # applyProgression, suggestWeightIncrease, suggestDeload (with changelog + audit trail)
firebase_functions/functions/tests/
  shared.errors.test.js
  shared.routines.test.js
  shared.templates.test.js
  shared.workouts.test.js
  shared.exercises.test.js
  shared.training-queries.test.js
  shared.planning-context.test.js
  shared.artifacts.test.js
  shared.progressions.test.js
```

**Phase 3a — Agent Service:**
```
adk_agent/agent_service/
  Dockerfile
  Makefile
  requirements.txt
  app/
    __init__.py
    main.py                    # Starlette ASGI app, /stream endpoint
    agent_loop.py              # Core agent loop (replaces ADK Runner)
    context.py                 # RequestContext dataclass (replaces ContextVar)
    observability.py           # Structured logging, Cloud Trace
    llm/
      __init__.py
      protocol.py              # LLMClient protocol, LLMChunk dataclass
      gemini.py                # GeminiClient (google-genai SDK)
    firestore_client.py        # AsyncClient-based Firestore access
    router.py                  # 4-lane router (migrated from shell/router.py)
    instruction.py             # Coaching persona (migrated, model-agnostic)
    planner.py                 # Tool planning for Slow Lane (migrated)
    safety_gate.py             # Write confirmation (migrated)
    critic.py                  # Response validation (migrated)
    functional_handler.py      # Functional Lane JSON handler (migrated)
    skills/
      __init__.py
      copilot_skills.py        # Fast Lane — HTTP to Firebase Functions (retained)
      coach_skills.py          # Read tools — direct Firestore queries
      planner_skills.py        # Write tools — direct Firestore + SSE artifacts
      workout_skills.py        # Active workout — HTTP to Firebase Functions (retained)
      progression_skills.py    # Background progression — HTTP to Firebase Functions (retained)
    tools/
      __init__.py
      registry.py              # Tool registry + execute_tool dispatcher
      definitions.py           # Tool schemas for LLM
  tests/
    __init__.py
    test_agent_loop.py
    test_llm_protocol.py
    test_router.py
    test_firestore_client.py
    test_context.py
    test_skills/
      __init__.py
      test_coach_skills.py
      test_planner_skills.py
```

**Phase 3b — Agent Memory:**
```
adk_agent/agent_service/app/
  memory.py                    # MemoryManager (save, retire, list, auto-load)
  context_builder.py           # 360 view assembler (all tiers)
  tools/
    memory_tools.py            # save_memory, retire_memory, set_session_var, etc.
adk_agent/agent_service/tests/
  test_memory.py
  test_context_builder.py
```

**Phase 4 — MCP Server:**
```
mcp_server/
  package.json
  tsconfig.json
  Dockerfile
  Makefile
  src/
    index.ts                   # Starlette HTTP MCP server entry
    auth.ts                    # API key hash lookup + premium validation
    tools.ts                   # MCP tool definitions importing shared modules
  tests/
    auth.test.ts
    tools.test.ts
```

**Phase 5 — Workout Completion (Cloud Tasks refactor, stays in JS):**
```
firebase_functions/functions/
  training/
    process-workout-completion.js   # Shared callable extracted from trigger cascade
  triggers/
    workout-completion-task.js      # Cloud Tasks HTTP handler
    workout-completion-watchdog.js  # Daily scheduled catch-up function
  utils/
    enqueue-workout-task.js         # Cloud Tasks enqueue helper
```

### Modified Files (key changes only)

| File | Phase | Change |
|------|-------|--------|
| `firebase_functions/functions/routines/*.js` | 2 | Thin wrappers calling `shared/routines.js` |
| `firebase_functions/functions/templates/*.js` | 2 | Thin wrappers calling `shared/templates.js` |
| `firebase_functions/functions/workouts/*.js` | 2 | Thin wrappers calling `shared/workouts.js` |
| `firebase_functions/functions/exercises/*.js` | 2 | Thin wrappers calling `shared/exercises.js` |
| `firebase_functions/functions/training/*.js` | 2 | Thin wrappers calling `shared/training-queries.js` |
| `firebase_functions/functions/strengthos/stream-agent-normalized.js` | 3a, 3c | Call Cloud Run instead of Vertex AI; add conversation init; remove session logic |
| `firebase_functions/functions/triggers/weekly-analytics.js` | 5 | Replace analytics pipeline with job enqueue (both onWorkoutCompleted + onWorkoutCreatedWithEnd) |
| `firebase_functions/functions/triggers/workout-routine-cursor.js` | 5 | Delete — routine cursor absorbed into workout completion worker |
| `firebase_functions/functions/agents/get-planning-context.js` | 2 | Thin wrapper over shared/planning-context.js |
| `firebase_functions/functions/agents/apply-progression.js` | 2 | Thin wrapper over shared/progressions.js |
| `firebase_functions/functions/artifacts/artifact-action.js` | 2 | Thin wrapper over shared/artifacts.js |
| `firebase_functions/functions/index.js` | 3c, 5 | Remove dead exports, remove deleted endpoints |
| `Povver/Povver/Services/SessionPreWarmer.swift` | 3c | Delete |
| `Povver/Povver/Services/SessionManager.swift` | 3c | Remove session pre-warming references |
| `Povver/Povver/Services/DirectStreamingService.swift` | 3c, 7 | Remove session ID handling, remove canvasId backward compat |
| `Povver/Povver/Models/StreamEvent.swift` | 7 | Update to 9-event contract (drop 6 legacy types) |
| `Povver/Povver/ViewModels/CanvasViewModel.swift` | 7 | Rename to ConversationViewModel, update collection paths |
| `Povver/Povver/Services/CanvasService.swift` | 7 | Rename to ConversationService, remove openCanvas/bootstrapCanvas |
| `adk_agent/canvas_orchestrator/workers/post_workout_analyst.py` | 5 | Move to adk_agent/training_analyst/ |

---

## Chunk 1: Phase 1 (Observability) + Phase 2 (Shared Business Logic)

### Task 1: Cloud Monitoring Dashboards (Phase 1)

**Files:**
- No code files — Cloud Console configuration

- [ ] **Step 1: Create Firebase Functions dashboard**

In Google Cloud Console > Monitoring > Dashboards, create "Povver — Firebase Functions":
- Widget: Function execution count by function name (metric: `cloudfunctions.googleapis.com/function/execution_count`)
- Widget: Execution latency p50/p95/p99 by function name (metric: `cloudfunctions.googleapis.com/function/execution_times`)
- Widget: Error rate by function name
- Widget: Active instances

- [ ] **Step 2: Create Cloud Run dashboard**

Create "Povver — Cloud Run":
- Widget: Request count by service
- Widget: Request latency p50/p95/p99
- Widget: Container instance count
- Widget: Billable container instance time

- [ ] **Step 3: Create alerting policies**

Create alerts:
- Function error rate > 5% over 5 min window → email notification
- Function p95 latency > 10s → email notification
- Cloud Run error rate > 5% → email notification

- [ ] **Step 4: Commit**

```bash
git add docs/plans/
git commit -m "docs: add observability setup instructions to implementation plan"
```

---

### Task 2: Shared Error Types

**Files:**
- Create: `firebase_functions/functions/shared/errors.js`
- Test: `firebase_functions/functions/tests/shared.errors.test.js`

- [ ] **Step 1: Write the failing test**

```javascript
// tests/shared.errors.test.js
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { ValidationError, NotFoundError, PermissionError, mapErrorToResponse } = require('../shared/errors');

describe('shared/errors', () => {
  test('ValidationError has correct code', () => {
    const err = new ValidationError('bad input');
    assert.equal(err.message, 'bad input');
    assert.equal(err.code, 'INVALID_ARGUMENT');
    assert.equal(err.httpStatus, 400);
  });

  test('NotFoundError has correct code', () => {
    const err = new NotFoundError('not found');
    assert.equal(err.code, 'NOT_FOUND');
    assert.equal(err.httpStatus, 404);
  });

  test('PermissionError has correct code', () => {
    const err = new PermissionError('forbidden');
    assert.equal(err.code, 'FORBIDDEN');
    assert.equal(err.httpStatus, 403);
  });

  test('mapErrorToResponse handles ValidationError', () => {
    const res = mockRes();
    const err = new ValidationError('routineId required');
    mapErrorToResponse(res, err);
    assert.equal(res._status, 400);
    assert.deepEqual(res._json, {
      success: false,
      error: { code: 'INVALID_ARGUMENT', message: 'routineId required', details: undefined }
    });
  });

  test('mapErrorToResponse handles unknown errors as INTERNAL', () => {
    const res = mockRes();
    mapErrorToResponse(res, new Error('kaboom'));
    assert.equal(res._status, 500);
    assert.equal(res._json.error.code, 'INTERNAL');
  });
});

function mockRes() {
  const r = { _status: null, _json: null };
  r.status = (s) => { r._status = s; return r; };
  r.json = (j) => { r._json = j; return r; };
  return r;
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd firebase_functions/functions && node --test tests/shared.errors.test.js
```
Expected: FAIL — `Cannot find module '../shared/errors'`

- [ ] **Step 3: Write implementation**

```javascript
// shared/errors.js
'use strict';

class AppError extends Error {
  constructor(message, code, httpStatus) {
    super(message);
    this.name = this.constructor.name;
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

class ValidationError extends AppError {
  constructor(message, details) {
    super(message, 'INVALID_ARGUMENT', 400);
    this.details = details;
  }
}

class NotFoundError extends AppError {
  constructor(message) {
    super(message, 'NOT_FOUND', 404);
  }
}

class PermissionError extends AppError {
  constructor(message) {
    super(message, 'FORBIDDEN', 403);
  }
}

function mapErrorToResponse(res, err) {
  if (err instanceof AppError) {
    return res.status(err.httpStatus).json({
      success: false,
      error: { code: err.code, message: err.message, details: err.details }
    });
  }
  console.error('Unhandled error:', err);
  return res.status(500).json({
    success: false,
    error: { code: 'INTERNAL', message: 'Internal server error', details: undefined }
  });
}

module.exports = { AppError, ValidationError, NotFoundError, PermissionError, mapErrorToResponse };
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd firebase_functions/functions && node --test tests/shared.errors.test.js
```
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add firebase_functions/functions/shared/errors.js firebase_functions/functions/tests/shared.errors.test.js
git commit -m "feat(shared): add typed error classes with mapErrorToResponse"
```

---

### Task 3: Shared Routines Module

**Files:**
- Create: `firebase_functions/functions/shared/routines.js`
- Test: `firebase_functions/functions/tests/shared.routines.test.js`
- Modify: `firebase_functions/functions/routines/get-routine.js`
- Modify: `firebase_functions/functions/routines/get-user-routines.js`
- Modify: `firebase_functions/functions/routines/create-routine.js`
- Modify: `firebase_functions/functions/routines/patch-routine.js`
- Modify: `firebase_functions/functions/routines/delete-routine.js`
- Modify: `firebase_functions/functions/routines/get-active-routine.js`
- Modify: `firebase_functions/functions/routines/set-active-routine.js`
- Modify: `firebase_functions/functions/routines/get-next-workout.js`
- Modify: `firebase_functions/functions/routines/create-routine-from-draft.js`

- [ ] **Step 1: Write tests for shared routines module**

Tests use a mock Firestore that validates the query patterns without requiring an emulator. Focus on: validation logic, error throwing, and data transformation.

```javascript
// tests/shared.routines.test.js
const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { ValidationError, NotFoundError } = require('../shared/errors');

// Mock db — inject via function parameter
function mockDb(docs = {}) {
  return {
    doc: (path) => ({
      get: async () => {
        const d = docs[path];
        return { exists: !!d, id: path.split('/').pop(), data: () => d };
      },
      set: async (data) => { docs[path] = data; },
      update: async (data) => { docs[path] = { ...(docs[path] || {}), ...data }; },
      delete: async () => { delete docs[path]; },
    }),
    collection: (path) => ({
      where: () => ({ get: async () => ({ docs: [] }) }),
      orderBy: () => ({ get: async () => ({ docs: [] }) }),
      get: async () => ({
        docs: Object.entries(docs)
          .filter(([k]) => k.startsWith(path + '/'))
          .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v, exists: true }))
      }),
      add: async (data) => {
        const id = 'auto-' + Math.random().toString(36).slice(2, 8);
        docs[`${path}/${id}`] = data;
        return { id };
      },
    }),
  };
}

describe('shared/routines', () => {
  // Tests will be imported after implementation
  // Pattern: each function receives (db, userId, ...args) — no req/res

  test('getRoutine throws ValidationError when routineId missing', async () => {
    const { getRoutine } = require('../shared/routines');
    await assert.rejects(
      () => getRoutine(mockDb(), 'user1', null),
      (err) => err instanceof ValidationError
    );
  });

  test('getRoutine throws NotFoundError when doc missing', async () => {
    const { getRoutine } = require('../shared/routines');
    await assert.rejects(
      () => getRoutine(mockDb(), 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError
    );
  });

  test('getRoutine returns routine with id', async () => {
    const { getRoutine } = require('../shared/routines');
    const docs = { 'users/user1/routines/r1': { name: 'PPL', template_ids: ['t1'] } };
    const result = await getRoutine(mockDb(docs), 'user1', 'r1');
    assert.equal(result.id, 'r1');
    assert.equal(result.name, 'PPL');
  });

  test('listRoutines returns all routines for user', async () => {
    const { listRoutines } = require('../shared/routines');
    const docs = {
      'users/user1/routines/r1': { name: 'PPL', created_at: new Date() },
      'users/user1/routines/r2': { name: 'UL', created_at: new Date() },
    };
    const result = await listRoutines(mockDb(docs), 'user1');
    assert.equal(result.length, 2);
  });

  test('deleteRoutine throws NotFoundError when doc missing', async () => {
    const { deleteRoutine } = require('../shared/routines');
    await assert.rejects(
      () => deleteRoutine(mockDb(), 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd firebase_functions/functions && node --test tests/shared.routines.test.js
```
Expected: FAIL — `Cannot find module '../shared/routines'`

- [ ] **Step 3: Write shared/routines.js**

Extract pure business logic from each handler. The pattern: each function takes `(db, userId, ...args)` and returns data or throws a typed error. No `req`, no `res`, no auth.

```javascript
// shared/routines.js
'use strict';

const { ValidationError, NotFoundError } = require('./errors');
const admin = require('firebase-admin');

async function getRoutine(db, userId, routineId) {
  if (!routineId) throw new ValidationError('routineId required');
  const doc = await db.doc(`users/${userId}/routines/${routineId}`).get();
  if (!doc.exists) throw new NotFoundError('Routine not found');
  return { id: doc.id, ...doc.data() };
}

async function listRoutines(db, userId) {
  const snapshot = await db.collection(`users/${userId}/routines`).get();
  return snapshot.docs.map(doc => ({ id: doc.id, ...doc.data() }));
}

async function createRoutine(db, userId, { name, description, frequency, template_ids }) {
  if (!name || typeof name !== 'string') throw new ValidationError('name is required');
  if (!template_ids || !Array.isArray(template_ids) || template_ids.length === 0) {
    throw new ValidationError('template_ids must be a non-empty array');
  }
  // Verify all templates exist
  const templateChecks = template_ids.map(tid =>
    db.doc(`users/${userId}/templates/${tid}`).get()
  );
  const templateDocs = await Promise.all(templateChecks);
  const missing = templateDocs.filter(d => !d.exists);
  if (missing.length > 0) throw new NotFoundError('One or more templates not found');

  const data = {
    name,
    description: description || '',
    frequency: frequency || template_ids.length,
    template_ids,
    created_at: admin.firestore.FieldValue.serverTimestamp(),
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  };
  const ref = await db.collection(`users/${userId}/routines`).add(data);
  return { id: ref.id, ...data };
}

const PATCH_ALLOWED_FIELDS = ['name', 'description', 'frequency', 'template_ids'];

async function patchRoutine(db, userId, routineId, updates) {
  if (!routineId) throw new ValidationError('routineId required');
  if (!updates || typeof updates !== 'object') throw new ValidationError('updates required');

  const doc = await db.doc(`users/${userId}/routines/${routineId}`).get();
  if (!doc.exists) throw new NotFoundError('Routine not found');

  const patch = {};
  for (const [key, value] of Object.entries(updates)) {
    if (!PATCH_ALLOWED_FIELDS.includes(key)) continue;
    patch[key] = value;
  }
  if (Object.keys(patch).length === 0) throw new ValidationError('No valid fields to update');

  // Cross-validate template_ids if changed
  if (patch.template_ids) {
    if (!Array.isArray(patch.template_ids) || patch.template_ids.length === 0) {
      throw new ValidationError('template_ids must be a non-empty array');
    }
    const checks = patch.template_ids.map(tid =>
      db.doc(`users/${userId}/templates/${tid}`).get()
    );
    const docs = await Promise.all(checks);
    if (docs.some(d => !d.exists)) throw new NotFoundError('One or more templates not found');

    // Clear cursor if removed template was the last completed
    const current = doc.data();
    if (current.last_completed_template_id &&
        !patch.template_ids.includes(current.last_completed_template_id)) {
      patch.last_completed_template_id = null;
    }
  }

  patch.updated_at = admin.firestore.FieldValue.serverTimestamp();
  await db.doc(`users/${userId}/routines/${routineId}`).update(patch);
  return { id: routineId, ...doc.data(), ...patch };
}

async function deleteRoutine(db, userId, routineId) {
  if (!routineId) throw new ValidationError('routineId required');
  const doc = await db.doc(`users/${userId}/routines/${routineId}`).get();
  if (!doc.exists) throw new NotFoundError('Routine not found');
  await db.doc(`users/${userId}/routines/${routineId}`).delete();
  return { id: routineId };
}

async function getActiveRoutine(db, userId) {
  const userDoc = await db.doc(`users/${userId}`).get();
  if (!userDoc.exists) throw new NotFoundError('User not found');
  const activeRoutineId = userDoc.data().activeRoutineId;
  if (!activeRoutineId) return null;
  return getRoutine(db, userId, activeRoutineId);
}

async function setActiveRoutine(db, userId, routineId) {
  if (!routineId) throw new ValidationError('routineId required');
  const doc = await db.doc(`users/${userId}/routines/${routineId}`).get();
  if (!doc.exists) throw new NotFoundError('Routine not found');
  await db.doc(`users/${userId}`).update({
    activeRoutineId: routineId,
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });
  return { id: routineId, ...doc.data() };
}

async function getNextWorkout(db, userId) {
  const activeRoutine = await getActiveRoutine(db, userId);
  if (!activeRoutine) return null;
  const { template_ids, last_completed_template_id } = activeRoutine;
  if (!template_ids || template_ids.length === 0) return null;

  // Find next template in rotation
  let nextIndex = 0;
  if (last_completed_template_id) {
    const lastIndex = template_ids.indexOf(last_completed_template_id);
    nextIndex = (lastIndex + 1) % template_ids.length;
  }
  const nextTemplateId = template_ids[nextIndex];
  const templateDoc = await db.doc(`users/${userId}/templates/${nextTemplateId}`).get();
  if (!templateDoc.exists) throw new NotFoundError('Next template not found');
  return { id: templateDoc.id, ...templateDoc.data(), routine_id: activeRoutine.id };
}

async function createRoutineFromDraft(db, userId, draft) {
  // draft contains: { name, templates: [{ name, exercises: [...] }] }
  if (!draft || !draft.name) throw new ValidationError('Draft must include a name');
  if (!draft.templates || !Array.isArray(draft.templates) || draft.templates.length === 0) {
    throw new ValidationError('Draft must include at least one template');
  }

  // Create templates first
  const templateIds = [];
  for (const tmpl of draft.templates) {
    const data = {
      name: tmpl.name,
      exercises: tmpl.exercises || [],
      created_at: admin.firestore.FieldValue.serverTimestamp(),
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    };
    const ref = await db.collection(`users/${userId}/templates`).add(data);
    templateIds.push(ref.id);
  }

  // Create routine
  return createRoutine(db, userId, {
    name: draft.name,
    description: draft.description || '',
    frequency: draft.frequency || templateIds.length,
    template_ids: templateIds,
  });
}

module.exports = {
  getRoutine,
  listRoutines,
  createRoutine,
  patchRoutine,
  deleteRoutine,
  getActiveRoutine,
  setActiveRoutine,
  getNextWorkout,
  createRoutineFromDraft,
};
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd firebase_functions/functions && node --test tests/shared.routines.test.js
```
Expected: All tests PASS

- [ ] **Step 5: Refactor handlers to use shared module**

Refactor each handler to be a thin HTTP wrapper. Example pattern for `get-routine.js`:

```javascript
// routines/get-routine.js (refactored)
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ok } = require('../utils/response');
const { mapErrorToResponse } = require('../shared/errors');
const { getRoutine } = require('../shared/routines');
const admin = require('firebase-admin');

async function getRoutineHandler(req, res) {
  try {
    const userId = getAuthenticatedUserId(req);
    const routineId = req.body?.routineId || req.query?.routineId;
    const routine = await getRoutine(admin.firestore(), userId, routineId);
    return ok(res, { routine });
  } catch (e) {
    return mapErrorToResponse(res, e);
  }
}

exports.getRoutine = onRequest(requireFlexibleAuth(getRoutineHandler));
```

Apply this pattern to all 9 handler files in `routines/`:
- `get-routine.js` → calls `getRoutine(db, userId, routineId)`
- `get-user-routines.js` → calls `listRoutines(db, userId)`
- `create-routine.js` → calls `createRoutine(db, userId, body)`
- `patch-routine.js` → calls `patchRoutine(db, userId, routineId, updates)`
- `delete-routine.js` → calls `deleteRoutine(db, userId, routineId)`
- `get-active-routine.js` → calls `getActiveRoutine(db, userId)`
- `set-active-routine.js` → calls `setActiveRoutine(db, userId, routineId)`
- `get-next-workout.js` → extract core logic to `shared/routines.js:getNextWorkout()`
- `create-routine-from-draft.js` → extract core logic to `shared/routines.js:createRoutineFromDraft()`

Read each handler file before refactoring to preserve any handler-specific validation or logic.

- [ ] **Step 6: Run existing tests to verify no regressions**

```bash
cd firebase_functions/functions && npm test
```
Expected: All existing tests PASS

- [ ] **Step 7: Commit**

```bash
git add firebase_functions/functions/shared/routines.js firebase_functions/functions/tests/shared.routines.test.js firebase_functions/functions/routines/
git commit -m "refactor(routines): extract business logic into shared/routines.js"
```

---

### Task 4: Shared Templates Module

**Files:**
- Create: `firebase_functions/functions/shared/templates.js`
- Test: `firebase_functions/functions/tests/shared.templates.test.js`
- Modify: `firebase_functions/functions/templates/get-template.js`
- Modify: `firebase_functions/functions/templates/get-user-templates.js`
- Modify: `firebase_functions/functions/templates/create-template.js`
- Modify: `firebase_functions/functions/templates/create-template-from-plan.js`
- Modify: `firebase_functions/functions/templates/patch-template.js`
- Modify: `firebase_functions/functions/templates/delete-template.js`

Follow the identical pattern from Task 3. Read each handler file before extracting:

- [ ] **Step 1: Write tests for shared/templates.js**

```javascript
// tests/shared.templates.test.js
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { ValidationError, NotFoundError } = require('../shared/errors');

// Use same mockDb() helper from shared.routines.test.js

describe('shared/templates', () => {
  test('getTemplate throws ValidationError when templateId missing', async () => {
    const { getTemplate } = require('../shared/templates');
    await assert.rejects(
      () => getTemplate(mockDb(), 'user1', null),
      (err) => err instanceof ValidationError
    );
  });

  test('getTemplate throws NotFoundError when doc missing', async () => {
    const { getTemplate } = require('../shared/templates');
    await assert.rejects(
      () => getTemplate(mockDb(), 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError
    );
  });

  test('getTemplate returns template with id', async () => {
    const { getTemplate } = require('../shared/templates');
    const docs = { 'users/user1/templates/t1': { name: 'Push Day', exercises: [] } };
    const result = await getTemplate(mockDb(docs), 'user1', 't1');
    assert.equal(result.id, 't1');
    assert.equal(result.name, 'Push Day');
  });

  test('listTemplates returns all templates for user', async () => {
    const { listTemplates } = require('../shared/templates');
    const docs = {
      'users/user1/templates/t1': { name: 'Push', created_at: new Date() },
      'users/user1/templates/t2': { name: 'Pull', created_at: new Date() },
    };
    const result = await listTemplates(mockDb(docs), 'user1');
    assert.equal(result.length, 2);
  });

  test('createTemplate validates name is required', async () => {
    const { createTemplate } = require('../shared/templates');
    await assert.rejects(
      () => createTemplate(mockDb(), 'user1', { exercises: [] }),
      (err) => err instanceof ValidationError
    );
  });

  test('deleteTemplate throws NotFoundError when doc missing', async () => {
    const { deleteTemplate } = require('../shared/templates');
    await assert.rejects(
      () => deleteTemplate(mockDb(), 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd firebase_functions/functions && node --test tests/shared.templates.test.js
```
Expected: FAIL — `Cannot find module '../shared/templates'`

- [ ] **Step 3: Write shared/templates.js**

Read each handler file first. Extract:
- `getTemplate(db, userId, templateId)` — from `get-template.js`
- `listTemplates(db, userId)` — from `get-user-templates.js`
- `createTemplate(db, userId, data)` — from `create-template.js`, uses Zod `TemplateSchema` from `utils/validators.js`
- `patchTemplate(db, userId, templateId, updates)` — from `patch-template.js`, allowlisted fields
- `deleteTemplate(db, userId, templateId)` — from `delete-template.js`
- `createTemplateFromPlan(db, userId, plan)` — from `create-template-from-plan.js`, uses `utils/plan-to-template-converter.js`

Each function follows the same pattern as `shared/routines.js`: takes `(db, userId, ...)`, returns data or throws typed error.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd firebase_functions/functions && node --test tests/shared.templates.test.js
```
Expected: All tests PASS

- [ ] **Step 5: Refactor all 6 template handlers to thin wrappers**

Apply the same thin wrapper pattern from Task 3, Step 5:
- `get-template.js` → calls `getTemplate(db, userId, templateId)`
- `get-user-templates.js` → calls `listTemplates(db, userId)`
- `create-template.js` → calls `createTemplate(db, userId, body)`
- `create-template-from-plan.js` → calls `createTemplateFromPlan(db, userId, plan)`
- `patch-template.js` → calls `patchTemplate(db, userId, templateId, updates)`
- `delete-template.js` → calls `deleteTemplate(db, userId, templateId)`

- [ ] **Step 6: Run full test suite**

```bash
cd firebase_functions/functions && npm test
```
Expected: All existing tests PASS

- [ ] **Step 7: Commit**

```bash
git add firebase_functions/functions/shared/templates.js firebase_functions/functions/tests/shared.templates.test.js firebase_functions/functions/templates/
git commit -m "refactor(templates): extract business logic into shared/templates.js"
```

---

### Task 5: Shared Workouts Module

**Files:**
- Create: `firebase_functions/functions/shared/workouts.js`
- Test: `firebase_functions/functions/tests/shared.workouts.test.js`
- Modify: `firebase_functions/functions/workouts/get-workout.js`
- Modify: `firebase_functions/functions/workouts/get-user-workouts.js`
- Modify: `firebase_functions/functions/workouts/upsert-workout.js`
- Modify: `firebase_functions/functions/workouts/delete-workout.js`

- [ ] **Step 1: Write tests**

```javascript
// tests/shared.workouts.test.js
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { ValidationError, NotFoundError } = require('../shared/errors');

describe('shared/workouts', () => {
  test('getWorkout throws ValidationError when workoutId missing', async () => {
    const { getWorkout } = require('../shared/workouts');
    await assert.rejects(() => getWorkout(mockDb(), 'user1', null),
      (err) => err instanceof ValidationError);
  });

  test('getWorkout throws NotFoundError when doc missing', async () => {
    const { getWorkout } = require('../shared/workouts');
    await assert.rejects(() => getWorkout(mockDb(), 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError);
  });

  test('listWorkouts returns paginated results', async () => {
    const { listWorkouts } = require('../shared/workouts');
    // Test with mockDb containing 3 workouts, limit=2
    // Verify returns 2 items + hasMore flag
  });

  test('deleteWorkout throws NotFoundError when doc missing', async () => {
    const { deleteWorkout } = require('../shared/workouts');
    await assert.rejects(() => deleteWorkout(mockDb(), 'user1', 'nonexistent'),
      (err) => err instanceof NotFoundError);
  });
});
```

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd firebase_functions/functions && node --test tests/shared.workouts.test.js
```

- [ ] **Step 3: Write shared/workouts.js**

Read `get-user-workouts.js` first to understand pagination pattern. Extract:
- `getWorkout(db, userId, workoutId)`
- `listWorkouts(db, userId, { limit, cursor, startDate, endDate })` — cursor-based, ordered by `start_time` desc
- `upsertWorkout(db, userId, workoutData)` — from `upsert-workout.js`
- `deleteWorkout(db, userId, workoutId)` — from `delete-workout.js`

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd firebase_functions/functions && node --test tests/shared.workouts.test.js
```

- [ ] **Step 5: Refactor handlers to thin wrappers**

Apply thin wrapper pattern to all 4 workout handlers.

- [ ] **Step 6: Run full test suite**

```bash
cd firebase_functions/functions && npm test
```

- [ ] **Step 7: Commit**

```bash
git add firebase_functions/functions/shared/workouts.js firebase_functions/functions/tests/shared.workouts.test.js firebase_functions/functions/workouts/
git commit -m "refactor(workouts): extract business logic into shared/workouts.js"
```

---

### Task 6: Shared Exercises Module

**Files:**
- Create: `firebase_functions/functions/shared/exercises.js`
- Test: `firebase_functions/functions/tests/shared.exercises.test.js`
- Modify: Relevant handlers in `firebase_functions/functions/exercises/`

- [ ] **Step 1: Write tests**

```javascript
// tests/shared.exercises.test.js
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

describe('shared/exercises', () => {
  test('listExercises returns canonical-only by default', async () => {
    const { listExercises } = require('../shared/exercises');
    // Mock db with 3 exercises: 2 canonical, 1 merged
    // Verify only 2 returned when canonicalOnly=true (default)
  });

  test('listExercises includes merged when requested', async () => {
    const { listExercises } = require('../shared/exercises');
    // Verify all 3 returned when canonicalOnly=false
  });

  test('searchExercises filters by name prefix', async () => {
    const { searchExercises } = require('../shared/exercises');
    // Mock exercises, search for "bench", verify correct matches
  });
});
```

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd firebase_functions/functions && node --test tests/shared.exercises.test.js
```

- [ ] **Step 3: Write shared/exercises.js**

Read `exercises/get-exercises.js` and any search endpoint. The exercises collection is top-level (`exercises/{id}`), not user-scoped. Extract:
- `listExercises(db, { limit, canonicalOnly })` — from `get-exercises.js`, preserves canonical filtering
- `getExercise(db, exerciseId)` — single exercise lookup
- `searchExercises(db, query, { limit })` — name-based search
- `resolveExercise(db, name)` — resolve exercise by name (for the catalog orchestrator)

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd firebase_functions/functions && node --test tests/shared.exercises.test.js
```

- [ ] **Step 5: Refactor exercise handlers to thin wrappers**
- [ ] **Step 6: Run full test suite**

```bash
cd firebase_functions/functions && npm test
```

- [ ] **Step 7: Commit**

```bash
git add firebase_functions/functions/shared/exercises.js firebase_functions/functions/tests/shared.exercises.test.js firebase_functions/functions/exercises/
git commit -m "refactor(exercises): extract business logic into shared/exercises.js"
```

---

### Task 7: Shared Training Queries Module

**Files:**
- Create: `firebase_functions/functions/shared/training-queries.js`
- Test: `firebase_functions/functions/tests/shared.training-queries.test.js`
- Modify: `firebase_functions/functions/training/query-sets.js`
- Modify: `firebase_functions/functions/training/series-endpoints.js`
- Modify: `firebase_functions/functions/training/get-analysis-summary.js`
- Modify: `firebase_functions/functions/training/progress-summary.js`

- [ ] **Step 1: Write tests**

Key tests: `querySets` (with filters, pagination, projection), `getAnalysisSummary`, `getMuscleGroupSummary`, `getExerciseSummary`. These are the most complex queries — test the filter building logic.

- [ ] **Step 2: Run test — expect FAIL**
- [ ] **Step 3: Write shared/training-queries.js**

This is the most complex extraction. Read each training handler carefully. Key concerns:
- `querySets` uses `utils/caps.js` for pagination, projection, cursor encoding. Import and reuse these.
- `series-endpoints.js` likely serves muscle group / exercise progress data.
- `get-analysis-summary.js` reads from `analysis_insights` and `weekly_reviews`.
- Preserve the validation from `utils/muscle-taxonomy.js` (validateMuscleGroupWithRecovery).

Functions to extract:
- `querySets(db, userId, { target, classification, effort, performance, sort, cursor, start, end, limit, fields })`
- `getAnalysisSummary(db, userId, { sections, date })`
- `getMuscleGroupSummary(db, userId, { group, weeks })`
- `getMuscleSummary(db, userId, { muscle, weeks })`
- `getExerciseSummary(db, userId, { exercise, weeks })`

- [ ] **Step 4: Run tests — expect PASS**
- [ ] **Step 5: Refactor training handlers to thin wrappers**
- [ ] **Step 6: Run full test suite**
- [ ] **Step 7: Commit**

```bash
git add firebase_functions/functions/shared/training-queries.js firebase_functions/functions/tests/shared.training-queries.test.js firebase_functions/functions/training/
git commit -m "refactor(training): extract query logic into shared/training-queries.js"
```

---

### Task 8: Shared Planning Context Module

**Files:**
- Create: `firebase_functions/functions/shared/planning-context.js`
- Test: `firebase_functions/functions/tests/shared.planning-context.test.js`
- Modify: `firebase_functions/functions/training/context-pack.js`

- [ ] **Step 1: Write tests**

Test `getPlanningContext(db, userId)` returns the assembled context object with user profile, active routine, training snapshot, and strength summary.

- [ ] **Step 2: Run test — expect FAIL**
- [ ] **Step 3: Write shared/planning-context.js**

Read `training/context-pack.js` to understand the current context assembly. Extract the core assembly logic. This function assembles:
- User profile (from `users/{uid}`)
- Active routine + its templates
- Recent workout summary (last N workouts)
- Training analysis highlights
- Weekly stats snapshot

```javascript
async function getPlanningContext(db, userId) {
  const [userDoc, activeRoutine, recentWorkouts] = await Promise.all([
    db.doc(`users/${userId}`).get(),
    getActiveRoutineWithTemplates(db, userId),
    getRecentWorkouts(db, userId, 5),
  ]);
  // ... assemble and return
}
```

- [ ] **Step 4: Run tests — expect PASS**
- [ ] **Step 5: Refactor context-pack.js handler**
- [ ] **Step 6: Run full test suite**
- [ ] **Step 7: Commit**

```bash
git add firebase_functions/functions/shared/planning-context.js firebase_functions/functions/tests/shared.planning-context.test.js firebase_functions/functions/training/context-pack.js
git commit -m "refactor(planning): extract getPlanningContext into shared module"
```

---

### Task 8b: Shared Artifacts Module

**Files:**
- Create: `firebase_functions/functions/shared/artifacts.js`
- Test: `firebase_functions/functions/tests/shared.artifacts.test.js`
- Modify: `firebase_functions/functions/artifacts/artifact-action.js`

- [ ] **Step 1: Read the current artifact-action.js**

Read `firebase_functions/functions/artifacts/artifact-action.js` (~401 lines). Understand all 6 action types: `accept`, `dismiss`, `save_routine`, `start_workout`, `save_template`, `save_as_new`.

- [ ] **Step 2: Write tests for shared artifacts module**

Test the core operations: getArtifact, acceptArtifact, dismissArtifact, saveRoutineFromArtifact. Focus on validation, error cases, and data transformation.

- [ ] **Step 3: Write shared/artifacts.js**

Extract the action dispatch logic into pure functions. Each function takes `(db, userId, conversationId, artifactId, options)` — no req/res:

```javascript
// shared/artifacts.js
'use strict';
const { ValidationError, NotFoundError } = require('./errors');
const admin = require('firebase-admin');

// Uses 'canvases' until Phase 7 coordinated rename to 'conversations'.
const CONVERSATION_COLLECTION = process.env.CONVERSATION_COLLECTION || 'canvases';

async function getArtifact(db, userId, conversationId, artifactId) {
  const doc = await db.doc(
    `users/${userId}/${CONVERSATION_COLLECTION}/${conversationId}/artifacts/${artifactId}`
  ).get();
  if (!doc.exists) throw new NotFoundError('Artifact not found');
  return { id: doc.id, ...doc.data() };
}

async function acceptArtifact(db, userId, conversationId, artifactId) {
  const artifact = await getArtifact(db, userId, conversationId, artifactId);
  await db.doc(
    `users/${userId}/${CONVERSATION_COLLECTION}/${conversationId}/artifacts/${artifactId}`
  ).update({ status: 'accepted', accepted_at: admin.firestore.FieldValue.serverTimestamp() });
  return { ...artifact, status: 'accepted' };
}

async function dismissArtifact(db, userId, conversationId, artifactId) {
  await db.doc(
    `users/${userId}/${CONVERSATION_COLLECTION}/${conversationId}/artifacts/${artifactId}`
  ).update({ status: 'dismissed', dismissed_at: admin.firestore.FieldValue.serverTimestamp() });
}

// saveRoutineFromArtifact, saveTemplateFromArtifact — port from artifact-action.js
// These create real routines/templates from artifact data

module.exports = { getArtifact, acceptArtifact, dismissArtifact /* ... */ };
```

- [ ] **Step 4: Refactor artifact-action.js to thin wrapper**

Replace inline logic with calls to shared/artifacts.js.

- [ ] **Step 5: Run tests, commit**

```bash
cd firebase_functions/functions && node --test tests/shared.artifacts.test.js && npm test
git add firebase_functions/functions/shared/artifacts.js firebase_functions/functions/tests/shared.artifacts.test.js firebase_functions/functions/artifacts/artifact-action.js
git commit -m "refactor(artifacts): extract artifact actions into shared module"
```

---

### Task 8c: Shared Progressions Module

**Files:**
- Create: `firebase_functions/functions/shared/progressions.js`
- Test: `firebase_functions/functions/tests/shared.progressions.test.js`
- Modify: `firebase_functions/functions/agents/apply-progression.js`

- [ ] **Step 1: Read apply-progression.js**

Read `firebase_functions/functions/agents/apply-progression.js` (~327 lines). Understand: auto-apply mode, review mode, nested path handling (`setNestedValue`/`resolvePathValue`), changelog entries, recommendation audit trail.

- [ ] **Step 2: Write tests for shared progressions module**

Test: validation, nested path resolution, auto-apply write, review-mode recommendation creation.

- [ ] **Step 3: Write shared/progressions.js**

Extract core progression logic:

```javascript
// shared/progressions.js
'use strict';
const { ValidationError, NotFoundError } = require('./errors');
const admin = require('firebase-admin');

function setNestedValue(obj, path, value) {
  // Port from apply-progression.js — handles paths like "exercises[0].sets[0].weight"
  // ...
}

async function applyProgression(db, userId, { targetType, targetId, changes, summary, rationale, trigger, autoApply = true }) {
  if (!targetId) throw new ValidationError('targetId required');
  if (!changes || changes.length === 0) throw new ValidationError('changes required');

  const targetPath = targetType === 'template'
    ? `users/${userId}/templates/${targetId}`
    : `users/${userId}/routines/${targetId}`;

  const doc = await db.doc(targetPath).get();
  if (!doc.exists) throw new NotFoundError(`${targetType} not found`);

  // Create recommendation record (audit trail)
  const recData = {
    userId, targetType, targetId, changes, summary, rationale,
    trigger: trigger || 'user_request',
    state: autoApply ? 'applied' : 'pending_review',
    created_at: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (autoApply) {
    // Apply changes to target document
    const data = doc.data();
    for (const change of changes) {
      setNestedValue(data, change.path, change.value);
    }
    data.updated_at = admin.firestore.FieldValue.serverTimestamp();
    await db.doc(targetPath).set(data);

    // Write changelog entry (for templates)
    if (targetType === 'template') {
      await db.collection(`users/${userId}/templates/${targetId}/changelog`).add({
        changes, summary, trigger, applied_at: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  const recRef = await db.collection(`users/${userId}/agent_recommendations`).add(recData);
  return { id: recRef.id, ...recData };
}

module.exports = { applyProgression, setNestedValue };
```

- [ ] **Step 4: Refactor apply-progression.js to thin wrapper**

Replace inline logic with calls to shared/progressions.js. Keep `withApiKey` auth wrapping.

- [ ] **Step 5: Also refactor agents/get-planning-context.js**

Make it a thin wrapper over `shared/planning-context.js`:

```javascript
const { getPlanningContext } = require('../shared/planning-context');
// ... handler calls getPlanningContext(db, userId, options)
```

- [ ] **Step 6: Run tests, commit**

```bash
cd firebase_functions/functions && node --test tests/shared.progressions.test.js && npm test
git add firebase_functions/functions/shared/progressions.js firebase_functions/functions/tests/shared.progressions.test.js firebase_functions/functions/agents/apply-progression.js firebase_functions/functions/agents/get-planning-context.js
git commit -m "refactor(agents): extract progressions + planning-context into shared modules"
```

---

### Task 9: Phase 2 Integration Verification

- [ ] **Step 1: Run full Firebase Functions test suite**

```bash
cd firebase_functions/functions && npm test
```
Expected: All tests PASS

- [ ] **Step 2: Deploy to emulator and smoke test**

```bash
cd firebase_functions/functions && npm run serve
```

Test key endpoints manually via curl or the iOS app against the emulator:
- `GET /getRoutine` with valid/invalid routineId
- `GET /getUserRoutines`
- `POST /createRoutine`
- `POST /patchRoutine`
- `GET /getTemplate`, `POST /createTemplate`
- `GET /getUserWorkouts`
- `POST /querySets`

- [ ] **Step 3: Verify shared modules export correctly**

```bash
cd firebase_functions/functions && node -e "
  const r = require('./shared/routines');
  const t = require('./shared/templates');
  const w = require('./shared/workouts');
  const e = require('./shared/exercises');
  const q = require('./shared/training-queries');
  const p = require('./shared/planning-context');
  const a = require('./shared/artifacts');
  const pr = require('./shared/progressions');
  const err = require('./shared/errors');
  console.log('All shared modules load successfully');
  console.log('Routines:', Object.keys(r));
  console.log('Templates:', Object.keys(t));
  console.log('Workouts:', Object.keys(w));
  console.log('Exercises:', Object.keys(e));
  console.log('Training:', Object.keys(q));
  console.log('Planning:', Object.keys(p));
  console.log('Artifacts:', Object.keys(a));
  console.log('Progressions:', Object.keys(pr));
  console.log('Errors:', Object.keys(err));
"
```

- [ ] **Step 4: Deploy Firebase Functions**

```bash
cd firebase_functions/functions && npm run deploy
```

- [ ] **Step 5: Update documentation**

Update `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md` to document the shared module layer.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(shared): complete Phase 2 — shared business logic extraction

Extracted pure business logic from all CRUD handlers into shared/ modules:
- shared/errors.js — typed errors with HTTP mapping
- shared/routines.js — routine CRUD + active routine + next workout
- shared/templates.js — template CRUD + createFromPlan
- shared/workouts.js — workout CRUD with pagination
- shared/exercises.js — exercise queries + search + resolve
- shared/training-queries.js — querySets, series endpoints, analysis
- shared/planning-context.js — getPlanningContext assembler
- shared/artifacts.js — artifact actions (accept, dismiss, save)
- shared/progressions.js — progression apply/suggest with audit trail

All Firebase Function handlers refactored to thin HTTP wrappers.
agents/get-planning-context.js and agents/apply-progression.js now use shared modules.
All existing tests pass. Shared modules have dedicated unit tests."
```

---

## Chunk 2: Phase 3a Part 1 — Agent Service Infrastructure

### Task 10: Agent Service Scaffold

**Files:**
- Create: `adk_agent/agent_service/requirements.txt`
- Create: `adk_agent/agent_service/Makefile`
- Create: `adk_agent/agent_service/Dockerfile`
- Create: `adk_agent/agent_service/app/__init__.py`

- [ ] **Step 1: Create requirements.txt**

```
# Core
starlette==0.41.3
uvicorn[standard]==0.32.1
httpx==0.28.1

# LLM
google-genai==1.20.0

# Firebase
google-cloud-firestore==2.19.0
google-cloud-logging==3.11.4
firebase-admin==6.6.0

# Observability
opentelemetry-api==1.29.0
opentelemetry-sdk==1.29.0
opentelemetry-exporter-gcp-trace==1.9.0

# Utils
python-dotenv==1.1.0
pydantic==2.11.7

# Testing
pytest==8.3.4
pytest-asyncio==0.24.0
```

- [ ] **Step 2: Create Makefile**

```makefile
.PHONY: help install test dev deploy lint format check

PROJECT_ID ?= myon-53d85
REGION ?= us-central1
IMAGE_TAG ?= latest
SERVICE_NAME ?= agent-service

help:
	@echo "Agent Service"
	@echo "============="
	@echo ""
	@echo "Development:"
	@echo "  make install    - Install dependencies"
	@echo "  make test       - Run tests"
	@echo "  make dev        - Run locally"
	@echo "  make lint       - Run linter"
	@echo "  make format     - Format code"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy     - Build + deploy to Cloud Run"

install:
	pip install -r requirements.txt

test:
	python -m pytest tests/ -v

dev:
	uvicorn app.main:app --reload --port 8080

lint:
	python -m ruff check app/ tests/

format:
	python -m ruff format app/ tests/

deploy:
	cp -r ../shared shared/
	gcloud builds submit --tag gcr.io/$(PROJECT_ID)/$(SERVICE_NAME):$(IMAGE_TAG) --project=$(PROJECT_ID); \
	rm -rf shared/
	gcloud run deploy $(SERVICE_NAME) \
		--image gcr.io/$(PROJECT_ID)/$(SERVICE_NAME):$(IMAGE_TAG) \
		--region $(REGION) \
		--platform managed \
		--no-allow-unauthenticated \
		--memory 512Mi \
		--cpu 1 \
		--min-instances 0 \
		--max-instances 10 \
		--timeout 300 \
		--concurrency 1 \
		--service-account ai-agents@$(PROJECT_ID).iam.gserviceaccount.com \
		--set-env-vars "PROJECT_ID=$(PROJECT_ID),GOOGLE_CLOUD_PROJECT=$(PROJECT_ID),ENABLE_USAGE_TRACKING=true,CONVERSATION_COLLECTION=canvases,FIREBASE_API_KEY=$${FIREBASE_API_KEY:?Set FIREBASE_API_KEY env var},MYON_API_KEY=$${MYON_API_KEY:?Set MYON_API_KEY env var},MYON_FUNCTIONS_BASE_URL=$${MYON_FUNCTIONS_BASE_URL:-https://us-central1-myon-53d85.cloudfunctions.net}"
```

- [ ] **Step 3: Create Dockerfile**

```dockerfile
FROM --platform=linux/amd64 python:3.11-slim

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/
COPY shared/ shared/

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 4: Create app/__init__.py**

```python
# Agent Service — Povver AI coaching agent
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/
git commit -m "feat(agent): scaffold Cloud Run agent service"
```

---

### Task 11: Request Context

**Files:**
- Create: `adk_agent/agent_service/app/context.py`
- Test: `adk_agent/agent_service/tests/__init__.py`
- Test: `adk_agent/agent_service/tests/test_context.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_context.py
import pytest
from app.context import RequestContext


def test_request_context_creation():
    ctx = RequestContext(
        user_id="user123",
        conversation_id="conv456",
        correlation_id="corr789",
    )
    assert ctx.user_id == "user123"
    assert ctx.conversation_id == "conv456"
    assert ctx.correlation_id == "corr789"
    assert ctx.workout_mode is False
    assert ctx.active_workout_id is None


def test_request_context_workout_mode():
    ctx = RequestContext(
        user_id="user123",
        conversation_id="conv456",
        correlation_id="corr789",
        workout_mode=True,
        active_workout_id="aw001",
    )
    assert ctx.workout_mode is True
    assert ctx.active_workout_id == "aw001"


def test_request_context_is_immutable():
    ctx = RequestContext(user_id="u", conversation_id="c", correlation_id="r")
    with pytest.raises(AttributeError):
        ctx.user_id = "other"
```

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_context.py -v
```

- [ ] **Step 3: Write implementation**

```python
# app/context.py
"""Request context — replaces ContextVar approach from ADK."""

from dataclasses import dataclass


@dataclass(frozen=True)
class RequestContext:
    """Immutable per-request context. Passed as function arg, not ContextVar."""
    user_id: str
    conversation_id: str
    correlation_id: str
    workout_id: str | None = None  # Active workout ID from iOS (enables workout mode)
    workout_mode: bool = False     # Set True when workout_id is present
    today: str | None = None       # YYYY-MM-DD, set from client timezone
```

- [ ] **Step 4: Run test — expect PASS**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_context.py -v
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/context.py adk_agent/agent_service/tests/
git commit -m "feat(agent): add RequestContext dataclass"
```

---

### Task 12: LLM Client Protocol + Gemini Implementation

**Files:**
- Create: `adk_agent/agent_service/app/llm/__init__.py`
- Create: `adk_agent/agent_service/app/llm/protocol.py`
- Create: `adk_agent/agent_service/app/llm/gemini.py`
- Test: `adk_agent/agent_service/tests/test_llm_protocol.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_llm_protocol.py
import pytest
from app.llm.protocol import LLMChunk, ToolCallChunk


def test_text_chunk():
    chunk = LLMChunk(text="hello")
    assert chunk.is_text is True
    assert chunk.is_tool_call is False
    assert chunk.text == "hello"


def test_tool_call_chunk():
    tc = ToolCallChunk(call_id="c1", tool_name="get_routine", args={"routine_id": "r1"})
    chunk = LLMChunk(tool_call=tc)
    assert chunk.is_text is False
    assert chunk.is_tool_call is True
    assert chunk.tool_call.tool_name == "get_routine"


def test_llm_client_protocol_exists():
    from app.llm.protocol import LLMClient
    # Verify it's a Protocol with a stream method
    import inspect
    assert hasattr(LLMClient, 'stream')


def test_model_config_defaults():
    from app.llm.protocol import ModelConfig
    config = ModelConfig()
    assert config.temperature == 0.3
    assert config.max_output_tokens == 8192
```

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_llm_protocol.py -v
```

- [ ] **Step 3: Write protocol.py**

```python
# app/llm/protocol.py
"""LLM client abstraction — model-agnostic interface."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Protocol, runtime_checkable


@dataclass
class ToolCallChunk:
    call_id: str
    tool_name: str
    args: dict[str, Any]


@dataclass
class LLMChunk:
    text: str | None = None
    tool_call: ToolCallChunk | None = None
    usage: dict | None = None  # {"input_tokens": N, "output_tokens": N} — set on final chunk

    @property
    def is_text(self) -> bool:
        return self.text is not None

    @property
    def is_tool_call(self) -> bool:
        return self.tool_call is not None


@dataclass
class ModelConfig:
    temperature: float = 0.3
    max_output_tokens: int = 8192
    max_context_tokens: int = 1_000_000  # Model-specific, overridden per client
    json_mode: bool = False


@dataclass
class ToolDef:
    """Tool definition for the LLM."""
    name: str
    description: str
    parameters: dict[str, Any]  # JSON Schema


@runtime_checkable
class LLMClient(Protocol):
    async def stream(
        self,
        model: str,
        messages: list[dict],
        tools: list[ToolDef] | None = None,
        config: ModelConfig | None = None,
    ) -> AsyncIterator[LLMChunk]: ...
```

- [ ] **Step 4: Run test — expect PASS**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_llm_protocol.py -v
```

- [ ] **Step 5: Write gemini.py**

```python
# app/llm/gemini.py
"""Gemini LLM client using google-genai SDK."""

from __future__ import annotations

import logging
from typing import Any, AsyncIterator

from google import genai
from google.genai import types

from app.llm.protocol import LLMChunk, LLMClient, ModelConfig, ToolCallChunk, ToolDef

logger = logging.getLogger(__name__)


class GeminiClient:
    """Gemini client implementing LLMClient protocol."""

    def __init__(self):
        self.client = genai.Client()

    async def stream(
        self,
        model: str,
        messages: list[dict],
        tools: list[ToolDef] | None = None,
        config: ModelConfig | None = None,
    ) -> AsyncIterator[LLMChunk]:
        config = config or ModelConfig()

        # Convert messages to Gemini format
        gemini_contents = self._to_gemini_contents(messages)

        # Convert tools to Gemini format
        gemini_tools = self._to_gemini_tools(tools) if tools else None

        # Extract system instruction (Gemini handles it as a separate parameter)
        system_instruction = self._extract_system_instruction(messages)

        gen_config = types.GenerateContentConfig(
            temperature=config.temperature,
            max_output_tokens=config.max_output_tokens,
            system_instruction=system_instruction,
        )

        async for response in self.client.aio.models.generate_content_stream(
            model=model,
            contents=gemini_contents,
            config=gen_config,
            tools=gemini_tools,
        ):
            # Extract usage metadata (present on final chunk)
            usage = None
            if hasattr(response, "usage_metadata") and response.usage_metadata:
                meta = response.usage_metadata
                usage = {
                    "input_tokens": getattr(meta, "prompt_token_count", 0) or 0,
                    "output_tokens": getattr(meta, "candidates_token_count", 0) or 0,
                }

            for part in response.candidates[0].content.parts:
                if part.text:
                    yield LLMChunk(text=part.text, usage=usage)
                elif part.function_call:
                    yield LLMChunk(tool_call=ToolCallChunk(
                        call_id=part.function_call.id or part.function_call.name,
                        tool_name=part.function_call.name,
                        args=dict(part.function_call.args) if part.function_call.args else {},
                    ), usage=usage)

    def _extract_system_instruction(self, messages: list[dict]) -> str | None:
        """Extract system instruction from messages (Gemini handles it separately)."""
        for msg in messages:
            if msg["role"] == "system":
                return msg["content"]
        return None

    def _to_gemini_contents(self, messages: list[dict]) -> list:
        """Convert generic messages to Gemini Content format."""
        contents = []
        for msg in messages:
            role = msg["role"]
            if role == "system":
                continue  # Handled via system_instruction parameter
            gemini_role = "user" if role == "user" else "model"
            if "tool_result" in msg:
                contents.append(types.Content(
                    role="user",
                    parts=[types.Part(function_response=types.FunctionResponse(
                        name=msg["tool_name"],
                        response=msg["tool_result"],
                    ))],
                ))
            else:
                contents.append(types.Content(
                    role=gemini_role,
                    parts=[types.Part(text=msg["content"])],
                ))
        return contents

    def _to_gemini_tools(self, tools: list[ToolDef]) -> list:
        """Convert ToolDef list to Gemini tool format."""
        declarations = []
        for tool in tools:
            declarations.append(types.FunctionDeclaration(
                name=tool.name,
                description=tool.description,
                parameters=tool.parameters,
            ))
        return [types.Tool(function_declarations=declarations)]
```

- [ ] **Step 6: Write __init__.py**

```python
# app/llm/__init__.py
from app.llm.protocol import LLMChunk, LLMClient, ModelConfig, ToolCallChunk, ToolDef
from app.llm.gemini import GeminiClient

__all__ = ["LLMChunk", "LLMClient", "ModelConfig", "ToolCallChunk", "ToolDef", "GeminiClient"]
```

- [ ] **Step 7: Commit**

```bash
git add adk_agent/agent_service/app/llm/ adk_agent/agent_service/tests/test_llm_protocol.py
git commit -m "feat(agent): add LLM client protocol + Gemini implementation"
```

---

### Task 13: Agent Loop

**Files:**
- Create: `adk_agent/agent_service/app/agent_loop.py`
- Test: `adk_agent/agent_service/tests/test_agent_loop.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_agent_loop.py
import pytest
import json
from unittest.mock import AsyncMock, MagicMock
from app.agent_loop import run_agent_loop, SSEEvent
from app.llm.protocol import LLMChunk, ToolCallChunk, ModelConfig, ToolDef
from app.context import RequestContext


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


class FakeLLMClient:
    """LLM client that returns a scripted sequence of responses."""

    def __init__(self, turns: list[list[LLMChunk]]):
        self.turns = iter(turns)

    async def stream(self, model, messages, tools=None, config=None):
        for chunk in next(self.turns):
            yield chunk


@pytest.mark.asyncio
async def test_text_only_response(ctx):
    """LLM returns text, no tool calls — single turn."""
    client = FakeLLMClient([[LLMChunk(text="Hello!")]])

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="You are a coach",
        history=[],
        message="Hi",
        tools=[],
        tool_executor=AsyncMock(),
        ctx=ctx,
    ):
        events.append(event)

    assert any(e.event == "message" and "Hello" in e.data for e in events)
    assert events[-1].event == "done"


@pytest.mark.asyncio
async def test_tool_call_then_response(ctx):
    """LLM calls a tool, gets result, then responds with text."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "get_routine", {"routine_id": "r1"}))],
        [LLMChunk(text="Your routine is PPL")],
    ])

    async def mock_executor(tool_name, args, context):
        return {"name": "PPL", "template_ids": ["t1", "t2"]}

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="You are a coach",
        history=[],
        message="What's my routine?",
        tools=[ToolDef("get_routine", "Get routine", {})],
        tool_executor=mock_executor,
        ctx=ctx,
    ):
        events.append(event)

    event_types = [e.event for e in events]
    assert "tool_start" in event_types
    assert "tool_end" in event_types
    assert "message" in event_types
    assert events[-1].event == "done"


@pytest.mark.asyncio
async def test_tool_error_returned_to_model(ctx):
    """Tool raises exception — error is returned to model for recovery."""
    client = FakeLLMClient([
        [LLMChunk(tool_call=ToolCallChunk("c1", "get_routine", {"routine_id": "bad"}))],
        [LLMChunk(text="Sorry, I couldn't find that routine.")],
    ])

    async def failing_executor(tool_name, args, context):
        raise ValueError("Routine not found")

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Get my routine",
        tools=[ToolDef("get_routine", "Get routine", {})],
        tool_executor=failing_executor,
        ctx=ctx,
    ):
        events.append(event)

    assert events[-1].event == "done"
    assert any(e.event == "message" for e in events)


@pytest.mark.asyncio
async def test_max_turns_guard(ctx):
    """Agent loop terminates after MAX_TOOL_TURNS."""
    # Every turn returns a tool call — should hit the limit
    infinite_tools = [[LLMChunk(tool_call=ToolCallChunk(f"c{i}", "noop", {}))]
                      for i in range(20)]
    client = FakeLLMClient(infinite_tools)

    async def noop_executor(tool_name, args, context):
        return {"ok": True}

    events = []
    async for event in run_agent_loop(
        llm_client=client,
        model="gemini-2.5-flash",
        instruction="",
        history=[],
        message="Loop forever",
        tools=[ToolDef("noop", "Do nothing", {})],
        tool_executor=noop_executor,
        ctx=ctx,
        max_tool_turns=3,
    ):
        events.append(event)

    # Should have exactly 3 tool_start events, then a graceful termination
    tool_starts = [e for e in events if e.event == "tool_start"]
    assert len(tool_starts) == 3
    assert events[-1].event == "done"
```

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_agent_loop.py -v
```

- [ ] **Step 3: Write implementation**

```python
# app/agent_loop.py
"""Core agent loop — replaces ADK's Runner.

Emits all 9 SSE event types:
- message, tool_start, tool_end, done — directly from the loop
- artifact, clarification — detected from tool return values
- status — emitted at tool call start based on TOOL_STATUS_MAP
- heartbeat — background task during LLM streaming
- error — try/catch around the entire loop
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Callable, Awaitable

from app.context import RequestContext
from app.llm.protocol import LLMClient, LLMChunk, ModelConfig, ToolDef
from app.observability import log_tokens
from shared.usage_tracker import track_usage

logger = logging.getLogger(__name__)

MAX_TOOL_TURNS = 12
HEARTBEAT_INTERVAL_S = 15

# Tool name → user-facing status message for iOS status events
TOOL_STATUS_MAP = {
    "get_training_context": "Reviewing your training profile...",
    "get_muscle_group_progress": "Analyzing muscle group data...",
    "get_exercise_progress": "Looking at exercise history...",
    "query_training_sets": "Querying your training sets...",
    "get_training_analysis": "Loading training analysis...",
    "propose_workout": "Building your workout...",
    "propose_routine": "Designing your routine...",
    "search_exercises": "Searching exercise catalog...",
    "get_workout_state": "Checking current workout...",
}


@dataclass
class SSEEvent:
    event: str
    data: str

    def encode(self) -> str:
        return f"event: {self.event}\ndata: {self.data}\n\n"


def sse_event(event: str, data: Any) -> SSEEvent:
    if isinstance(data, str):
        return SSEEvent(event=event, data=json.dumps({"text": data}))
    return SSEEvent(event=event, data=json.dumps(data))


ToolExecutor = Callable[[str, dict, RequestContext], Awaitable[Any]]


def _inspect_tool_result(result: Any) -> tuple[list[SSEEvent], bool]:
    """Inspect a tool result for artifact or clarification side-effects.

    Returns (sse_side_effects, should_pause).
    - Artifacts: detected by 'artifact_type' key in result dict.
      Emits SSE artifact event matching the exact shape iOS expects.
    - Clarifications: detected by 'requires_confirmation' key.
      Emits SSE clarification event with id, question, options.
    """
    side_effects = []
    should_pause = False

    if not isinstance(result, dict):
        return side_effects, should_pause

    # Artifact detection (mirrors stream-agent-normalized.js artifact handling)
    if result.get("artifact_type"):
        artifact_id = result.get("artifact_id") or str(uuid.uuid4())
        side_effects.append(sse_event("artifact", {
            "artifact_type": result["artifact_type"],
            "artifact_id": artifact_id,
            "artifact_content": result.get("content", {}),
            "actions": result.get("actions", []),
            "status": result.get("status", "proposed"),
        }))

    # Safety gate / clarification detection
    if result.get("requires_confirmation"):
        side_effects.append(sse_event("clarification", {
            "id": result.get("confirmation_id", str(uuid.uuid4())),
            "question": result.get("question", ""),
            "options": result.get("options", []),
        }))
        should_pause = True

    return side_effects, should_pause


async def run_agent_loop(
    *,
    llm_client: LLMClient,
    model: str,
    instruction: str,
    history: list[dict],
    message: str,
    tools: list[ToolDef],
    tool_executor: ToolExecutor,
    ctx: RequestContext,
    fs: Any = None,  # FirestoreClient, optional for artifact persistence
    config: ModelConfig | None = None,
    max_tool_turns: int = MAX_TOOL_TURNS,
) -> AsyncIterator[SSEEvent]:
    """Run the agent loop: LLM -> tool calls -> LLM -> ... -> text response.

    Emits all 9 SSE event types. Artifact and clarification events are
    detected from tool return values via _inspect_tool_result().
    """

    messages = _build_messages(instruction, history, message)
    turn = 0

    try:
        while turn < max_tool_turns:
            tool_calls = []
            last_usage = None

            # Start heartbeat during LLM streaming
            heartbeat_stop = asyncio.Event()
            heartbeat_task = asyncio.create_task(
                _heartbeat_loop(heartbeat_stop)
            )

            async for chunk in llm_client.stream(model, messages, tools, config):
                if chunk.usage:
                    last_usage = chunk.usage
                if chunk.is_text:
                    yield sse_event("message", chunk.text)
                elif chunk.is_tool_call:
                    tool_calls.append(chunk.tool_call)

            # Stop heartbeat
            heartbeat_stop.set()
            heartbeat_events = await heartbeat_task
            for hb in heartbeat_events:
                yield hb

            # Track token usage per LLM turn (mirrors old after_model_callback)
            if last_usage:
                log_tokens(model, last_usage["input_tokens"], last_usage["output_tokens"])
                track_usage(
                    user_id=ctx.user_id,
                    model=model,
                    prompt_tokens=last_usage["input_tokens"],
                    completion_tokens=last_usage["output_tokens"],
                    total_tokens=last_usage["input_tokens"] + last_usage["output_tokens"],
                    feature="agent_loop",
                )

            # No tool calls — model is done
            if not tool_calls:
                yield sse_event("done", {})
                return

            # Execute all tool calls from this turn
            for tc in tool_calls:
                # Emit status event for user-facing progress
                status_msg = TOOL_STATUS_MAP.get(tc.tool_name)
                if status_msg:
                    yield sse_event("status", {"text": status_msg})

                yield sse_event("tool_start", {"tool": tc.tool_name, "call_id": tc.call_id})
                start = time.monotonic()
                try:
                    result = await tool_executor(tc.tool_name, tc.args, ctx)
                except Exception as e:
                    logger.warning("Tool %s failed: %s", tc.tool_name, e)
                    result = {"error": str(e)}
                elapsed_ms = int((time.monotonic() - start) * 1000)
                yield sse_event("tool_end", {"tool": tc.tool_name, "call_id": tc.call_id, "elapsed_ms": elapsed_ms})

                # Inspect tool result for artifact/clarification side-effects
                side_effects, should_pause = _inspect_tool_result(result)
                for evt in side_effects:
                    yield evt

                # Persist artifact to Firestore if detected
                if fs and isinstance(result, dict) and result.get("artifact_type"):
                    artifact_id = result.get("artifact_id") or side_effects[0].data  # from sse_event
                    try:
                        await fs.save_artifact(
                            ctx.user_id, ctx.conversation_id,
                            json.loads(side_effects[0].data)["artifact_id"],
                            result,
                        )
                    except Exception:
                        logger.warning("Failed to persist artifact", exc_info=True)

                # Append tool result to messages for next LLM turn
                messages.append({
                    "role": "tool",
                    "tool_name": tc.tool_name,
                    "tool_call_id": tc.call_id,
                    "tool_result": result,
                })

            turn += 1

        # Exceeded max turns
        yield sse_event("message", "I've reached my reasoning limit for this request. "
                                   "Please try rephrasing or breaking your question into parts.")
        yield sse_event("done", {})

    except Exception as e:
        logger.exception("Agent loop error")
        yield sse_event("error", {"code": "AGENT_ERROR", "message": str(e)})


async def _heartbeat_loop(stop: asyncio.Event) -> list[SSEEvent]:
    """Emit heartbeat events every HEARTBEAT_INTERVAL_S until stopped.

    Returns collected heartbeat events (yielded by caller after LLM stream ends).
    In production, these should be yielded during streaming via an async queue;
    this simplified version collects them for the caller to yield.
    """
    events = []
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), timeout=HEARTBEAT_INTERVAL_S)
            break  # stop was set
        except asyncio.TimeoutError:
            events.append(sse_event("heartbeat", {}))
    return events


def _build_messages(instruction: str, history: list[dict], message: str) -> list[dict]:
    """Build the message list for the LLM."""
    messages = []
    if instruction:
        messages.append({"role": "system", "content": instruction})
    messages.extend(history)
    messages.append({"role": "user", "content": message})
    return messages
```

- [ ] **Step 4: Run test — expect PASS**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_agent_loop.py -v
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/agent_loop.py adk_agent/agent_service/tests/test_agent_loop.py
git commit -m "feat(agent): implement core agent loop with tool execution"
```

---

### Task 14: Firestore Client (AsyncClient)

**Files:**
- Create: `adk_agent/agent_service/app/firestore_client.py`
- Test: `adk_agent/agent_service/tests/test_firestore_client.py`

- [ ] **Step 1: Write the failing test**

Tests verify interface and query building — not live Firestore calls. Use mocking.

```python
# tests/test_firestore_client.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from app.firestore_client import FirestoreClient


def test_firestore_client_init():
    """Verify FirestoreClient creates an AsyncClient."""
    with patch("app.firestore_client.AsyncClient") as mock_async:
        client = FirestoreClient()
        mock_async.assert_called_once()


@pytest.mark.asyncio
async def test_get_routine_returns_dict():
    """get_routine returns dict with id field."""
    client = FirestoreClient.__new__(FirestoreClient)
    mock_doc = AsyncMock()
    mock_doc.exists = True
    mock_doc.id = "r1"
    mock_doc.to_dict.return_value = {"name": "PPL", "template_ids": ["t1"]}

    client.db = MagicMock()
    client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

    result = await client.get_routine("user1", "r1")
    assert result["id"] == "r1"
    assert result["name"] == "PPL"
    client.db.document.assert_called_with("users/user1/routines/r1")


@pytest.mark.asyncio
async def test_get_routine_not_found_raises():
    """get_routine raises when doc doesn't exist."""
    client = FirestoreClient.__new__(FirestoreClient)
    mock_doc = AsyncMock()
    mock_doc.exists = False

    client.db = MagicMock()
    client.db.document.return_value.get = AsyncMock(return_value=mock_doc)

    with pytest.raises(ValueError, match="not found"):
        await client.get_routine("user1", "nonexistent")
```

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_firestore_client.py -v
```

- [ ] **Step 3: Write implementation**

```python
# app/firestore_client.py
"""Async Firestore client for the agent service.

Uses AsyncClient to avoid blocking the async agent loop.
Mirrors the query patterns from the Node.js shared modules —
the Firestore schema is the shared contract.
"""

from __future__ import annotations

import logging
import os
from typing import Any

from google.cloud.firestore import AsyncClient

logger = logging.getLogger(__name__)


_instance: 'FirestoreClient | None' = None


def get_firestore_client() -> 'FirestoreClient':
    """Module-level singleton — reuses gRPC channel across requests."""
    global _instance
    if _instance is None:
        _instance = FirestoreClient()
    return _instance


class FirestoreClient:
    # Uses 'canvases' until Phase 7 coordinated rename to 'conversations'.
    # This prevents a data visibility gap — iOS reads from 'canvases' until Phase 7.
    CONVERSATION_COLLECTION = os.getenv("CONVERSATION_COLLECTION", "canvases")

    def __init__(self):
        self.db = AsyncClient()

    # --- Routines ---

    async def get_routine(self, user_id: str, routine_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}/routines/{routine_id}").get()
        if not doc.exists:
            raise ValueError(f"Routine {routine_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    async def list_routines(self, user_id: str) -> list[dict]:
        docs = self.db.collection(f"users/{user_id}/routines").stream()
        return [{"id": doc.id, **doc.to_dict()} async for doc in docs]

    # --- Templates ---

    async def get_template(self, user_id: str, template_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}/templates/{template_id}").get()
        if not doc.exists:
            raise ValueError(f"Template {template_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    async def list_templates(self, user_id: str) -> list[dict]:
        docs = self.db.collection(f"users/{user_id}/templates").stream()
        return [{"id": doc.id, **doc.to_dict()} async for doc in docs]

    # --- User ---

    async def get_user(self, user_id: str) -> dict:
        doc = await self.db.document(f"users/{user_id}").get()
        if not doc.exists:
            raise ValueError(f"User {user_id} not found")
        return {"id": doc.id, **doc.to_dict()}

    # --- Workouts ---

    async def list_recent_workouts(self, user_id: str, limit: int = 5) -> list[dict]:
        query = (
            self.db.collection(f"users/{user_id}/workouts")
            .order_by("end_time", direction="DESCENDING")
            .limit(limit)
        )
        docs = query.stream()
        return [{"id": doc.id, **doc.to_dict()} async for doc in docs]

    # --- User Attributes ---

    async def get_user_attributes(self, user_id: str) -> dict:
        """Read user_attributes/{uid} subcollection doc (fitness_level, fitness_goal, etc.)."""
        doc = await self.db.document(f"users/{user_id}/user_attributes/{user_id}").get()
        return doc.to_dict() if doc.exists else {}

    # --- Training Data ---

    async def get_analysis_summary(self, user_id: str) -> dict | None:
        """Get most recent analysis insight."""
        query = (
            self.db.collection(f"users/{user_id}/analysis_insights")
            .order_by("created_at", direction="DESCENDING")
            .limit(1)
        )
        docs = [doc async for doc in query.stream()]
        if not docs:
            return None
        return {"id": docs[0].id, **docs[0].to_dict()}

    async def get_weekly_review(self, user_id: str) -> dict | None:
        """Get most recent weekly review."""
        query = (
            self.db.collection(f"users/{user_id}/weekly_reviews")
            .order_by("created_at", direction="DESCENDING")
            .limit(1)
        )
        docs = [doc async for doc in query.stream()]
        if not docs:
            return None
        return {"id": docs[0].id, **docs[0].to_dict()}

    async def get_weekly_stats(self, user_id: str, week_start: str | None = None) -> dict | None:
        """Get weekly stats. week_start is YYYY-MM-DD (Monday). Defaults to current week."""
        if not week_start:
            from datetime import date, timedelta
            today = date.today()
            monday = today - timedelta(days=today.weekday())
            week_start = monday.isoformat()
        doc = await self.db.document(f"users/{user_id}/weekly_stats/{week_start}").get()
        if not doc.exists:
            return None
        return doc.to_dict()

    # --- Planning Context (360 view assembly) ---

    async def get_planning_context(self, user_id: str) -> dict:
        """Assemble the full planning context for the agent.

        Mirrors get-planning-context.js: reads user doc, user_attributes,
        active routine + templates, recent workouts, analysis.
        """
        import asyncio

        user_task = self.get_user(user_id)
        attrs_task = self.get_user_attributes(user_id)
        routines_task = self.list_routines(user_id)
        templates_task = self.list_templates(user_id)
        workouts_task = self.list_recent_workouts(user_id, limit=5)
        analysis_task = self.get_analysis_summary(user_id)
        weekly_task = self.get_weekly_stats(user_id)

        user, attrs, routines, templates, workouts, analysis, weekly = await asyncio.gather(
            user_task, attrs_task, routines_task, templates_task,
            workouts_task, analysis_task, weekly_task,
        )

        # Determine active routine
        active_routine_id = user.get("activeRoutineId")
        active_routine = next((r for r in routines if r["id"] == active_routine_id), None)

        # Weight unit from user_attributes (mirrors get-planning-context.js)
        weight_format = attrs.get("weight_format", "kilograms")
        weight_unit = "lbs" if weight_format == "pounds" else "kg"

        return {
            "user": {
                "name": user.get("name"),
                "attributes": attrs,
                "weight_unit": weight_unit,
            },
            "active_routine": active_routine,
            "templates": templates,
            "recent_workouts": workouts,
            "analysis": analysis,
            "weekly_stats": weekly,
        }

    # --- Training Analytics v2 ---

    async def get_muscle_group_summary(self, user_id: str, muscle_group: str, weeks: int = 8) -> dict:
        """Weekly series for a muscle group (from analytics_series_muscle_group)."""
        doc = await self.db.document(
            f"users/{user_id}/analytics_series_muscle_group/{muscle_group}"
        ).get()
        if not doc.exists:
            return {"muscle_group": muscle_group, "weeks": []}
        return {"id": doc.id, **doc.to_dict()}

    async def get_muscle_summary(self, user_id: str, muscle: str, weeks: int = 8) -> dict:
        """Weekly series for a specific muscle (from analytics_series_muscle)."""
        doc = await self.db.document(
            f"users/{user_id}/analytics_series_muscle/{muscle}"
        ).get()
        if not doc.exists:
            return {"muscle": muscle, "weeks": []}
        return {"id": doc.id, **doc.to_dict()}

    async def get_exercise_summary(self, user_id: str, exercise_id: str) -> dict:
        """Per-exercise series with e1RM and volume trends.
        Keyed by exercise_id (not name) in analytics_series_exercise collection.
        """
        doc = await self.db.document(
            f"users/{user_id}/analytics_series_exercise/{exercise_id}"
        ).get()
        if not doc.exists:
            return {"exercise_id": exercise_id, "points_by_day": {}}
        return {"id": doc.id, **doc.to_dict()}

    async def query_sets(self, user_id: str, exercise_id: str, filters: dict | None = None) -> list[dict]:
        """Raw set-level drilldown from set_facts collection.
        Queries by exercise_id (matching existing composite index).
        """
        query = self.db.collection(f"users/{user_id}/set_facts")
        if exercise_id:
            query = query.where("exercise_id", "==", exercise_id)
        if filters:
            if filters.get("date_from"):
                query = query.where("workout_date", ">=", filters["date_from"])
            if filters.get("date_to"):
                query = query.where("workout_date", "<=", filters["date_to"])
        query = query.order_by("workout_date", direction="DESCENDING").limit(filters.get("limit", 50) if filters else 50)
        return [{"id": doc.id, **doc.to_dict()} async for doc in query.stream()]

    async def get_active_snapshot_lite(self, user_id: str) -> dict:
        """Lightweight context: active routine, this week summary."""
        import asyncio
        user_doc, weekly = await asyncio.gather(
            self.db.document(f"users/{user_id}").get(),
            self.get_weekly_stats(user_id),
        )
        user = user_doc.to_dict() if user_doc.exists else {}
        return {
            "active_routine_id": user.get("activeRoutineId"),
            "weekly_stats": weekly,
        }

    async def get_active_events(self, user_id: str, limit: int = 10) -> list[dict]:
        """Recent training events (PR, workout completed, etc.) from agent_recommendations."""
        query = (
            self.db.collection(f"users/{user_id}/agent_recommendations")
            .order_by("created_at", direction="DESCENDING")
            .limit(limit)
        )
        return [{"id": doc.id, **doc.to_dict()} async for doc in query.stream()]

    # --- Exercises ---

    async def search_exercises(self, query: str, limit: int = 10) -> list[dict]:
        """Search exercises by name prefix.

        Uses the existing searchExercises Firebase Function via HTTP because
        Firestore's != filter requires orderBy on the inequality field first,
        making client-side name filtering unreliable. The Firebase Function
        handles this correctly with multi-field filtering.
        """
        import httpx
        url = os.getenv("MYON_FUNCTIONS_BASE_URL",
                        "https://us-central1-myon-53d85.cloudfunctions.net")
        api_key = os.getenv("MYON_API_KEY", "")
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                f"{url}/searchExercises",
                params={"query": query, "limit": str(limit)},
                headers={"x-api-key": api_key},
            )
            data = resp.json()
            return data.get("exercises", [])

    # --- Conversations ---

    async def get_conversation_messages(
        self, user_id: str, conversation_id: str, limit: int = 20
    ) -> list[dict]:
        """Load recent messages for a conversation."""
        coll = self.CONVERSATION_COLLECTION
        query = (
            self.db.collection(f"users/{user_id}/{coll}/{conversation_id}/messages")
            .order_by("created_at", direction="DESCENDING")
            .limit(limit)
        )
        docs = [doc async for doc in query.stream()]
        docs.reverse()  # Chronological order
        return [{"id": doc.id, **doc.to_dict()} for doc in docs]

    async def save_message(
        self, user_id: str, conversation_id: str, message: dict
    ) -> str:
        """Save a message to a conversation.
        Message format: {type: 'user_prompt'|'agent_response'|'artifact',
                         content: str, created_at: datetime}
        """
        coll = self.CONVERSATION_COLLECTION
        ref = await self.db.collection(
            f"users/{user_id}/{coll}/{conversation_id}/messages"
        ).add(message)
        return ref[1].id

    async def save_artifact(
        self, user_id: str, conversation_id: str, artifact_id: str, artifact: dict
    ) -> None:
        """Persist an artifact to the conversation's artifacts subcollection."""
        coll = self.CONVERSATION_COLLECTION
        from datetime import datetime, timezone
        await self.db.document(
            f"users/{user_id}/{coll}/{conversation_id}/artifacts/{artifact_id}"
        ).set({
            "type": artifact.get("artifact_type"),
            "content": artifact.get("content", {}),
            "actions": artifact.get("actions", []),
            "status": artifact.get("status", "proposed"),
            "created_at": datetime.now(timezone.utc),
        })
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd adk_agent/agent_service && python -m pytest tests/test_firestore_client.py -v
```

- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/firestore_client.py adk_agent/agent_service/tests/test_firestore_client.py
git commit -m "feat(agent): add async Firestore client with planning context assembly"
```

---

### Task 15: Observability Module

**Files:**
- Create: `adk_agent/agent_service/app/observability.py`

- [ ] **Step 1: Write implementation**

```python
# app/observability.py
"""Structured logging and tracing for the agent service."""

from __future__ import annotations

import json
import logging
import time
import uuid
from contextvars import ContextVar
from functools import wraps
from typing import Any

# Request-scoped trace ID for log correlation
_trace_id: ContextVar[str] = ContextVar("trace_id", default="")


class StructuredFormatter(logging.Formatter):
    """JSON log formatter for Cloud Logging."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "trace_id": _trace_id.get(""),
        }
        if hasattr(record, "extra_fields"):
            log_entry.update(record.extra_fields)
        return json.dumps(log_entry)


def setup_logging():
    """Configure structured JSON logging."""
    handler = logging.StreamHandler()
    handler.setFormatter(StructuredFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(logging.INFO)


def new_trace_id() -> str:
    """Generate and set a new trace ID for the current request."""
    tid = uuid.uuid4().hex[:16]
    _trace_id.set(tid)
    return tid


def get_trace_id() -> str:
    return _trace_id.get("")


def log_request(user_id: str, conversation_id: str, lane: str, model: str):
    """Log request metadata."""
    logger = logging.getLogger("agent.request")
    logger.info(
        "request_start",
        extra={"extra_fields": {
            "user_id": user_id,
            "conversation_id": conversation_id,
            "lane": lane,
            "model": model,
        }},
    )


def log_tool_call(tool_name: str, elapsed_ms: int, success: bool):
    """Log tool execution."""
    logger = logging.getLogger("agent.tool")
    logger.info(
        "tool_call",
        extra={"extra_fields": {
            "tool": tool_name,
            "elapsed_ms": elapsed_ms,
            "success": success,
        }},
    )


def log_tokens(model: str, input_tokens: int, output_tokens: int):
    """Log token usage."""
    logger = logging.getLogger("agent.tokens")
    logger.info(
        "token_usage",
        extra={"extra_fields": {
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
        }},
    )
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/app/observability.py
git commit -m "feat(agent): add structured observability module"
```

---

### Task 16: Starlette App + /stream Endpoint

**Files:**
- Create: `adk_agent/agent_service/app/main.py`

- [ ] **Step 1: Write implementation**

```python
# app/main.py
"""Agent Service — Starlette ASGI application."""

from __future__ import annotations

import json
import logging

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import StreamingResponse, JSONResponse
from starlette.routing import Route

from app.observability import setup_logging, new_trace_id

setup_logging()
logger = logging.getLogger(__name__)


async def stream_handler(request: Request) -> StreamingResponse:
    """POST /stream — main agent streaming endpoint.

    Request body: {
        "user_id": str,
        "conversation_id": str,
        "message": str,
        "correlation_id": str,
        "workout_id": str | null
    }
    Response: SSE stream
    """
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid JSON"}, status_code=400)

    user_id = body.get("user_id")
    conversation_id = body.get("conversation_id")
    message = body.get("message")
    correlation_id = body.get("correlation_id", "")
    workout_id = body.get("workout_id")

    if not all([user_id, conversation_id, message]):
        return JSONResponse(
            {"error": "user_id, conversation_id, and message are required"},
            status_code=400,
        )

    trace_id = correlation_id or new_trace_id()

    async def event_stream():
        # Import here to avoid circular imports during startup
        from app.agent_loop import run_agent_loop, sse_event
        from app.context import RequestContext
        from app.firestore_client import FirestoreClient
        from app.llm.gemini import GeminiClient
        from app.router import route_request, Lane
        from app.tools.registry import get_tools, execute_tool

        ctx = RequestContext(
            user_id=user_id,
            conversation_id=conversation_id,
            correlation_id=trace_id,
            workout_id=workout_id,
        )

        fs = get_firestore_client()

        # Load conversation history
        history = await fs.get_conversation_messages(
            user_id, conversation_id, limit=20
        )

        # Route to determine lane
        lane = route_request(message)

        # TODO: Fast Lane handling (Phase 3a skill migration)
        # TODO: Functional Lane handling (Phase 3a skill migration)

        # Slow Lane — full agent loop
        llm_client = GeminiClient()
        tools = get_tools(ctx)

        # Build instruction with planning context
        from app.instruction import build_instruction
        instruction = await build_instruction(fs, ctx)

        async for event in run_agent_loop(
            llm_client=llm_client,
            model="gemini-2.5-flash",
            instruction=instruction,
            history=_format_history(history),
            message=message,
            tools=tools,
            tool_executor=execute_tool,
            ctx=ctx,
        ):
            yield event.encode()

        # Persist user message and indicate stream ended
        await fs.save_message(user_id, conversation_id, {
            "role": "user",
            "content": message,
            "timestamp": _server_timestamp(),
        })

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Trace-Id": trace_id,
        },
    )


def _format_history(messages: list[dict]) -> list[dict]:
    """Convert Firestore message docs to LLM message format."""
    formatted = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if role in ("user", "assistant"):
            formatted.append({"role": role, "content": content})
    return formatted


def _server_timestamp():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc)


async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


app = Starlette(
    routes=[
        Route("/stream", stream_handler, methods=["POST"]),
        Route("/health", health, methods=["GET"]),
    ],
)
```

- [ ] **Step 2: Commit**

```bash
git add adk_agent/agent_service/app/main.py
git commit -m "feat(agent): add Starlette app with /stream endpoint"
```

---

## Chunk 3: Phase 3a Part 2 — Skill Migration, Router, Instruction, SSE Proxy

### Task 17: Router Migration

**Files:**
- Create: `adk_agent/agent_service/app/router.py`
- Test: `adk_agent/agent_service/tests/test_router.py`
- Reference: `adk_agent/canvas_orchestrator/app/shell/router.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_router.py
import pytest
from app.router import route_request, Lane


def test_fast_lane_log_set():
    assert route_request("log 8 reps at 100kg") == Lane.FAST


def test_fast_lane_shorthand():
    assert route_request("8@100") == Lane.FAST


def test_fast_lane_done():
    assert route_request("done") == Lane.FAST


def test_fast_lane_next_set():
    assert route_request("next set") == Lane.FAST


def test_slow_lane_general():
    assert route_request("How's my training going?") == Lane.SLOW


def test_slow_lane_routine_creation():
    assert route_request("Create me a push pull legs routine") == Lane.SLOW


def test_functional_lane_json():
    assert route_request({"intent": "SWAP_EXERCISE"}) == Lane.FUNCTIONAL


def test_functional_lane_autofill():
    assert route_request({"intent": "AUTOFILL_SET"}) == Lane.FUNCTIONAL
```

- [ ] **Step 2: Run test — expect FAIL**
- [ ] **Step 3: Migrate router from `canvas_orchestrator/app/shell/router.py`**

Read the source file. Port the regex patterns and lane classification logic. Key changes:
- Remove all ContextVar usage — return `Lane` enum only
- Remove `execute_fast_lane()` — that moves to `main.py`
- Keep the regex patterns and intent classification unchanged

```python
# app/router.py
"""4-lane message router — migrated from shell/router.py."""

from __future__ import annotations

import re
from enum import Enum
from typing import Any


class Lane(str, Enum):
    FAST = "fast"
    SLOW = "slow"
    FUNCTIONAL = "functional"
    WORKER = "worker"


# Fast Lane patterns — regex match → direct skill execution, no LLM
FAST_PATTERNS = [
    re.compile(r"^(?:log\s+)?(\d+)\s*(?:reps?\s*)?(?:@|at)\s*(\d+(?:\.\d+)?)\s*(?:kg|lbs?|pounds?)?$", re.I),
    re.compile(r"^(\d+)@(\d+(?:\.\d+)?)$"),
    re.compile(r"^done$", re.I),
    re.compile(r"^next\s*set$", re.I),
    re.compile(r"^rest$", re.I),
    re.compile(r"^log\s+set\b", re.I),
    re.compile(r"^(\d+)\s*(?:reps?)?$", re.I),
]

# Functional Lane intents
FUNCTIONAL_INTENTS = {"SWAP_EXERCISE", "AUTOFILL_SET", "SUGGEST_WEIGHT", "MONITOR_STATE"}


def route_request(payload: str | dict[str, Any]) -> Lane:
    """Route a message to the appropriate lane."""
    if isinstance(payload, dict):
        intent = payload.get("intent", "")
        if intent in FUNCTIONAL_INTENTS:
            return Lane.FUNCTIONAL
        return Lane.SLOW

    text = payload.strip()
    for pattern in FAST_PATTERNS:
        if pattern.match(text):
            return Lane.FAST

    return Lane.SLOW
```

- [ ] **Step 4: Run tests — expect PASS**
- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/router.py adk_agent/agent_service/tests/test_router.py
git commit -m "feat(agent): migrate 4-lane router"
```

---

### Task 18: Tool Registry

**Files:**
- Create: `adk_agent/agent_service/app/tools/__init__.py`
- Create: `adk_agent/agent_service/app/tools/registry.py`
- Create: `adk_agent/agent_service/app/tools/definitions.py`

- [ ] **Step 1: Write tool registry**

```python
# app/tools/registry.py
"""Tool registry — maps tool names to implementations."""

from __future__ import annotations

from typing import Any

from app.context import RequestContext
from app.llm.protocol import ToolDef

# Tool implementations are registered here after skill migration
_TOOL_REGISTRY: dict[str, Any] = {}


def register_tool(name: str, fn, description: str, parameters: dict):
    """Register a tool function."""
    _TOOL_REGISTRY[name] = {
        "fn": fn,
        "def": ToolDef(name=name, description=description, parameters=parameters),
    }


async def execute_tool(tool_name: str, args: dict, ctx: RequestContext) -> Any:
    """Execute a registered tool."""
    if tool_name not in _TOOL_REGISTRY:
        return {"error": f"Unknown tool: {tool_name}"}
    fn = _TOOL_REGISTRY[tool_name]["fn"]
    return await fn(ctx=ctx, **args)


# Tools that are banned during active workout mode (heavy-compute, disruptive)
WORKOUT_BANNED_TOOLS = {
    "get_planning_context", "search_exercises", "query_training_sets",
    "get_training_analysis", "propose_routine", "propose_routine_update",
}


def get_tools(ctx: RequestContext) -> list[ToolDef]:
    """Get tool definitions available for this context."""
    if ctx.workout_mode:
        return [
            entry["def"] for entry in _TOOL_REGISTRY.values()
            if entry["def"].name not in WORKOUT_BANNED_TOOLS
        ]
    return [entry["def"] for entry in _TOOL_REGISTRY.values()]
```

- [ ] **Step 2: Write tool definitions skeleton**

```python
# app/tools/definitions.py
"""Tool definitions — JSON schemas for each tool.

Populated during skill migration (Tasks 19-21).
"""

# Will be populated as skills are migrated
```

- [ ] **Step 3: Commit**

```bash
git add adk_agent/agent_service/app/tools/
git commit -m "feat(agent): add tool registry and executor"
```

---

### Task 19: Coach Skills Migration (Read Tools)

**Files:**
- Create: `adk_agent/agent_service/app/skills/__init__.py`
- Create: `adk_agent/agent_service/app/skills/coach_skills.py`
- Test: `adk_agent/agent_service/tests/test_skills/__init__.py`
- Test: `adk_agent/agent_service/tests/test_skills/test_coach_skills.py`
- Reference: `adk_agent/canvas_orchestrator/app/skills/coach_skills.py`

- [ ] **Step 1: Read the source file**

```bash
# Read the full source to understand every function
```
Read `adk_agent/canvas_orchestrator/app/skills/coach_skills.py` in full.

- [ ] **Step 2: Write failing tests**

```python
# tests/test_skills/test_coach_skills.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from app.context import RequestContext
from app.skills.coach_skills import get_user_profile, search_exercises, get_planning_context


@pytest.fixture
def ctx():
    return RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")


@pytest.mark.asyncio
async def test_get_user_profile_returns_user_data(ctx):
    with patch("app.skills.coach_skills.get_firestore_client") as mock_fc:
        mock_client = AsyncMock()
        mock_client.get_user.return_value = {"id": "u1", "name": "Test"}
        mock_fc.return_value = mock_client
        result = await get_user_profile(ctx=ctx)
        assert result["name"] == "Test"
        mock_client.get_user.assert_called_once_with("u1")


@pytest.mark.asyncio
async def test_search_exercises_returns_results(ctx):
    with patch("app.skills.coach_skills.get_firestore_client") as mock_fc:
        mock_client = AsyncMock()
        mock_client.search_exercises.return_value = [{"id": "e1", "name": "Bench Press"}]
        mock_fc.return_value = mock_client
        result = await search_exercises(ctx=ctx, query="bench")
        assert result["count"] == 1
        assert result["exercises"][0]["name"] == "Bench Press"


@pytest.mark.asyncio
async def test_get_planning_context_returns_full_context(ctx):
    with patch("app.skills.coach_skills.get_firestore_client") as mock_fc:
        mock_client = AsyncMock()
        mock_client.get_planning_context.return_value = {
            "user": {"name": "Test"},
            "active_routine": None,
            "templates": [],
            "recent_workouts": [],
            "analysis": None,
            "weekly_stats": None,
        }
        mock_fc.return_value = mock_client
        result = await get_planning_context(ctx=ctx)
        assert "user" in result
```

Test each coach skill function. Mock the `FirestoreClient` via `get_firestore_client`.

- [ ] **Step 3: Write implementation**

Key changes from the original:
- Replace `CanvasFunctionsClient` HTTP calls with `FirestoreClient` async calls
- Replace `ContextVar` for `user_id` with explicit `ctx: RequestContext` parameter
- Replace `SkillResult` returns with plain dicts (tool registry handles the wrapping)
- Remove `_client_instance` singleton pattern — `FirestoreClient` is passed in

```python
# app/skills/coach_skills.py
"""Read tools — training data queries via direct Firestore access.

Migrated from canvas_orchestrator/app/skills/coach_skills.py.
Replaces HTTP calls with FirestoreClient.
"""

from __future__ import annotations

from app.context import RequestContext
from app.firestore_client import get_firestore_client


async def get_user_profile(*, ctx: RequestContext) -> dict:
    fs = get_firestore_client()
    return await fs.get_user(ctx.user_id)


async def search_exercises(*, ctx: RequestContext, query: str, limit: int = 10) -> dict:
    fs = get_firestore_client()
    results = await fs.search_exercises(query, limit)
    return {"exercises": results, "count": len(results)}


async def get_planning_context(*, ctx: RequestContext) -> dict:
    fs = get_firestore_client()
    return await fs.get_planning_context(ctx.user_id)


async def get_training_analysis(*, ctx: RequestContext, sections: list[str] | None = None) -> dict:
    fs = get_firestore_client()
    analysis = await fs.get_analysis_summary(ctx.user_id)
    weekly = await fs.get_weekly_review(ctx.user_id)
    return {"analysis": analysis, "weekly_review": weekly}


async def get_muscle_group_progress(*, ctx: RequestContext, group: str, weeks: int = 8) -> dict:
    fs = get_firestore_client()
    query = (
        fs.db.collection(f"users/{ctx.user_id}/analytics_series_muscle_group")
        .where("muscle_group", "==", group)
        .order_by("week_start", direction="DESCENDING")
        .limit(weeks)
    )
    docs = [doc async for doc in query.stream()]
    return {"series": [{"id": d.id, **d.to_dict()} for d in reversed(docs)]}


async def get_exercise_progress(*, ctx: RequestContext, exercise: str, weeks: int = 8) -> dict:
    fs = get_firestore_client()
    query = (
        fs.db.collection(f"users/{ctx.user_id}/analytics_series_exercise")
        .where("exercise_id", "==", exercise)
        .order_by("date", direction="DESCENDING")
        .limit(weeks * 7)
    )
    docs = [doc async for doc in query.stream()]
    return {"series": [{"id": d.id, **d.to_dict()} for d in reversed(docs)]}
```

- [ ] **Step 4: Register tools**

In `tools/definitions.py`, register each coach skill with its JSON schema:

```python
from app.tools.registry import register_tool
from app.skills import coach_skills

register_tool(
    "get_planning_context",
    coach_skills.get_planning_context,
    "Get the full planning context for the current user",
    {"type": "object", "properties": {}, "required": []},
)

register_tool(
    "search_exercises",
    coach_skills.search_exercises,
    "Search the exercise catalog by name",
    {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Search query"},
            "limit": {"type": "integer", "description": "Max results", "default": 10},
        },
        "required": ["query"],
    },
)
# ... register all coach skills
```

- [ ] **Step 5: Run tests — expect PASS**
- [ ] **Step 6: Commit**

```bash
git add adk_agent/agent_service/app/skills/ adk_agent/agent_service/app/tools/definitions.py adk_agent/agent_service/tests/test_skills/
git commit -m "feat(agent): migrate coach skills with direct Firestore access"
```

---

### Task 20: Planner Skills Migration (Write Tools)

**Files:**
- Create: `adk_agent/agent_service/app/skills/planner_skills.py`
- Test: `adk_agent/agent_service/tests/test_skills/test_planner_skills.py`
- Reference: `adk_agent/canvas_orchestrator/app/skills/planner_skills.py`

- [ ] **Step 1: Read the source file**

Read `adk_agent/canvas_orchestrator/app/skills/planner_skills.py` in full.

- [ ] **Step 2: Write failing tests**
- [ ] **Step 3: Write implementation**

Key changes:
- Artifacts are written directly to Firestore `conversations/{id}/artifacts` + yielded as SSE events
- No more proxy-side artifact detection — the agent controls artifact persistence
- Replace `CanvasFunctionsClient` with `FirestoreClient` for routine/template creation
- `propose_workout`, `propose_routine`, `propose_routine_update`, `propose_template_update`

- [ ] **Step 4: Register tools in definitions.py**
- [ ] **Step 5: Run tests — expect PASS**
- [ ] **Step 6: Commit**

```bash
git add adk_agent/agent_service/app/skills/planner_skills.py adk_agent/agent_service/tests/test_skills/test_planner_skills.py
git commit -m "feat(agent): migrate planner skills with direct artifact writes"
```

---

### Task 21: Copilot + Workout + Progression Skills Migration (HTTP-Retained)

**Files:**
- Create: `adk_agent/agent_service/app/skills/copilot_skills.py`
- Create: `adk_agent/agent_service/app/skills/workout_skills.py`
- Create: `adk_agent/agent_service/app/skills/progression_skills.py`
- Reference: `adk_agent/canvas_orchestrator/app/skills/copilot_skills.py`
- Reference: `adk_agent/canvas_orchestrator/app/skills/workout_skills.py`
- Reference: `adk_agent/canvas_orchestrator/app/skills/progression_skills.py`

- [ ] **Step 1: Read both source files**
- [ ] **Step 2: Write implementation**

These skills **retain HTTP calls** to Firebase Functions — active workout mutations and progression writes are too critical to reimplement in Python. Key changes:
- Replace `ContextVar` for user_id with `ctx: RequestContext`
- Replace `_client_instance` singleton with injected HTTP client
- Use `httpx.AsyncClient` instead of `requests`
- Keep the same Firebase Function endpoints and API key auth
- `copilot_skills.py`: Fast Lane workout ops. Uses `FIREBASE_API_KEY`. Calls `completeCurrentSet` (auto-cursor log) and `logSet` (explicit log). Also `getActiveWorkout` for get_next_set.
- `workout_skills.py`: LLM-directed workout ops. Uses `FIREBASE_API_KEY` via `httpx`. Calls `logSet`, `swapExercise`, `addExercise`, `patchActiveWorkout`, `completeActiveWorkout`.
- `progression_skills.py`: Background progression writes. Uses `MYON_API_KEY`. Calls `applyProgression` Firebase Function. Two modes: `auto_apply=True` (immediate) or `False` (pending_review). Also provides `suggest_weight_increase()` and `suggest_deload()` convenience wrappers.

```python
# app/skills/copilot_skills.py
"""Fast Lane skills — active workout operations via HTTP.

These call Firebase Functions via HTTP because the active workout
state machine (Zod validation, idempotency, concurrent-set protection)
is too critical to reimplement in Python.
"""

from __future__ import annotations

import os
import httpx

from app.context import RequestContext

FUNCTIONS_URL = os.getenv("MYON_FUNCTIONS_BASE_URL", "https://us-central1-myon-53d85.cloudfunctions.net")
API_KEY = os.getenv("FIREBASE_API_KEY", "")


async def log_set(*, ctx: RequestContext, exercise_instance_id: str,
                  set_id: str, reps: int, weight_kg: float, rir: int = 0) -> dict:
    """Log a set to the active workout via Firebase Function.

    Request body must include nested `values` object and `idempotency_key`
    to match the logSet endpoint's expected shape.
    """
    import uuid
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/logSet",
            json={
                "workout_id": ctx.workout_id,
                "exercise_instance_id": exercise_instance_id,
                "set_id": set_id,
                "values": {
                    "weight": weight_kg,
                    "reps": reps,
                    "rir": rir,
                },
                "idempotency_key": str(uuid.uuid4()),
            },
            headers={
                "x-api-key": API_KEY,
                "x-user-id": ctx.user_id,
            },
        )
        return resp.json()

# ... log_set_shorthand, get_next_set, swap_exercise, add_exercise, etc.
```

- [ ] **Step 3: Write progression_skills.py**

```python
# app/skills/progression_skills.py
"""Progression skills — apply weight/volume changes via Firebase Function.

Uses MYON_API_KEY to call applyProgression endpoint. Supports both
user-requested changes (via chat agent) and automated progressions
(via training analyst worker).
"""

from __future__ import annotations

import os
import httpx

from app.context import RequestContext

FUNCTIONS_URL = os.getenv("MYON_FUNCTIONS_BASE_URL", "https://us-central1-myon-53d85.cloudfunctions.net")
MYON_API_KEY = os.getenv("MYON_API_KEY", "")


async def apply_progression(
    *, ctx: RequestContext,
    target_type: str,  # "template" or "routine"
    target_id: str,
    changes: list[dict],
    summary: str,
    rationale: str,
    trigger: str = "user_request",
    auto_apply: bool = True,
) -> dict:
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/applyProgression",
            json={
                "userId": ctx.user_id,
                "targetType": target_type,
                "targetId": target_id,
                "changes": changes,
                "summary": summary,
                "rationale": rationale,
                "trigger": trigger,
                "autoApply": auto_apply,
            },
            headers={"x-api-key": MYON_API_KEY},
        )
        return resp.json()


async def suggest_weight_increase(
    *, ctx: RequestContext, template_id: str, exercise_index: int,
    new_weight: float, rationale: str,
) -> dict:
    return await apply_progression(
        ctx=ctx,
        target_type="template",
        target_id=template_id,
        changes=[{"path": f"exercises[{exercise_index}].sets[0].weight",
                  "from": None, "to": new_weight, "rationale": rationale}],
        summary=f"Increase weight to {new_weight}kg",
        rationale=rationale,
        trigger="user_request",
    )
```

- [ ] **Step 4: Register tools in definitions.py**
- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/skills/copilot_skills.py adk_agent/agent_service/app/skills/workout_skills.py adk_agent/agent_service/app/skills/progression_skills.py
git commit -m "feat(agent): migrate copilot/workout/progression skills (HTTP retained)"
```

---

### Task 22: Safety Gate, Planner, Critic Migration

**Files:**
- Create: `adk_agent/agent_service/app/safety_gate.py`
- Create: `adk_agent/agent_service/app/planner.py`
- Create: `adk_agent/agent_service/app/critic.py`
- Create: `adk_agent/agent_service/app/functional_handler.py`
- Reference: `adk_agent/canvas_orchestrator/app/shell/safety_gate.py`
- Reference: `adk_agent/canvas_orchestrator/app/shell/planner.py`
- Reference: `adk_agent/canvas_orchestrator/app/shell/critic.py`
- Reference: `adk_agent/canvas_orchestrator/app/shell/functional_handler.py`

- [ ] **Step 1: Read all four source files**
- [ ] **Step 2: Migrate safety_gate.py**

Key changes: replace ContextVar message access with function parameter. Keep confirmation keyword patterns unchanged.

- [ ] **Step 3: Migrate planner.py**

Key changes: replace ContextVar context access with function parameter. Keep intent templates and tool plan generation unchanged.

- [ ] **Step 4: Migrate critic.py**

Key changes: replace ContextVar with function parameter. Keep safety/hallucination pattern matching unchanged.

- [ ] **Step 5: Migrate functional_handler.py**

Key changes: use the LLM client abstraction instead of direct google-genai. Keep intent handling unchanged.

- [ ] **Step 6: Commit**

```bash
git add adk_agent/agent_service/app/safety_gate.py adk_agent/agent_service/app/planner.py adk_agent/agent_service/app/critic.py adk_agent/agent_service/app/functional_handler.py
git commit -m "feat(agent): migrate safety gate, planner, critic, functional handler"
```

---

### Task 23: Instruction Migration

**Files:**
- Create: `adk_agent/agent_service/app/instruction.py`
- Reference: `adk_agent/canvas_orchestrator/app/shell/instruction.py`

- [ ] **Step 1: Read the full instruction (698 lines)**
- [ ] **Step 2: Migrate instruction.py**

Read `adk_agent/canvas_orchestrator/app/shell/instruction.py` (698 lines) in full. Copy the entire `CORE_INSTRUCTION` string, then apply these modifications:

1. **Remove Gemini-specific formatting** — delete any references to Gemini's extended thinking format, thinking tokens, or model-specific behavior
2. **Remove session-awareness** — delete references to `session_id`, `agent_version`, session state, version-forced resets
3. **Remove ContextVar references** — delete any mention of ContextVar, thread boundaries, or ADK-specific patterns
4. **Add memory usage guidance** — append the `MEMORY_GUIDANCE` section (defined above)
5. **Keep unchanged:** core coaching persona, response craft (Verdict/Evidence/Action), weight prescription rules, workout mode rules, safety patterns, tool usage tiers, evidence-based training principles

After migration, verify the instruction string doesn't reference any ADK/Vertex AI concepts by searching for: "session", "agent_version", "ContextVar", "ADK", "Vertex", "gemini" (case-insensitive). Any matches should be removed or made model-agnostic.

```python
# app/instruction.py
"""Agent instruction — coaching persona and behavior rules.

Migrated from canvas_orchestrator/app/shell/instruction.py (698 lines).
Model-agnostic — no Gemini-specific formatting.
"""

from __future__ import annotations

from app.context import RequestContext
from app.firestore_client import FirestoreClient


CORE_INSTRUCTION = ""  # Populated in Step 2 below — full migration of 698-line instruction

MEMORY_GUIDANCE = """
## Memory Usage
When you learn something new about the user that would be valuable in future
conversations — a goal, a constraint, an injury, a preference, a life context —
save it with the save_memory tool.

Save durable facts: "user prefers 4-day upper/lower splits"
Don't save transient details: "user wants to train chest today"

When you discover a previous memory is outdated or incorrect, retire it with
retire_memory and optionally save the corrected version.
"""


async def build_instruction(fs: FirestoreClient, ctx: RequestContext) -> str:
    """Build the full system instruction with auto-loaded context."""
    parts = [CORE_INSTRUCTION, MEMORY_GUIDANCE]

    # Auto-loaded context will be added in Phase 3b (memory system)
    # For now, load planning context
    try:
        planning = await fs.get_planning_context(ctx.user_id)
        parts.append(_format_training_snapshot(planning))
    except Exception:
        pass  # First-time user may have no data

    return "\n\n".join(parts)


def _format_training_snapshot(planning: dict) -> str:
    """Format planning context as a system message section."""
    sections = ["## Current Training Snapshot"]
    user = planning.get("user", {})
    if user.get("name"):
        sections.append(f"User: {user['name']}")
    active = planning.get("active_routine")
    if active:
        sections.append(f"Active routine: {active.get('name', 'Unknown')}")
    return "\n".join(sections)
```

- [ ] **Step 3: Commit**

```bash
git add adk_agent/agent_service/app/instruction.py
git commit -m "feat(agent): migrate instruction with model-agnostic formatting"
```

---

### Task 24: Wire main.py with Full Lane Support

**Files:**
- Modify: `adk_agent/agent_service/app/main.py`

- [ ] **Step 1: Update stream_handler**

Wire the router, Fast Lane (copilot_skills), Functional Lane (functional_handler), and Slow Lane (agent loop with planner + critic):

- Fast Lane: parse shorthand, execute copilot skill, return SSE result
- Functional Lane: execute functional_handler with LLM client
- Slow Lane: run planner → agent loop → critic

Read the `agent_engine_app.py` `stream_query` method to ensure all pipeline stages are preserved.

- [ ] **Step 2: Import and wire tool definitions**

Ensure `tools/definitions.py` registers all tools on module import.

- [ ] **Step 3: Run full test suite**

```bash
cd adk_agent/agent_service && python -m pytest tests/ -v
```

- [ ] **Step 4: Commit**

```bash
git add adk_agent/agent_service/app/main.py adk_agent/agent_service/app/tools/definitions.py
git commit -m "feat(agent): wire full lane support in /stream endpoint"
```

---

### Task 25: SSE Proxy Update

**Files:**
- Modify: `firebase_functions/functions/strengthos/stream-agent-normalized.js`

- [ ] **Step 1: Read the full SSE proxy file**

Read `firebase_functions/functions/strengthos/stream-agent-normalized.js` (~1528 lines).

- [ ] **Step 2: Add conversation initialization logic**

The SSE proxy now handles conversation lifecycle (replaces `openCanvas`, `bootstrapCanvas`, `initializeSession`):

```javascript
const INACTIVITY_TIMEOUT_MS = 4 * 60 * 60 * 1000; // 4 hours

// IMPORTANT: Uses 'canvases' collection until Phase 7 coordinated rename.
// This prevents a data visibility gap — iOS reads from 'canvases' until Phase 7
// switches everything atomically to 'conversations'.
const CONVERSATION_COLLECTION = 'canvases';

async function resolveConversationId(userId, requestConversationId) {
  if (requestConversationId) {
    const convDoc = await db.doc(`users/${userId}/${CONVERSATION_COLLECTION}/${requestConversationId}`).get();
    if (convDoc.exists) {
      const lastMessageAt = convDoc.data().last_message_at?.toMillis() || 0;
      const hasActiveWorkout = convDoc.data().active_workout_id != null;
      if (!hasActiveWorkout && Date.now() - lastMessageAt > INACTIVITY_TIMEOUT_MS) {
        return createNewConversation(userId);
      }
      return requestConversationId;
    }
  }
  return createNewConversation(userId);
}

async function createNewConversation(userId) {
  const ref = await db.collection(`users/${userId}/${CONVERSATION_COLLECTION}`).add({
    created_at: admin.firestore.FieldValue.serverTimestamp(),
    last_message_at: admin.firestore.FieldValue.serverTimestamp(),
  });
  return ref.id;
}
```

- [ ] **Step 3: Add AGENT_SERVICE_URL guard and uuid dependency**

```javascript
const { GoogleAuth } = require('google-auth-library');
const { v4: uuidv4 } = require('uuid');

const AGENT_SERVICE_URL = process.env.AGENT_SERVICE_URL;
if (!AGENT_SERVICE_URL) throw new Error('AGENT_SERVICE_URL not configured');

const auth = new GoogleAuth();
```

Also add `"uuid": "^9.0.0"` to `firebase_functions/functions/package.json` dependencies.

- [ ] **Step 4: Replace Vertex AI call with Cloud Run call + error handling**

```javascript
async function callAgentService(userId, conversationId, message, correlationId, workoutId) {
  const client = await auth.getIdTokenClient(AGENT_SERVICE_URL);
  const response = await client.request({
    url: `${AGENT_SERVICE_URL}/stream`,
    method: 'POST',
    data: {
      user_id: userId,
      conversation_id: conversationId,
      message,
      correlation_id: correlationId || uuidv4(),
      workout_id: workoutId || null,
    },
    responseType: 'stream',
  });
  return response.data;
}
```

Wrap the call site in try/catch to handle Cloud Run errors gracefully:

```javascript
try {
  const stream = await callAgentService(userId, conversationId, message, correlationId, workoutId);
  // relay events with translation (see Step 6)
} catch (err) {
  logger.error('Agent service error', { error: err.message, userId });
  sse.write(`event: error\ndata: ${JSON.stringify({
    error: { code: 'UPSTREAM_ERROR', message: err.message }
  })}\n\n`);
  done(false);
  return;
}
```

- [ ] **Step 5: Remove all session logic**

Delete:
- `initializeOrReuseSession()` function and all calls
- Session creation/reuse/versioning code
- Session pre-warming hooks
- Any `agent_sessions` Firestore references

Keep:
- Auth (bearer token validation)
- Premium gate (`isPremiumUser`)
- Rate limiting
- Workspace_entries write logic (persist each relayed event to `workspace_entries` subcollection for iOS timeline replay)
- Artifact detection in relayed events (write to `artifacts` subcollection) — **Note:** per AD-2, the agent service also persists artifacts to Firestore. The proxy's workspace_entries writes cover ALL events including artifacts for timeline replay, while the agent service handles the canonical artifact document.

- [ ] **Step 6: Add EVENT_COMPAT translation table for Phase 3a→7 backward compatibility**

The Cloud Run agent emits new event names (`tool_start`, `tool_end`, `clarification`) but iOS expects old names until Phase 7. Add a translation table:

```javascript
// Backward compatibility — removed in Phase 7 when iOS is updated
const EVENT_COMPAT = {
  'tool_start': 'toolRunning',
  'tool_end': 'toolComplete',
  'clarification': 'clarification.request',
};

function relayEvent(rawEvent) {
  const parsed = JSON.parse(rawEvent);
  const translatedType = EVENT_COMPAT[parsed.type] || parsed.type;

  // Write workspace_entry for timeline replay (existing behavior, kept)
  writeWorkspaceEntry(userId, conversationId, {
    ...parsed,
    type: translatedType,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Relay to client with translated event name
  sse.write(`event: ${translatedType}\ndata: ${JSON.stringify(parsed.data || parsed)}\n\n`);
}
```

- [ ] **Step 7: Run Firebase Functions tests**

```bash
cd firebase_functions/functions && npm test
```

- [ ] **Step 8: Commit**

```bash
git add firebase_functions/functions/strengthos/stream-agent-normalized.js firebase_functions/functions/package.json
git commit -m "feat(proxy): update SSE proxy — Cloud Run call, event translation, workspace_entries kept"
```

---

### Task 26: Deploy + End-to-End Verification

- [ ] **Step 1: Deploy agent service to Cloud Run**

```bash
cd adk_agent/agent_service && make deploy
```

- [ ] **Step 2: Grant IAM + set AGENT_SERVICE_URL env var for Firebase Functions**

```bash
# Grant Firebase Functions SA permission to invoke the agent service
gcloud run services add-iam-policy-binding agent-service \
  --region us-central1 \
  --member="serviceAccount:myon-53d85@appspot.gserviceaccount.com" \
  --role="roles/run.invoker"

# Get the Cloud Run URL
gcloud run services describe agent-service --region us-central1 --format 'value(status.url)'

# Set as env var in firebase_functions/functions/.env (v2 Functions use dotenv, not functions:config)
echo 'AGENT_SERVICE_URL=https://agent-service-HASH-uc.a.run.app' >> firebase_functions/functions/.env
```

Note: Firebase Functions v2 reads environment variables from `.env` files, not `firebase functions:config`. The `.env` file is already gitignored.

- [ ] **Step 3: Deploy Firebase Functions**

```bash
cd firebase_functions/functions && npm run deploy
```

- [ ] **Step 4: Test via iOS app**

Open the iOS app, start a new conversation. Verify:
- Text responses stream correctly
- Tool calls show in the thinking UI
- Routine/template queries work
- Active workout operations work (Fast Lane)

- [ ] **Step 5: Update documentation**

Update `docs/SHELL_AGENT_ARCHITECTURE.md` to document the new agent service architecture.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(agent): complete Phase 3a — agent service on Cloud Run

New stateless Cloud Run agent service replaces Vertex AI Agent Engine:
- LLM client protocol + Gemini implementation
- Core agent loop with tool execution
- Direct Firestore access via AsyncClient
- All skills migrated (copilot/workout retain HTTP for active workout)
- 4-lane router, planner, critic, safety gate migrated
- Model-agnostic instruction
- Structured observability (JSON logging, trace IDs)
- SSE proxy updated to call Cloud Run"
```

---

## Chunk 4: Phase 3b (Agent Memory) + Phase 3c (Session Elimination)

### Task 27: Agent Memory — Firestore Operations

**Files:**
- Create: `adk_agent/agent_service/app/memory.py`
- Test: `adk_agent/agent_service/tests/test_memory.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_memory.py
import pytest
from unittest.mock import AsyncMock, MagicMock
from app.memory import MemoryManager


@pytest.mark.asyncio
async def test_save_memory():
    mm = MemoryManager.__new__(MemoryManager)
    mock_ref = AsyncMock()
    mock_ref.__getitem__ = MagicMock(return_value=MagicMock(id="mem1"))
    mm.db = MagicMock()
    mm.db.collection.return_value.add = AsyncMock(return_value=mock_ref)

    result = await mm.save_memory("u1", "Prefers 4-day splits", "preference", "conv1")
    assert result["content"] == "Prefers 4-day splits"
    assert result["category"] == "preference"


@pytest.mark.asyncio
async def test_retire_memory():
    mm = MemoryManager.__new__(MemoryManager)
    mock_doc = AsyncMock()
    mock_doc.exists = True
    mm.db = MagicMock()
    mm.db.document.return_value.get = AsyncMock(return_value=mock_doc)
    mm.db.document.return_value.update = AsyncMock()

    result = await mm.retire_memory("u1", "mem1", "Contradicted by user")
    assert result["retired"] is True


@pytest.mark.asyncio
async def test_list_active_memories():
    mm = MemoryManager.__new__(MemoryManager)
    mm.db = MagicMock()

    mock_docs = []
    for i in range(3):
        doc = MagicMock()
        doc.id = f"mem{i}"
        doc.to_dict.return_value = {"content": f"Memory {i}", "category": "preference", "active": True}
        mock_docs.append(doc)

    # Mock async stream
    async def mock_stream():
        for doc in mock_docs:
            yield doc

    mm.db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream = mock_stream

    result = await mm.list_active_memories("u1", limit=50)
    assert len(result) == 3
```

- [ ] **Step 2: Run test — expect FAIL**
- [ ] **Step 3: Write implementation**

```python
# app/memory.py
"""Agent Memory Manager — persistent cross-conversation memory.

Tier 3 of the 4-tier memory system. Stores learned facts about the user
in users/{uid}/agent_memory/{auto-id}.
"""

from __future__ import annotations

from datetime import datetime, timezone
from google.cloud.firestore import AsyncClient


_mm_instance: 'MemoryManager | None' = None


def get_memory_manager() -> 'MemoryManager':
    """Module-level singleton — reuses gRPC channel."""
    global _mm_instance
    if _mm_instance is None:
        _mm_instance = MemoryManager()
    return _mm_instance


class MemoryManager:
    def __init__(self):
        self.db = AsyncClient()

    async def save_memory(
        self, user_id: str, content: str, category: str, conversation_id: str
    ) -> dict:
        data = {
            "content": content,
            "category": category,
            "active": True,
            "created_at": datetime.now(timezone.utc),
            "source_conversation_id": conversation_id,
        }
        ref = await self.db.collection(f"users/{user_id}/agent_memory").add(data)
        return {"id": ref[1].id, **data}

    async def retire_memory(
        self, user_id: str, memory_id: str, reason: str
    ) -> dict:
        doc_ref = self.db.document(f"users/{user_id}/agent_memory/{memory_id}")
        doc = await doc_ref.get()
        if not doc.exists:
            return {"error": f"Memory {memory_id} not found"}
        await doc_ref.update({
            "active": False,
            "retired_at": datetime.now(timezone.utc),
            "retire_reason": reason,
        })
        return {"retired": True, "memory_id": memory_id}

    async def list_active_memories(self, user_id: str, limit: int = 50) -> list[dict]:
        query = (
            self.db.collection(f"users/{user_id}/agent_memory")
            .where("active", "==", True)
            .order_by("created_at", direction="DESCENDING")
            .limit(limit)
        )
        return [{"id": doc.id, **doc.to_dict()} async for doc in query.stream()]

    async def generate_conversation_summary(
        self, user_id: str, conversation_id: str, llm_client, model: str
    ) -> str | None:
        """Generate a summary for a completed conversation (lazy, Tier 4)."""
        from app.firestore_client import FirestoreClient
        coll = FirestoreClient.CONVERSATION_COLLECTION
        conv_ref = self.db.document(
            f"users/{user_id}/{coll}/{conversation_id}"
        )
        conv = await conv_ref.get()
        if not conv.exists:
            return None
        if conv.to_dict().get("summary"):
            return conv.to_dict()["summary"]

        # Load last 10 messages
        msgs_query = (
            self.db.collection(
                f"users/{user_id}/{coll}/{conversation_id}/messages"
            )
            .order_by("timestamp", direction="DESCENDING")
            .limit(10)
        )
        msgs = [doc.to_dict() async for doc in msgs_query.stream()]
        msgs.reverse()

        if not msgs:
            return None

        # Single-shot summary
        transcript = "\n".join(
            f"{m.get('role', 'user')}: {m.get('content', '')}" for m in msgs
        )
        prompt = (
            "Summarize this coaching conversation in 1-2 sentences. "
            "Focus on what was discussed and any decisions made.\n\n"
            f"{transcript}"
        )

        summary_text = ""
        async for chunk in llm_client.stream(
            model, [{"role": "user", "content": prompt}]
        ):
            if chunk.is_text:
                summary_text += chunk.text

        # Persist
        await conv_ref.update({
            "summary": summary_text,
            "completed_at": datetime.now(timezone.utc),
        })
        return summary_text
```

- [ ] **Step 4: Run tests — expect PASS**
- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/memory.py adk_agent/agent_service/tests/test_memory.py
git commit -m "feat(agent): add MemoryManager with save, retire, list, summary"
```

---

### Task 28: Context Builder (360 View)

**Files:**
- Create: `adk_agent/agent_service/app/context_builder.py`
- Test: `adk_agent/agent_service/tests/test_context_builder.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_context_builder.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from app.context_builder import build_system_context
from app.context import RequestContext


@pytest.mark.asyncio
async def test_build_system_context_includes_all_sections():
    ctx = RequestContext(user_id="u1", conversation_id="c1", correlation_id="r1")

    mock_fs = AsyncMock()
    mock_fs.get_planning_context.return_value = {
        "user": {"name": "Test User"},
        "active_routine": {"name": "PPL"},
        "templates": [],
        "recent_workouts": [],
        "analysis": None,
        "weekly_stats": None,
    }
    mock_fs.get_conversation_messages.return_value = []

    mock_mm = AsyncMock()
    mock_mm.list_active_memories.return_value = [
        {"content": "Prefers morning workouts", "category": "preference"}
    ]

    mock_fs_class = MagicMock(return_value=mock_fs)
    mock_mm_class = MagicMock(return_value=mock_mm)

    with patch("app.context_builder.FirestoreClient", mock_fs_class), \
         patch("app.context_builder.MemoryManager", mock_mm_class):
        instruction, history = await build_system_context(ctx)

    assert "Test User" in instruction or "PPL" in instruction
    assert "morning workouts" in instruction
```

- [ ] **Step 2: Run test — expect FAIL**
- [ ] **Step 3: Write implementation**

```python
# app/context_builder.py
"""360 View Context Builder — assembles the full system context.

Auto-loaded before the LLM sees anything. Assembles:
1. INSTRUCTION (coaching persona)
2. AGENT MEMORIES (cross-conversation)
3. RECENT CONVERSATIONS (last 5 summaries)
4. USER PROFILE + TRAINING SNAPSHOT
5. ACTIVE ALERTS (from training analyst)
6. SESSION VARS (current conversation)
7. CONVERSATION HISTORY (last 20 messages)
"""

from __future__ import annotations

from app.context import RequestContext
from app.firestore_client import get_firestore_client
from app.memory import get_memory_manager
from app.instruction import CORE_INSTRUCTION, MEMORY_GUIDANCE


async def build_system_context(
    ctx: RequestContext,
    llm_client=None,
    model: str = "gemini-2.5-flash",
) -> tuple[str, list[dict]]:
    """Build instruction string and conversation history.

    Returns: (instruction, history_messages)
    """
    fs = get_firestore_client()
    mm = get_memory_manager()

    # Parallel loads
    import asyncio
    planning_task = fs.get_planning_context(ctx.user_id)
    memories_task = mm.list_active_memories(ctx.user_id, limit=50)
    history_task = fs.get_conversation_messages(
        ctx.user_id, ctx.conversation_id, limit=20
    )
    summaries_task = _load_recent_summaries(fs, ctx.user_id, limit=5)

    planning, memories, history, summaries = await asyncio.gather(
        planning_task, memories_task, history_task, summaries_task,
        return_exceptions=True,
    )

    # Handle errors gracefully — first-time users may have no data
    if isinstance(planning, Exception):
        planning = {}
    if isinstance(memories, Exception):
        memories = []
    if isinstance(history, Exception):
        history = []
    if isinstance(summaries, Exception):
        summaries = []

    # Lazy summary generation for previous conversation
    if llm_client and summaries is not None:
        await _maybe_generate_previous_summary(
            fs, mm, ctx, llm_client, model
        )

    # Assemble instruction
    instruction_parts = [CORE_INSTRUCTION, MEMORY_GUIDANCE]

    if memories:
        mem_text = "\n".join(f"- [{m['category']}] {m['content']}" for m in memories)
        instruction_parts.append(f"## What You Know About This User\n{mem_text}")

    if summaries:
        sum_text = "\n".join(f"- {s}" for s in summaries)
        instruction_parts.append(f"## Recent Conversations\n{sum_text}")

    if isinstance(planning, dict):
        instruction_parts.append(_format_snapshot(planning))

    # Session vars
    conv_doc = await _get_session_vars(fs, ctx)
    if conv_doc:
        vars_text = "\n".join(f"- {k}: {v}" for k, v in conv_doc.items())
        instruction_parts.append(f"## Session State\n{vars_text}")

    instruction = "\n\n".join(instruction_parts)

    # Format history for LLM
    formatted_history = _format_history(history)

    return instruction, formatted_history


async def _load_recent_summaries(fs: FirestoreClient, user_id: str, limit: int) -> list[str]:
    query = (
        fs.db.collection(f"users/{user_id}/{fs.CONVERSATION_COLLECTION}")
        .where("summary", "!=", None)
        .order_by("completed_at", direction="DESCENDING")
        .limit(limit)
    )
    return [doc.to_dict().get("summary", "") async for doc in query.stream()]


async def _maybe_generate_previous_summary(fs, mm, ctx, llm_client, model):
    """Lazy summary: check if previous conversation needs a summary."""
    query = (
        fs.db.collection(f"users/{ctx.user_id}/{fs.CONVERSATION_COLLECTION}")
        .order_by("created_at", direction="DESCENDING")
        .limit(2)
    )
    convs = [doc async for doc in query.stream()]
    if len(convs) < 2:
        return
    prev = convs[1]  # Second most recent
    if not prev.to_dict().get("summary"):
        await mm.generate_conversation_summary(
            ctx.user_id, prev.id, llm_client, model
        )


async def _get_session_vars(fs: FirestoreClient, ctx: RequestContext) -> dict | None:
    doc = await fs.db.document(
        f"users/{ctx.user_id}/{fs.CONVERSATION_COLLECTION}/{ctx.conversation_id}"
    ).get()
    if doc.exists:
        return doc.to_dict().get("session_vars")
    return None


def _format_snapshot(planning: dict) -> str:
    sections = ["## Current Training Snapshot"]
    user = planning.get("user", {})
    if user.get("name"):
        sections.append(f"User: {user['name']}")
    routine = planning.get("active_routine")
    if routine:
        sections.append(f"Active routine: {routine.get('name', 'Unknown')}")
    analysis = planning.get("analysis")
    if analysis:
        sections.append(f"Latest insight: {analysis.get('summary', 'N/A')}")
    return "\n".join(sections)


def _format_history(messages: list[dict]) -> list[dict]:
    """Format Firestore messages to LLM history.

    Firestore uses `type` field with values: user_prompt, agent_response, artifact.
    LLM expects `role` field with values: user, assistant (model).
    """
    TYPE_TO_ROLE = {"user_prompt": "user", "agent_response": "assistant"}
    formatted = []
    for msg in messages:
        msg_type = msg.get("type", "user_prompt")
        role = TYPE_TO_ROLE.get(msg_type)
        if role:
            formatted.append({"role": role, "content": msg.get("content", "")})
    return formatted
```

- [ ] **Step 4: Run tests — expect PASS**
- [ ] **Step 5: Commit**

```bash
git add adk_agent/agent_service/app/context_builder.py adk_agent/agent_service/tests/test_context_builder.py
git commit -m "feat(agent): add 360 view context builder with all 4 memory tiers"
```

---

### Task 29: Memory Tools + Session Var Tools

**Files:**
- Create: `adk_agent/agent_service/app/tools/memory_tools.py`
- Modify: `adk_agent/agent_service/app/tools/definitions.py`

- [ ] **Step 1: Write memory tool functions**

```python
# app/tools/memory_tools.py
"""Memory and session variable tools for the agent."""

from __future__ import annotations

from app.context import RequestContext
from app.memory import MemoryManager
from app.firestore_client import FirestoreClient


async def save_memory(*, ctx: RequestContext, content: str, category: str) -> dict:
    from app.memory import get_memory_manager
    mm = get_memory_manager()
    return await mm.save_memory(ctx.user_id, content, category, ctx.conversation_id)


async def retire_memory(*, ctx: RequestContext, memory_id: str, reason: str) -> dict:
    from app.memory import get_memory_manager
    mm = get_memory_manager()
    return await mm.retire_memory(ctx.user_id, memory_id, reason)


async def list_memories(*, ctx: RequestContext, offset: int = 0, limit: int = 50) -> dict:
    from app.memory import get_memory_manager
    mm = get_memory_manager()
    memories = await mm.list_active_memories(ctx.user_id, limit=limit)
    return {"memories": memories, "count": len(memories)}


async def set_session_var(*, ctx: RequestContext, key: str, value) -> dict:
    fs = get_firestore_client()
    await fs.db.document(
        f"users/{ctx.user_id}/{fs.CONVERSATION_COLLECTION}/{ctx.conversation_id}"
    ).update({f"session_vars.{key}": value})
    return {"set": key, "value": value}


async def delete_session_var(*, ctx: RequestContext, key: str) -> dict:
    from google.cloud.firestore import DELETE_FIELD
    fs = get_firestore_client()
    await fs.db.document(
        f"users/{ctx.user_id}/{fs.CONVERSATION_COLLECTION}/{ctx.conversation_id}"
    ).update({f"session_vars.{key}": DELETE_FIELD})
    return {"deleted": key}


async def search_past_conversations(*, ctx: RequestContext, query: str, limit: int = 5) -> dict:
    # Simple keyword search across recent conversation messages
    fs = get_firestore_client()
    convs_query = (
        fs.db.collection(f"users/{ctx.user_id}/{fs.CONVERSATION_COLLECTION}")
        .order_by("created_at", direction="DESCENDING")
        .limit(20)
    )
    results = []
    async for conv_doc in convs_query.stream():
        conv_data = conv_doc.to_dict()
        summary = conv_data.get("summary", "")
        if query.lower() in summary.lower():
            results.append({
                "conversation_id": conv_doc.id,
                "summary": summary,
                "date": str(conv_data.get("completed_at", "")),
            })
            if len(results) >= limit:
                break
    return {"results": results}
```

- [ ] **Step 2: Register all memory tools in definitions.py**
- [ ] **Step 3: Commit**

```bash
git add adk_agent/agent_service/app/tools/memory_tools.py adk_agent/agent_service/app/tools/definitions.py
git commit -m "feat(agent): add memory and session variable tools"
```

---

### Task 30: Wire Context Builder into main.py

**Files:**
- Modify: `adk_agent/agent_service/app/main.py`

- [ ] **Step 1: Replace direct instruction building with context_builder**

Replace the instruction + history loading in `stream_handler` with `build_system_context()`. The context builder handles all 4 memory tiers, conversation history, and auto-loaded context.

- [ ] **Step 2: Run full test suite**

```bash
cd adk_agent/agent_service && python -m pytest tests/ -v
```

- [ ] **Step 3: Deploy and verify**

```bash
cd adk_agent/agent_service && make deploy
```

Test via iOS app: verify conversation continuity, memory saves, and session variables.

- [ ] **Step 4: Commit**

```bash
git add adk_agent/agent_service/app/main.py
git commit -m "feat(agent): wire 360 view context builder into /stream endpoint"
```

---

### Task 31: Session Elimination + Dead Code Removal (Phase 3c)

**Files:**
- Modify: `firebase_functions/functions/strengthos/stream-agent-normalized.js`
- Delete: `firebase_functions/functions/sessions/` (entire directory)
- Delete: `Povver/Povver/Services/SessionPreWarmer.swift`
- Modify: `Povver/Povver/Services/DirectStreamingService.swift`
- Modify: `firebase_functions/functions/index.js`
- Delete: `firebase_functions/functions/auth/exchange-token.js` (getServiceToken)
- Modify: `firebase_functions/functions/canvas/expire-proposals-scheduled.js` → delete scheduled function

- [ ] **Step 1: Read session-related and dead code**

Read:
- `firebase_functions/functions/sessions/` — list all files, read each
- `stream-agent-normalized.js` — identify all session logic
- `DirectStreamingService.swift` — identify session ID handling and `getServiceToken` call
- `index.js` — identify all exports to remove
- `firebase_functions/functions/auth/exchange-token.js` — confirm `getServiceToken` scope

- [ ] **Step 2: Remove session logic from SSE proxy**

In `stream-agent-normalized.js` (most of this was done in Task 25, verify clean):
- Remove any remaining `initializeOrReuseSession()` references
- Remove `agent_sessions` Firestore reads/writes
- Remove session validation/invalidation logic

- [ ] **Step 3: Delete session Firebase Functions**

```bash
rm -rf firebase_functions/functions/sessions/
```

- [ ] **Step 4: Delete `getServiceToken` endpoint**

```bash
rm firebase_functions/functions/auth/exchange-token.js
```

This endpoint exchanged Firebase ID tokens for GCP access tokens to call Vertex AI directly. No longer needed — iOS no longer calls Vertex AI.

- [ ] **Step 5: Update index.js — remove dead exports, replace canvas endpoints with no-op stubs**

**Remove these exports** from `firebase_functions/functions/index.js`:
- `cleanupStaleSessions` — scheduled function, no more sessions
- `getServiceToken` — no more Vertex AI token exchange
- `invokeCanvasOrchestrator` — replaced by SSE proxy → Cloud Run
- `expireProposalsScheduled` — no more canvas proposals (replaced by artifacts)
- `onWorkoutCreatedWeekly` — dead export (undefined symbol)
- `onWorkoutFinalizedForUser` — dead export (undefined symbol)

**Replace with no-op stubs** (iOS still calls these until Phase 7 — see AD-4):

```javascript
// No-op stubs — iOS calls these until Phase 7 coordinated cleanup.
// Returns expected response shapes so iOS doesn't error.
const { onRequest } = require('firebase-functions/v2/https');
const { ok } = require('./utils/response');
const { getAuthenticatedUserId } = require('./utils/auth-helpers');
const { v4: uuidv4 } = require('uuid');

exports.openCanvas = onRequest(async (req, res) => {
  getAuthenticatedUserId(req); // auth check still required
  return ok(res, {
    canvasId: req.body.canvasId || uuidv4(),
    sessionId: null,
    isNewSession: true,
    resumeState: { cards: [], cardCount: 0 },
  });
});

exports.bootstrapCanvas = onRequest(async (req, res) => {
  getAuthenticatedUserId(req);
  return ok(res, { canvasId: req.body.canvasId || uuidv4(), bootstrapped: true });
});

exports.initializeSession = onRequest(async (req, res) => {
  getAuthenticatedUserId(req);
  return ok(res, { sessionId: null, isReused: false });
});

exports.preWarmSession = onRequest(async (req, res) => {
  getAuthenticatedUserId(req);
  return ok(res, { preWarmed: true });
});
```

Delete the actual implementation files but keep these stub exports in `index.js`.

Verify with:
```bash
grep -n "onWorkoutCreatedWeekly\|onWorkoutFinalizedForUser\|getServiceToken\|cleanupStaleSessions\|expireProposals\|invokeCanvasOrchestrator" firebase_functions/functions/index.js
```

- [ ] **Step 6: Delete SessionPreWarmer.swift**

```bash
rm Povver/Povver/Services/SessionPreWarmer.swift
```

- [ ] **Step 7: Update DirectStreamingService.swift**

Remove:
- Session ID from the SSE request body
- `getServiceToken` call (line ~849) and all token exchange logic
- The backward-compat `canvasId` field (keep only `conversationId`)
- Any `sessionId` property or parameter

- [ ] **Step 8: Remove SessionPreWarmer references from iOS**

```bash
grep -rn "SessionPreWarmer\|preWarmSession\|getServiceToken\|initializeSession" Povver/Povver/ --include="*.swift"
```

Remove all matches. Check `CanvasService.swift` for `preWarmSession()`, `initializeSession()`, `openCanvas()`, `bootstrapCanvas()` methods — these are now dead code.

- [ ] **Step 9: Remove dead CanvasService methods**

In `Povver/Povver/Services/CanvasService.swift`, remove:
- `applyAction(_:)` — canvas reducer pattern, replaced by artifacts

**Keep until Phase 7** (iOS still calls these, backend now returns no-op stubs):
- `openCanvas(userId:purpose:)` — calls no-op stub
- `bootstrapCanvas(for:purpose:)` — calls no-op stub
- `preWarmSession(userId:purpose:)` — calls no-op stub
- `initializeSession(canvasId:purpose:forceNew:)` — calls no-op stub
- `purgeCanvas` — may still be useful for cleanup

- [ ] **Step 10: Delete agent_sessions Firestore collection data**

Mark `users/{uid}/agent_sessions/` as deprecated/removed in `docs/FIRESTORE_SCHEMA.md`.

- [ ] **Step 11: Build iOS to verify no compilation errors**

```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

- [ ] **Step 12: Run Firebase Functions tests**

```bash
cd firebase_functions/functions && npm test
```

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "feat: Phase 3c — eliminate sessions + remove dead code

Removed:
- SessionPreWarmer.swift (iOS)
- firebase_functions/functions/sessions/ (all session endpoints)
- getServiceToken (auth/exchange-token.js) — no more Vertex AI
- invokeCanvasOrchestrator — replaced by Cloud Run
- cleanupStaleSessions, expireProposalsScheduled — obsolete scheduled functions
- Dead exports: onWorkoutCreatedWeekly, onWorkoutFinalizedForUser
- Session ID and canvasId backward compat from DirectStreamingService
- CanvasService.applyAction (canvas reducer, replaced by artifacts)

Replaced with no-op stubs (Phase 7 removes iOS callers):
- openCanvas, bootstrapCanvas, initializeSession, preWarmSession

6 endpoints removed. 4 endpoints → no-op stubs. 2 scheduled functions removed."
```

---

## Chunk 5: Phase 4 (MCP Server) + Phase 5 (Job Queue)

### Task 32: MCP Server Scaffold

**Files:**
- Create: `mcp_server/package.json`
- Create: `mcp_server/tsconfig.json`
- Create: `mcp_server/Dockerfile`
- Create: `mcp_server/Makefile`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "povver-mcp-server",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js",
    "dev": "tsx src/index.ts",
    "test": "node --test dist/tests/*.test.js"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0",
    "firebase-admin": "^12.0.0"
  },
  "devDependencies": {
    "typescript": "^5.5.0",
    "tsx": "^4.19.0",
    "@types/node": "^22.0.0"
  }
}
```

- [ ] **Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "declaration": true
  },
  "include": ["src/**/*"]
}
```

- [ ] **Step 3: Create Dockerfile**

```dockerfile
FROM --platform=linux/amd64 node:20-slim

WORKDIR /app

COPY package*.json ./
RUN npm ci --production

COPY dist/ dist/

# Import shared modules from Firebase Functions
COPY shared/ shared/

CMD ["node", "dist/index.js"]
```

- [ ] **Step 4: Create Makefile**

```makefile
.PHONY: help install build test dev deploy

PROJECT_ID ?= myon-53d85
REGION ?= us-central1
SERVICE_NAME ?= mcp-server

help:
	@echo "MCP Server"
	@echo "=========="
	@echo "  make install  - Install dependencies"
	@echo "  make build    - Build TypeScript"
	@echo "  make test     - Run tests"
	@echo "  make dev      - Run locally"
	@echo "  make deploy   - Build + deploy to Cloud Run"

install:
	npm install

build:
	npm run build

test:
	npm run build && npm test

dev:
	npm run dev

deploy: build
	cp -r ../firebase_functions/functions/shared shared/
	gcloud builds submit --tag gcr.io/$(PROJECT_ID)/$(SERVICE_NAME):latest --project=$(PROJECT_ID)
	gcloud run deploy $(SERVICE_NAME) \
		--image gcr.io/$(PROJECT_ID)/$(SERVICE_NAME):latest \
		--region $(REGION) \
		--platform managed \
		--allow-unauthenticated \
		--memory 256Mi \
		--cpu 1 \
		--min-instances 0 \
		--max-instances 5 \
		--timeout 60
	rm -rf shared/
```

- [ ] **Step 5: Commit**

```bash
git add mcp_server/
git commit -m "feat(mcp): scaffold MCP server project"
```

---

### Task 33: MCP Authentication

**Files:**
- Create: `mcp_server/src/auth.ts`
- Test: `mcp_server/src/tests/auth.test.ts`

- [ ] **Step 1: Write auth module**

```typescript
// src/auth.ts
import { createHash } from 'crypto';
import admin from 'firebase-admin';

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

export interface AuthResult {
  userId: string;
  keyName: string;
}

export async function authenticateApiKey(apiKey: string): Promise<AuthResult> {
  const keyHash = createHash('sha256').update(apiKey).digest('hex');
  const doc = await db.doc(`mcp_api_keys/${keyHash}`).get();

  if (!doc.exists) {
    throw new Error('Invalid API key');
  }

  const data = doc.data()!;

  // Check premium status
  const userDoc = await db.doc(`users/${data.user_id}`).get();
  if (!userDoc.exists) {
    throw new Error('User not found');
  }

  const userData = userDoc.data()!;
  // Mirror isPremiumUser() logic: check override first, then tier
  const isPremium = userData.subscription_override === 'premium'
                 || userData.subscription_tier === 'premium';
  if (!isPremium) {
    throw new Error('Premium subscription required for MCP access');
  }

  // Update last_used_at
  await doc.ref.update({ last_used_at: admin.firestore.FieldValue.serverTimestamp() });

  return { userId: data.user_id, keyName: data.name || 'default' };
}
```

- [ ] **Step 2: Commit**

```bash
git add mcp_server/src/auth.ts
git commit -m "feat(mcp): add API key authentication with premium validation"
```

---

### Task 34: MCP Tool Definitions + Server

**Files:**
- Create: `mcp_server/src/tools.ts`
- Create: `mcp_server/src/index.ts`

- [ ] **Step 1: Write tools.ts**

Import shared business logic modules and expose as MCP tools:

```typescript
// src/tools.ts
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import admin from 'firebase-admin';

// Import shared business logic (copied into build context)
// Path is ../shared/ because this runs from dist/ after TypeScript compilation
const routines = require('../shared/routines');
const templates = require('../shared/templates');
const workouts = require('../shared/workouts');
const exercises = require('../shared/exercises');
const trainingQueries = require('../shared/training-queries');
const planningContext = require('../shared/planning-context');

const db = admin.firestore();

export function registerTools(server: McpServer, userId: string) {
  // Read tools
  server.tool('get_training_snapshot', 'Get user training snapshot', {},
    async () => {
      const ctx = await planningContext.getPlanningContext(db, userId);
      return { content: [{ type: 'text', text: JSON.stringify(ctx, null, 2) }] };
    }
  );

  server.tool('list_routines', 'List all routines', {},
    async () => {
      const items = await routines.listRoutines(db, userId);
      return { content: [{ type: 'text', text: JSON.stringify(items, null, 2) }] };
    }
  );

  server.tool('get_routine', 'Get a specific routine', {
    routine_id: { type: 'string', description: 'Routine ID' }
  }, async ({ routine_id }) => {
    const routine = await routines.getRoutine(db, userId, routine_id);
    return { content: [{ type: 'text', text: JSON.stringify(routine, null, 2) }] };
  });

  // --- Templates ---
  server.tool('list_templates', 'List all workout templates', {},
    async () => {
      const items = await templates.listTemplates(db, userId);
      return { content: [{ type: 'text', text: JSON.stringify(items, null, 2) }] };
    }
  );

  server.tool('get_template', 'Get a specific template', {
    template_id: { type: 'string', description: 'Template ID' }
  }, async ({ template_id }) => {
    const tmpl = await templates.getTemplate(db, userId, template_id);
    return { content: [{ type: 'text', text: JSON.stringify(tmpl, null, 2) }] };
  });

  // --- Workouts ---
  server.tool('list_workouts', 'List recent workouts', {
    limit: { type: 'number', description: 'Max results (default 20)', default: 20 }
  }, async ({ limit }) => {
    const items = await workouts.listWorkouts(db, userId, { limit: limit || 20 });
    return { content: [{ type: 'text', text: JSON.stringify(items, null, 2) }] };
  });

  server.tool('get_workout', 'Get a specific workout', {
    workout_id: { type: 'string', description: 'Workout ID' }
  }, async ({ workout_id }) => {
    const w = await workouts.getWorkout(db, userId, workout_id);
    return { content: [{ type: 'text', text: JSON.stringify(w, null, 2) }] };
  });

  // --- Exercises ---
  server.tool('search_exercises', 'Search exercise catalog', {
    query: { type: 'string', description: 'Search query' },
    limit: { type: 'number', description: 'Max results', default: 10 }
  }, async ({ query, limit }) => {
    const items = await exercises.searchExercises(db, query, { limit: limit || 10 });
    return { content: [{ type: 'text', text: JSON.stringify(items, null, 2) }] };
  });

  // --- Training Analysis ---
  server.tool('get_training_analysis', 'Get training analysis insights', {
    sections: { type: 'array', items: { type: 'string' }, description: 'Sections to include', optional: true }
  }, async ({ sections }) => {
    const analysis = await trainingQueries.getAnalysisSummary(db, userId, { sections });
    return { content: [{ type: 'text', text: JSON.stringify(analysis, null, 2) }] };
  });

  server.tool('get_muscle_group_progress', 'Get muscle group progress over time', {
    group: { type: 'string', description: 'Muscle group name' },
    weeks: { type: 'number', description: 'Number of weeks', default: 8 }
  }, async ({ group, weeks }) => {
    const data = await trainingQueries.getMuscleGroupSummary(db, userId, { group, weeks: weeks || 8 });
    return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
  });

  server.tool('get_exercise_progress', 'Get exercise progress over time', {
    exercise: { type: 'string', description: 'Exercise name' },
    weeks: { type: 'number', description: 'Number of weeks', default: 8 }
  }, async ({ exercise, weeks }) => {
    const data = await trainingQueries.getExerciseSummary(db, userId, { exercise, weeks: weeks || 8 });
    return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
  });

  server.tool('query_sets', 'Query raw set-level training data', {
    target: { type: 'object', description: 'Target filter (exercise, muscle_group, or muscle)' },
    limit: { type: 'number', description: 'Max results', default: 50 }
  }, async ({ target, limit }) => {
    const data = await trainingQueries.querySets(db, userId, { target, limit: limit || 50 });
    return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
  });

  // --- Write Tools ---
  server.tool('create_routine', 'Create a new routine', {
    name: { type: 'string', description: 'Routine name' },
    template_ids: { type: 'array', items: { type: 'string' }, description: 'Template IDs' },
    frequency: { type: 'number', description: 'Days per week', optional: true }
  }, async (args) => {
    const routine = await routines.createRoutine(db, userId, args);
    return { content: [{ type: 'text', text: JSON.stringify(routine, null, 2) }] };
  });

  server.tool('update_routine', 'Update an existing routine', {
    routine_id: { type: 'string', description: 'Routine ID' },
    updates: { type: 'object', description: 'Fields to update' }
  }, async ({ routine_id, updates }) => {
    const routine = await routines.patchRoutine(db, userId, routine_id, updates);
    return { content: [{ type: 'text', text: JSON.stringify(routine, null, 2) }] };
  });

  server.tool('create_template', 'Create a new workout template', {
    name: { type: 'string', description: 'Template name' },
    exercises: { type: 'array', description: 'Exercise list with sets' }
  }, async (args) => {
    const tmpl = await templates.createTemplate(db, userId, args);
    return { content: [{ type: 'text', text: JSON.stringify(tmpl, null, 2) }] };
  });

  server.tool('update_template', 'Update an existing template', {
    template_id: { type: 'string', description: 'Template ID' },
    updates: { type: 'object', description: 'Fields to update' }
  }, async ({ template_id, updates }) => {
    const tmpl = await templates.patchTemplate(db, userId, template_id, updates);
    return { content: [{ type: 'text', text: JSON.stringify(tmpl, null, 2) }] };
  });

  // --- Memory (read-only via MCP) ---
  server.tool('list_memories', 'List agent memories about the user', {},
    async () => {
      const memSnap = await db.collection(`users/${userId}/agent_memory`)
        .where('active', '==', true)
        .orderBy('created_at', 'desc')
        .limit(50)
        .get();
      const memories = memSnap.docs.map(d => ({ id: d.id, ...d.data() }));
      return { content: [{ type: 'text', text: JSON.stringify(memories, null, 2) }] };
    }
  );
}
```

- [ ] **Step 2: Write index.ts (server entry)**

```typescript
// src/index.ts
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createServer } from 'http';
import { authenticateApiKey } from './auth.js';
import { registerTools } from './tools.js';

const PORT = parseInt(process.env.PORT || '8080');

const httpServer = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  // Extract API key from Authorization header
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing API key' }));
    return;
  }

  const apiKey = authHeader.slice(7);

  try {
    const auth = await authenticateApiKey(apiKey);

    const server = new McpServer({ name: 'povver', version: '1.0.0' });
    registerTools(server, auth.userId);

    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    await server.connect(transport);
    await transport.handleRequest(req, res);
  } catch (e: any) {
    res.writeHead(e.message === 'Premium subscription required for MCP access' ? 403 : 401);
    res.end(JSON.stringify({ error: e.message }));
  }
});

httpServer.listen(PORT, () => {
  console.log(`MCP server listening on port ${PORT}`);
});
```

- [ ] **Step 3: Build and test locally**

```bash
cd mcp_server && npm install && npm run build
```

- [ ] **Step 4: Commit**

```bash
git add mcp_server/src/
git commit -m "feat(mcp): add MCP server with Streamable HTTP transport and shared tools"
```

---

### Task 35: iOS — API Key Generation UI

**Files:**
- Create: `Povver/Povver/Views/Settings/ConnectedAppsView.swift`
- Modify: Settings navigation to include Connected Apps

- [ ] **Step 1: Create ConnectedAppsView**

Premium-gated view with:
- "Generate API Key" button (shows key once, copies to clipboard)
- List of existing keys (name, created_at, last_used_at)
- Revoke button per key
- Instructions for connecting Claude Desktop / ChatGPT

Key generation goes through a Firebase Function (not client-side Firestore write), because `mcp_api_keys` is server-only:

1. iOS calls `POST /generateMcpApiKey` with `{ name: "My Key" }`
2. Firebase Function generates random 32-byte key, SHA-256 hashes it
3. Function writes to `mcp_api_keys/{hash}` via Admin SDK
4. Function returns the raw key to the client (shown once, never stored server-side)
5. iOS displays key for user to copy

Listing/revoking keys: Firebase Function endpoint queries `mcp_api_keys` by `user_id`.

- [ ] **Step 1b: Create Firebase Function for key management**

Create `firebase_functions/functions/mcp/generate-api-key.js` and `firebase_functions/functions/mcp/list-api-keys.js` and `firebase_functions/functions/mcp/revoke-api-key.js`. Use `requireAuth` (iOS-only, not API key lane). Premium gate via `isPremiumUser`.

- [ ] **Step 2: Add Firestore rules for mcp_api_keys and agent_memory**

Add to `firestore.rules`:
```
match /mcp_api_keys/{keyHash} {
  // Server-only (Admin SDK) — no client reads/writes
  allow read, write: if false;
}
```

Also add `agent_memory` rules (under the `users/{userId}` match block):
```
match /users/{userId}/agent_memory/{memoryId} {
  // Agent service writes via Admin SDK; iOS can read for display
  allow read: if request.auth != null && request.auth.uid == userId;
  allow write: if false; // Admin SDK only
}
```

- [ ] **Step 3: Add navigation link from Settings**
- [ ] **Step 4: Build and test**

```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/Views/Settings/ConnectedAppsView.swift
git commit -m "feat(ios): add Connected Apps settings for MCP API key management"
```

---

### Task 36: MCP Deploy + Verification

- [ ] **Step 1: Deploy MCP server**

The Makefile `deploy` target must include `--service-account` and `--set-env-vars`:

```bash
# In mcp_server/Makefile deploy target:
deploy:
	cp -r ../firebase_functions/functions/shared shared/
	gcloud run deploy mcp-server \
		--source . \
		--region us-central1 \
		--allow-unauthenticated \
		--service-account ai-agents@$(PROJECT_ID).iam.gserviceaccount.com \
		--set-env-vars "GOOGLE_CLOUD_PROJECT=$(PROJECT_ID)"
	rm -rf shared/
```

```bash
cd mcp_server && make deploy
```

- [ ] **Step 2: Test with Claude Desktop**

Generate an API key via the iOS app. Configure Claude Desktop:
```json
{
  "mcpServers": {
    "povver": {
      "url": "https://mcp-server-HASH-uc.a.run.app",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

Verify: list routines, get training snapshot, search exercises.

- [ ] **Step 3: Update documentation**

Create `docs/MCP_SERVER_ARCHITECTURE.md` documenting the MCP server.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: complete Phase 4 — MCP server for external LLM access"
```

---

### Task 37: Refactor JS Workout Triggers to Cloud Tasks (Phase 5)

> **AD-1:** The workout completion pipeline stays in JavaScript. The existing 2,960 lines across 6 files, writing to 11 Firestore collections through 7 transaction patterns with 4 idempotency mechanisms, is battle-tested JS. The problem was *trigger reliability* (silent failures, no observability), not the language. This task replaces Firestore triggers with Cloud Tasks for reliable, observable, retryable processing.

**Files:**
- Create: `firebase_functions/functions/training/process-workout-completion.js`
- Create: `firebase_functions/functions/triggers/workout-completion-task.js`
- Create: `firebase_functions/functions/triggers/workout-completion-watchdog.js`
- Modify: `firebase_functions/functions/triggers/weekly-analytics.js`
- Modify: `firebase_functions/functions/workouts/upsert-workout.js`
- Modify: `firebase_functions/functions/workouts/complete-active-workout.js`
- Modify: `firebase_functions/functions/index.js`
- Modify: `firebase_functions/functions/package.json`

- [ ] **Step 1: Read the current trigger implementations**

Read in full:
- `firebase_functions/functions/triggers/weekly-analytics.js` — `onWorkoutCompleted` + `onWorkoutCreatedWithEnd` (the duplicated analytics cascade)
- `firebase_functions/functions/triggers/workout-routine-cursor.js` — `onWorkoutCreatedUpdateRoutineCursor`
- `firebase_functions/functions/workouts/upsert-workout.js` — where workouts are created/updated
- `firebase_functions/functions/workouts/complete-active-workout.js` — where end_time is set

- [ ] **Step 2: Add npm dependency**

```bash
cd firebase_functions/functions && npm install @google-cloud/tasks
```

Add `"@google-cloud/tasks": "^5.0.0"` to `package.json`.
Also add `"uuid": "^9.0.0"` (needed by SSE proxy Task 25).

- [ ] **Step 3: Extract shared processing function**

Extract the duplicated logic from `onWorkoutCompleted` and `onWorkoutCreatedWithEnd` into a single callable:

```javascript
// training/process-workout-completion.js
/**
 * Shared workout completion processor — extracted from the duplicated
 * trigger logic in weekly-analytics.js.
 *
 * Called by Cloud Tasks handler. All 11 collection writes happen here
 * in a single transaction-safe flow.
 */
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { generateSetFacts } = require('./set-facts-generator');
const { appendExerciseSeries, appendMuscleSeries, upsertRollup } = require('../utils/analytics-writes');
const { mapMuscleGroups } = require('../utils/muscle-taxonomy');
const { calculateCaps } = require('../utils/caps');
const logger = require('firebase-functions/logger');

const db = getFirestore();

async function processWorkoutCompletion(userId, workoutId) {
  const workoutRef = db.doc(`users/${userId}/workouts/${workoutId}`);
  const workoutDoc = await workoutRef.get();

  if (!workoutDoc.exists) {
    logger.warn('Workout not found', { userId, workoutId });
    return { skipped: true, reason: 'not_found' };
  }

  const workout = workoutDoc.data();
  if (!workout.end_time) {
    logger.warn('Workout not completed', { userId, workoutId });
    return { skipped: true, reason: 'not_completed' };
  }

  // Idempotency check: skip if already processed
  const watermark = await db.doc(`users/${userId}/watermarks/analytics`).get();
  if (watermark.exists && watermark.data().processed_workouts?.includes(workoutId)) {
    logger.info('Workout already processed', { userId, workoutId });
    return { skipped: true, reason: 'already_processed' };
  }

  // === Core pipeline (extracted from weekly-analytics.js) ===
  // Steps 1-11 use the EXISTING battle-tested JS logic.
  // The only change is that this is called from Cloud Tasks instead of triggers.

  // 1. Generate set_facts
  const setFacts = generateSetFacts(workout, workoutId, userId);

  // 2-8. All analytics writes (exercise series, muscle series, rollups, etc.)
  // [Uses the existing functions from utils/analytics-writes.js, unchanged]

  // 9. Advance routine cursor (absorbed from workout-routine-cursor.js)
  if (workout.source_routine_id && workout.source_template_id) {
    await db.doc(`users/${userId}/routines/${workout.source_routine_id}`).update({
      last_completed_template_id: workout.source_template_id,
      last_completed_at: FieldValue.serverTimestamp(),
    });
  }

  // 10. Update watermark (includes workoutId for idempotency)
  await db.doc(`users/${userId}/watermarks/analytics`).set({
    last_processed_workout: workoutId,
    processed_at: FieldValue.serverTimestamp(),
    processed_workouts: FieldValue.arrayUnion(workoutId),
  }, { merge: true });

  // 11. Enqueue training analysis (if premium)
  const userDoc = await db.doc(`users/${userId}`).get();
  const userData = userDoc.exists ? userDoc.data() : {};
  const isPremium = userData.subscription_override === 'premium'
                 || userData.subscription_tier === 'premium';
  if (isPremium) {
    await db.collection('training_analysis_jobs').add({
      type: 'POST_WORKOUT',
      status: 'QUEUED',
      payload: { user_id: userId, workout_id: workoutId },
      created_at: FieldValue.serverTimestamp(),
    });
  }

  logger.info('Processed workout completion', {
    userId, workoutId, setFactsCount: setFacts.length,
  });
  return { processed: true, setFactsCount: setFacts.length };
}

module.exports = { processWorkoutCompletion };
```

**Note:** The actual implementation step copies the EXACT logic from the existing trigger bodies — the code above shows the structure. The implementer must read `weekly-analytics.js` and transplant the steps verbatim, not reimplement them.

- [ ] **Step 4: Create Cloud Tasks handler**

```javascript
// triggers/workout-completion-task.js
/**
 * Cloud Tasks handler for workout completion processing.
 * Receives task payloads from Cloud Tasks queue.
 */
const { onRequest } = require('firebase-functions/v2/https');
const { processWorkoutCompletion } = require('../training/process-workout-completion');
const logger = require('firebase-functions/logger');

exports.processWorkoutCompletionTask = onRequest(
  { region: 'us-central1', memory: '512MiB', timeoutSeconds: 120 },
  async (req, res) => {
    // Cloud Tasks sends POST with JSON body
    const { userId, workoutId } = req.body;

    if (!userId || !workoutId) {
      logger.error('Missing userId or workoutId in task payload');
      res.status(400).send('Missing userId or workoutId');
      return;
    }

    try {
      const result = await processWorkoutCompletion(userId, workoutId);
      logger.info('Task completed', { userId, workoutId, result });
      res.status(200).json(result);
    } catch (err) {
      logger.error('Task failed', { userId, workoutId, error: err.message });
      // Return 500 so Cloud Tasks retries
      res.status(500).send(err.message);
    }
  }
);
```

- [ ] **Step 5: Create helper to enqueue Cloud Tasks**

```javascript
// utils/enqueue-workout-task.js
const { CloudTasksClient } = require('@google-cloud/tasks');
const logger = require('firebase-functions/logger');

const client = new CloudTasksClient();
const PROJECT = process.env.GCLOUD_PROJECT || 'myon-53d85';
const LOCATION = 'us-central1';
const QUEUE = 'workout-completion';

async function enqueueWorkoutCompletion(userId, workoutId) {
  const parent = client.queuePath(PROJECT, LOCATION, QUEUE);

  // Get the Cloud Functions URL for the task handler
  const url = `https://${LOCATION}-${PROJECT}.cloudfunctions.net/processWorkoutCompletionTask`;

  const task = {
    httpRequest: {
      httpMethod: 'POST',
      url,
      headers: { 'Content-Type': 'application/json' },
      body: Buffer.from(JSON.stringify({ userId, workoutId })).toString('base64'),
      oidcToken: {
        serviceAccountEmail: `${PROJECT}@appspot.gserviceaccount.com`,
      },
    },
    // Deduplicate by workout ID (prevents double-processing)
    name: `${parent}/tasks/workout-${userId.slice(0, 8)}-${workoutId}`,
  };

  try {
    await client.createTask({ parent, task });
    logger.info('Enqueued workout completion task', { userId, workoutId });
  } catch (err) {
    if (err.code === 6) {
      // ALREADY_EXISTS — task already enqueued, safe to ignore
      logger.info('Task already exists (idempotent)', { userId, workoutId });
    } else {
      throw err;
    }
  }
}

module.exports = { enqueueWorkoutCompletion };
```

- [ ] **Step 6: Update upsert-workout.js to enqueue Cloud Task**

In `firebase_functions/functions/workouts/upsert-workout.js`, after a workout is created with `end_time` already set (imported workouts), call:

```javascript
const { enqueueWorkoutCompletion } = require('../utils/enqueue-workout-task');

// After successful upsert, if workout has end_time:
if (workoutData.end_time) {
  await enqueueWorkoutCompletion(userId, workoutId);
}
```

- [ ] **Step 7: Update complete-active-workout.js to enqueue Cloud Task**

In `firebase_functions/functions/workouts/complete-active-workout.js`, after setting `end_time`:

```javascript
const { enqueueWorkoutCompletion } = require('../utils/enqueue-workout-task');

// After setting end_time on the workout document:
await enqueueWorkoutCompletion(userId, workoutId);
```

- [ ] **Step 8: Create watchdog scheduled function**

```javascript
// triggers/workout-completion-watchdog.js
/**
 * Daily watchdog — catches workouts that were completed but never processed.
 * Safety net for any Cloud Tasks delivery failures.
 */
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { getFirestore } = require('firebase-admin/firestore');
const { enqueueWorkoutCompletion } = require('../utils/enqueue-workout-task');
const logger = require('firebase-functions/logger');

const db = getFirestore();

exports.workoutCompletionWatchdog = onSchedule(
  { schedule: 'every 24 hours', region: 'us-central1' },
  async () => {
    // Find workouts completed in last 48h that have no watermark entry
    const cutoff = new Date(Date.now() - 48 * 60 * 60 * 1000);
    const usersSnap = await db.collection('users').get();

    let requeued = 0;
    for (const userDoc of usersSnap.docs) {
      const userId = userDoc.id;
      const watermark = await db.doc(`users/${userId}/watermarks/analytics`).get();
      const processedIds = watermark.exists
        ? (watermark.data().processed_workouts || [])
        : [];

      const recentWorkouts = await db.collection(`users/${userId}/workouts`)
        .where('end_time', '>=', cutoff)
        .get();

      for (const wDoc of recentWorkouts.docs) {
        if (!processedIds.includes(wDoc.id)) {
          await enqueueWorkoutCompletion(userId, wDoc.id);
          requeued++;
        }
      }
    }

    logger.info('Watchdog completed', { requeued });
  }
);
```

- [ ] **Step 9: Remove old triggers from weekly-analytics.js**

Remove `onWorkoutCompleted` and `onWorkoutCreatedWithEnd` trigger exports from `weekly-analytics.js`. Keep `weeklyStatsRecalculation` scheduled function and `onWorkoutDeleted` trigger (deletion analytics stay as a trigger — simpler, less frequent).

- [ ] **Step 10: Delete workout-routine-cursor.js**

```bash
rm firebase_functions/functions/triggers/workout-routine-cursor.js
```

The routine cursor advance is now step 9 in `processWorkoutCompletion()`. This eliminates the race condition where the cursor could update before analytics.

- [ ] **Step 11: Create Cloud Tasks queue**

```bash
gcloud tasks queues create workout-completion \
  --location=us-central1 \
  --max-dispatches-per-second=5 \
  --max-concurrent-dispatches=5 \
  --max-attempts=5 \
  --min-backoff=10s \
  --max-backoff=300s
```

- [ ] **Step 12: Grant IAM permissions**

```bash
# Firebase Functions SA needs to enqueue tasks
gcloud projects add-iam-policy-binding myon-53d85 \
  --member="serviceAccount:myon-53d85@appspot.gserviceaccount.com" \
  --role="roles/cloudtasks.enqueuer"
```

- [ ] **Step 13: Update index.js**

Remove:
- `onWorkoutCompleted` export (trigger replaced by Cloud Tasks)
- `onWorkoutCreatedWithEnd` export (trigger replaced by Cloud Tasks)
- `onWorkoutCreatedUpdateRoutineCursor` export (absorbed into processWorkoutCompletion)

Add:
- `processWorkoutCompletionTask` export
- `workoutCompletionWatchdog` export

- [ ] **Step 14: Run tests**

```bash
cd firebase_functions/functions && npm test
```

- [ ] **Step 15: Deploy and verify**

Deploy Firebase Functions, then test:
1. Complete a workout via iOS → verify Cloud Task fires → verify all 11 collections written
2. Import a workout via CSV → verify Cloud Task fires
3. Verify watchdog runs without errors

- [ ] **Step 16: Commit**

```bash
git add firebase_functions/functions/training/process-workout-completion.js \
       firebase_functions/functions/triggers/workout-completion-task.js \
       firebase_functions/functions/triggers/workout-completion-watchdog.js \
       firebase_functions/functions/utils/enqueue-workout-task.js \
       firebase_functions/functions/triggers/weekly-analytics.js \
       firebase_functions/functions/workouts/upsert-workout.js \
       firebase_functions/functions/workouts/complete-active-workout.js \
       firebase_functions/functions/index.js \
       firebase_functions/functions/package.json
git commit -m "feat: Phase 5 — replace trigger cascade with Cloud Tasks queue

AD-1: Workout completion stays in JavaScript. The 2,960 lines of battle-tested
JS across 6 files (set-facts-generator, analytics-writes, muscle-taxonomy,
caps, weekly-analytics, workout-routine-cursor) now run via Cloud Tasks
instead of Firestore triggers.

Benefits:
- Reliable: Cloud Tasks retries on failure (triggers silently drop)
- Observable: task success/failure visible in Cloud Console
- Idempotent: deduplication by workout ID in task name + watermark
- Atomic: single processWorkoutCompletion() callable, no race conditions
- Watchdog: daily scheduled function catches any missed completions

Removed: onWorkoutCompleted, onWorkoutCreatedWithEnd triggers,
workout-routine-cursor.js (absorbed into processor)."
```

---

### Task 39b: Move post_workout_analyst.py to Training Analyst (Phase 5)

**Files:**
- Move: `adk_agent/canvas_orchestrator/workers/post_workout_analyst.py` → `adk_agent/training_analyst/workers/post_workout_analyst.py`
- Modify: `adk_agent/training_analyst/Makefile`

- [ ] **Step 1: Read the current post_workout_analyst.py**

Read `adk_agent/canvas_orchestrator/workers/post_workout_analyst.py`. Understand:
- It's a standalone CLI worker (`python post_workout_analyst.py --user-id X --workout-id Y`)
- It calls `progression_skills.apply_progression()` via HTTP to the `applyProgression` Firebase Function
- It imports from `app.skills.progression_skills` in the canvas_orchestrator

- [ ] **Step 2: Move the file**

```bash
cp adk_agent/canvas_orchestrator/workers/post_workout_analyst.py adk_agent/training_analyst/workers/post_workout_analyst.py
```

- [ ] **Step 3: Update imports**

The moved file needs to call `applyProgression` directly via HTTP (using `httpx`) instead of importing from `canvas_orchestrator`. Update the import to use a local HTTP client:

```python
# Replace: from app.skills.progression_skills import apply_progression
# With: direct httpx call to applyProgression endpoint
import httpx
FUNCTIONS_URL = os.getenv("MYON_FUNCTIONS_BASE_URL", "https://us-central1-myon-53d85.cloudfunctions.net")
MYON_API_KEY = os.getenv("MYON_API_KEY", "")

async def apply_progression(user_id, changes, **kwargs):
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{FUNCTIONS_URL}/applyProgression",
            json={
                "userId": user_id,
                "changes": changes,
                **kwargs,
            },
            headers={"x-api-key": MYON_API_KEY},
        )
        return resp.json()
```

- [ ] **Step 4: Add Makefile target**

Add to `adk_agent/training_analyst/Makefile`:
```makefile
# Run post-workout analyst locally
analyst-local:
	python workers/post_workout_analyst.py
```

- [ ] **Step 5: Verify the original in canvas_orchestrator can be deleted after full migration**

Note: Don't delete the original yet — it's still referenced by the current deployed system. It becomes dead code once the new agent service is deployed. Clean up in Phase 3c.

- [ ] **Step 6: Commit**

```bash
git add adk_agent/training_analyst/workers/post_workout_analyst.py adk_agent/training_analyst/Makefile
git commit -m "refactor: move post_workout_analyst from canvas_orchestrator to training_analyst"
```

---

## Chunk 6: Phase 6 (Training Analyst) + Phase 7 (iOS Cleanup)

### Task 40: Training Analyst — New Analysis Sections (Phase 6)

**Files:**
- Modify: `adk_agent/training_analyst/app/analyzers/post_workout.py`
- Modify: `adk_agent/training_analyst/app/analyzers/weekly_review.py`
- Create: `adk_agent/training_analyst/app/analyzers/plateau_detector.py`
- Create: `adk_agent/training_analyst/app/analyzers/volume_optimizer.py`

- [ ] **Step 1: Read existing analyzers**

Read `adk_agent/training_analyst/app/analyzers/post_workout.py` and `weekly_review.py` to understand the pattern.

- [ ] **Step 2: Add plateau_detector.py**

New analyzer. Reads `users/{uid}/analytics_series_exercise` for the last 4 weeks. An exercise is "plateaued" if its best e1RM has not increased for 3+ consecutive weeks with at least 2 data points per week.

```python
# app/analyzers/plateau_detector.py
"""Plateau detection — identifies stalled exercises."""

async def detect_plateaus(db, user_id: str) -> list[dict]:
    """Returns list of plateaued exercises with suggested interventions."""
    # Read analytics_series_exercise for last 4 weeks
    # Group by exercise_name, check if best_e1rm is flat/declining
    # Return: [{ exercise_name, weeks_stalled, last_e1rm, suggested_action }]
    # suggested_action is one of: "increase_volume", "change_rep_range", "add_variation"
```

Output written to: `users/{uid}/analysis_insights/{autoId}` with `section: "plateau_report"`.

- [ ] **Step 3: Add volume_optimizer.py**

New analyzer. Reads `users/{uid}/analytics_series_muscle_group` for the last 2 weeks and compares against known MEV/MRV ranges per muscle group.

```python
# app/analyzers/volume_optimizer.py
"""Volume optimization — actual vs target per muscle group."""

# MEV/MRV reference ranges (sets per week)
VOLUME_TARGETS = {
    "chest": {"mev": 10, "mrv": 20},
    "back": {"mev": 10, "mrv": 22},
    "quads": {"mev": 8, "mrv": 18},
    # ... all muscle groups
}

async def analyze_volume(db, user_id: str) -> dict:
    """Returns per-muscle actual vs target with surplus/deficit flags."""
    # Read analytics_series_muscle_group for last 2 weeks, average weekly sets
    # Compare against VOLUME_TARGETS
    # Return: { muscle_group: { actual_sets, mev, mrv, status: "deficit"|"optimal"|"surplus" } }
```

Output written to: `users/{uid}/analysis_insights/{autoId}` with `section: "volume_optimization"`.

- [ ] **Step 4: Enhance post_workout.py**

Add `progression_candidates` section. After post-workout analysis, check if any exercises in the workout hit target reps with RIR >= 2 (indicating ready for weight increase). Read the exercise's recent series to confirm trend.

Output shape: `{ "progression_candidates": [{ "exercise_name": "Bench Press", "current_weight": 80, "suggested_weight": 82.5, "reason": "Hit 8 reps at RPE 7 for 2 consecutive sessions" }] }`

- [ ] **Step 5: Enhance weekly_review.py**

Add two new sections:

**`periodization_status`:** Calculate Acute:Chronic Workload Ratio (ACWR) using weekly volume over 4-week acute and 8-week chronic windows. Flag if ACWR > 1.3 (injury risk) or < 0.8 (detraining). Suggest deload if ACWR > 1.2 for 2+ consecutive weeks.

**`consistency_trends`:** Count training sessions per week over 4/8/12 week windows. Flag "dropout risk" if frequency has declined for 3+ consecutive weeks. Output: `{ "weeks_4": 3.5, "weeks_8": 3.2, "weeks_12": 2.8, "trend": "declining", "risk": "moderate" }`

- [ ] **Step 5b: Wire new sections into context_builder.py**

Update `adk_agent/agent_service/app/context_builder.py` to load the latest plateau_report, volume_optimization, and periodization_status from `analysis_insights` and include them in the "Active Alerts" section of the auto-loaded system context.

- [ ] **Step 6: Run tests**

```bash
cd adk_agent/training_analyst && python -m pytest tests/ -v
```

- [ ] **Step 7: Deploy**

```bash
cd adk_agent/training_analyst && make deploy
```

- [ ] **Step 8: Commit**

```bash
git add adk_agent/training_analyst/
git commit -m "feat(analyst): Phase 6 — add plateau, volume, periodization, consistency sections"
```

---

### Task 41: iOS Cleanup (Phase 7)

**Files:**
- Modify: Various iOS files (see steps below)

- [ ] **Step 0: Coordinated rename — all layers switch simultaneously**

This rename must be atomic across all layers to prevent data visibility gaps.
Deploy order: Firebase Functions first (proxy + rules), then agent service, then iOS.

**Backend changes (deploy together):**
- SSE proxy `stream-agent-normalized.js`: change `CONVERSATION_COLLECTION` from `'canvases'` to `'conversations'`
- Firestore rules: rename `canvases` match to `conversations`
- Agent service: set env var `CONVERSATION_COLLECTION=conversations` in Cloud Run

**Then iOS build + deploy.**

- [ ] **Step 1: Rename `canvases` → `conversations` in Firestore collection paths**

These 5 files have hardcoded `"canvases"` Firestore collection paths:

| File | Lines | Change |
|------|-------|--------|
| `CanvasRepository.swift` | 70, 94, 124, 146 | Replace `"canvases"` → `"conversations"` |
| `CanvasViewModel.swift` | 802, 821, 905 | Replace `"canvases"` → `"conversations"` |
| `CoachTabView.swift` | 250, 262, 268, 279 | Replace `"canvases"` → `"conversations"` |
| `AllConversationsSheet.swift` | 187, 217 | Replace `"canvases"` → `"conversations"` |
| `UserRepository.swift` | 92 | Replace `"canvases"` → `"conversations"` |

```bash
# Verify all references found:
grep -rn '"canvases"' Povver/Povver/ --include="*.swift" | grep -v ".build/"
```

Build after:
```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

- [ ] **Step 2: Update Firestore security rules**

In `firestore.rules`, rename `canvases` match rules to `conversations`:
```
match /users/{userId}/conversations/{conversationId} {
  // Same rules as canvases — admin-only write
}
```

- [ ] **Step 3: Rename iOS classes**

Rename files and all internal references. Build after each rename.

| From | To |
|------|----|
| `CanvasViewModel.swift` | `ConversationViewModel.swift` |
| `CanvasService.swift` | `ConversationService.swift` |
| `CanvasRepository.swift` | `ConversationRepository.swift` |
| `CanvasDTOs.swift` | `ConversationDTOs.swift` |
| `CanvasActions.swift` | `ConversationActions.swift` |
| `CanvasScreen.swift` | `ConversationScreen.swift` |

Also rename variables: `recentCanvases` → `recentConversations` in `CoachTabView.swift`.

```bash
# Verify no remaining Canvas references (except ARCHITECTURE docs):
grep -rn "Canvas" Povver/Povver/ --include="*.swift" | grep -v ".build/" | grep -v "ARCHITECTURE" | grep -v "//.*deprecated"
```

- [ ] **Step 4: Update StreamEvent.swift to 9-event contract**

Replace the 15-type `EventType` enum with 9 types:

```swift
enum EventType: String {
    case message
    case toolStart = "tool_start"
    case toolEnd = "tool_end"
    case artifact
    case clarification
    case status
    case heartbeat
    case done
    case error
}
```

Dropped types (no longer emitted by the new agent service):
- `thinking`, `thought` — ADK thinking indicators
- `toolRunning`, `toolComplete` — renamed to `tool_start`/`tool_end`
- `agentResponse` / `agent_response` — redundant with `message`
- `userPrompt`, `userResponse` — echo events
- `pipeline` — ADK pipeline state
- `card` — replaced by `artifact`

Update `handleIncomingStreamEvent` in `ConversationViewModel` for new event names:
- `toolRunning` handling → `toolStart`
- `toolComplete` handling → `toolEnd`
- `clarificationRequest` handling → `clarification`

- [ ] **Step 4b: Update or remove ThinkingProcessState**

`ThinkingProcessState` is currently driven by `pipeline` events (which are no longer emitted). Replace with a simpler progress indicator based on `tool_start`/`tool_end` events. If the UI shows a "thinking" animation, drive it from `tool_start` (start) and `tool_end` (stop) events instead.

- [ ] **Step 4c: Switch workspace_entries → messages listener**

In `ConversationViewModel`, replace the Firestore listener on `workspace_entries` subcollection with a listener on `messages` subcollection. The `messages` collection uses `type` field (values: `user_prompt`, `agent_response`, `artifact`) and `created_at` instead of `timestamp`.

- [ ] **Step 5: Remove DirectStreamingService backward compat**

In `DirectStreamingService.swift`, remove:
- `canvasId` field from request body (only send `conversationId`)
- Any `sessionId` parameter
- The `getServiceToken` call site

- [ ] **Step 5b: Remove no-op stub callers from iOS**

Remove calls to these endpoints (they were kept as no-op stubs in Phase 3c, now deleted from backend):
- `CanvasService.openCanvas()` → remove caller
- `CanvasService.bootstrapCanvas()` → remove caller
- `CanvasService.preWarmSession()` → remove caller
- `CanvasService.initializeSession()` → remove caller

- [ ] **Step 5c: Remove no-op stubs and EVENT_COMPAT from backend**

In `firebase_functions/functions/index.js`:
- Remove `openCanvas`, `bootstrapCanvas`, `initializeSession`, `preWarmSession` no-op stub exports

In `firebase_functions/functions/strengthos/stream-agent-normalized.js`:
- Remove the `EVENT_COMPAT` translation table (agent events now match iOS expectations directly)

- [ ] **Step 6: Split FocusModeWorkoutScreen.swift** (~1904 lines)

Extract into focused files. Build after each extraction:

- `FocusModeExerciseSection.swift` — exercise list section
- `FocusModeSetRow.swift` — individual set row view
- `FocusModeRestTimer.swift` — rest timer overlay
- `FocusModeWorkoutScreen.swift` — retains: main layout, navigation, state

- [ ] **Step 7: Remove any remaining dead code**

```bash
grep -rn "agent_sessions\|AGENT_VERSION\|SessionPreWarmer\|preWarmSession\|CanvasRepository\|getServiceToken\|openCanvas\|bootstrapCanvas\|initializeSession" Povver/Povver/ --include="*.swift" | grep -v ".build/"
```

Remove any matches that survived Phase 3c.

- [ ] **Step 8: Update ARCHITECTURE.md files**

Update the 4 iOS ARCHITECTURE.md files that reference "canvases":
- `Povver/Povver/Models/ARCHITECTURE.md`
- `Povver/Povver/Repositories/ARCHITECTURE.md`
- `Povver/Povver/Views/Coach/ARCHITECTURE.md`
- `Povver/Povver/Services/ARCHITECTURE.md` (if exists)

- [ ] **Step 9: Build to verify**

```bash
xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

- [ ] **Step 10: Commit**

```bash
git add Povver/ firestore.rules
git commit -m "refactor: Phase 7 — canvases→conversations, 9-event SSE, full cleanup

iOS:
- Renamed 'canvases' to 'conversations' in all Firestore paths (5 files)
- Renamed 6 Canvas* classes to Conversation* classes
- Updated StreamEvent.swift: 15 types → 9 (dropped ADK legacy types)
- Replaced ThinkingProcessState with tool_start/tool_end progress
- Switched workspace_entries listener → messages listener
- Removed DirectStreamingService backward compat (canvasId, sessionId)
- Removed no-op stub callers (openCanvas, bootstrapCanvas, etc.)
- Split FocusModeWorkoutScreen (1904 lines → 4 focused files)

Backend:
- Removed no-op stubs from index.js (openCanvas, bootstrapCanvas, etc.)
- Removed EVENT_COMPAT translation table from SSE proxy
- Updated Firestore security rules: canvases → conversations"
```

---

### Task 42: Final Documentation Update

**Files:**
- Modify: `docs/SYSTEM_ARCHITECTURE.md`
- Modify: `docs/FIREBASE_FUNCTIONS_ARCHITECTURE.md`
- Modify: `docs/SHELL_AGENT_ARCHITECTURE.md`
- Modify: `docs/IOS_ARCHITECTURE.md`
- Modify: `docs/FIRESTORE_SCHEMA.md`
- Create: `docs/MCP_SERVER_ARCHITECTURE.md`

- [ ] **Step 1: Update SYSTEM_ARCHITECTURE.md**

Add: shared business logic layer, Cloud Run agent service, MCP server, workout completion worker. Update architecture diagrams. Remove Vertex AI Agent Engine references.

- [ ] **Step 2: Update FIREBASE_FUNCTIONS_ARCHITECTURE.md**

Document shared/ modules, thin handler pattern, simplified triggers.

- [ ] **Step 3: Update SHELL_AGENT_ARCHITECTURE.md**

Rename or replace with `AGENT_SERVICE_ARCHITECTURE.md`. Document: Cloud Run deployment, LLM client abstraction, agent loop, memory system, 4-lane router, observability.

- [ ] **Step 4: Update IOS_ARCHITECTURE.md**

Remove session pre-warming, update streaming service docs.

- [ ] **Step 5: Update FIRESTORE_SCHEMA.md**

Add new collections and fields:
- `agent_memory/{auto-id}` — fields: `content`, `category`, `active`, `created_at`, `source_conversation_id`, `retired_at`, `retire_reason`
- `mcp_api_keys/{key_hash}` — fields: `user_id`, `name`, `created_at`, `last_used_at`, `scopes`
- Conversation fields: `summary`, `completed_at`, `session_vars`, `last_message_at`
- `conversations/{id}/messages` — fields: `type` (user_prompt/agent_response/artifact), `content`, `created_at`
- `conversations/{id}/artifacts` — fields: `artifact_type`, `artifact_content`, `actions`, `status`, `created_at`
- Composite index: `agent_memory(active ASC, created_at DESC)`

Mark as removed:
- `agent_sessions` — replaced by stateless agent service
- `canvases` — renamed to `conversations`
- `workout_completion_jobs` — replaced by Cloud Tasks queue (AD-1)

Document that the canonical Firestore collection name is `conversations` (not `canvases`).

- [ ] **Step 5b: Update CLAUDE.md**

Update the Task Startup Sequence to reference `AGENT_SERVICE_ARCHITECTURE.md` instead of `SHELL_AGENT_ARCHITECTURE.md`. Update the Build & Development Commands section with the new `adk_agent/agent_service` commands. Add `mcp_server/` commands. Update the Deprecated section to add: Vertex AI Agent Engine, ADK framework, `getServiceToken`, `invokeCanvasOrchestrator`, `openCanvas`/`bootstrapCanvas`/`initializeSession`/`preWarmSession`, `cleanupStaleSessions`/`expireProposalsScheduled`, `canvases` collection name (now `conversations`).

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "docs: update all architecture docs for redesigned system"
```

---

### Task 43: Deferred Scaling Configuration (Reference)

This task is NOT implemented now — it documents what to configure when revenue justifies monthly costs.

**When ready:**
- `minInstances: 1` on hot-path Firebase Functions (SSE proxy, log-set, get-active-workout)
- `maxInstances` increase on SSE proxy (20 → 50+)
- Cloud Run agent service: `min-instances: 1` to eliminate cold starts
- Cloud Run MCP server: `min-instances: 1` if usage justifies
- Consider Redis for rate limiting if Firestore-based limiting becomes a bottleneck

No commit needed — this is a reference note in the plan.
