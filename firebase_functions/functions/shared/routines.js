/**
 * =============================================================================
 * shared/routines.js - Pure business logic for routine operations
 * =============================================================================
 *
 * Every function takes (db, userId, ...args) where db is a Firestore instance.
 * No req/res/auth — HTTP handlers are thin wrappers that call these.
 *
 * Throws:
 * - ValidationError for bad input
 * - NotFoundError when a document doesn't exist
 * - Raw Firestore errors bubble up (handlers catch and map to 500)
 * =============================================================================
 */

const admin = require('firebase-admin');
const { ValidationError, NotFoundError } = require('./errors');
const { RoutineSchema } = require('../utils/validators');
const { formatValidationResponse } = require('../utils/validation-response');

// ---------------------------------------------------------------------------
// getRoutine
// ---------------------------------------------------------------------------

/**
 * Get a single routine by ID, enriched with is_active.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} routineId
 * @param {Object} [opts={}] - Options
 * @param {boolean} [opts.include_templates] - When true, inline template summaries
 * @returns {Object} routine document with is_active flag
 */
async function getRoutine(db, userId, routineId, opts = {}) {
  if (!routineId) {
    throw new ValidationError('Missing required parameters', ['routineId']);
  }

  const [routineSnap, userSnap] = await Promise.all([
    db.collection('users').doc(userId).collection('routines').doc(routineId).get(),
    db.collection('users').doc(userId).get(),
  ]);

  if (!routineSnap.exists) {
    throw new NotFoundError('Routine not found');
  }

  const routine = { id: routineSnap.id, ...routineSnap.data() };
  const activeRoutineId = userSnap.exists ? userSnap.data().activeRoutineId : null;
  routine.is_active = routine.id === activeRoutineId;

  // Optional: include inline template summaries
  if (opts.include_templates) {
    const templateIds = routine.template_ids || [];
    if (templateIds.length > 0) {
      const templatesCol = db.collection('users').doc(userId).collection('templates');
      const templateRefs = templateIds.map(tid => templatesCol.doc(tid));
      const templateDocs = await db.getAll(...templateRefs);

      routine.templates = templateDocs
        .filter(d => d.exists)
        .map((d) => {
          const t = d.data();
          return {
            id: d.id,
            name: t.name || 'Untitled',
            position: templateIds.indexOf(d.id),
            exercise_names: (t.exercises || []).map(ex => ex.name || ex.exercise_id || 'Unknown'),
            exercise_count: (t.exercises || []).length,
          };
        });
    } else {
      routine.templates = [];
    }
  }

  return routine;
}

// ---------------------------------------------------------------------------
// listRoutines
// ---------------------------------------------------------------------------

/**
 * List all routines for a user, each enriched with is_active.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @returns {{ items: Object[], count: number }}
 */
async function listRoutines(db, userId) {
  const [routinesSnap, userSnap] = await Promise.all([
    db.collection('users').doc(userId).collection('routines').limit(500).get(),
    db.collection('users').doc(userId).get(),
  ]);

  const activeRoutineId = userSnap.exists ? userSnap.data().activeRoutineId : null;
  const items = routinesSnap.docs.map(doc => ({
    id: doc.id,
    ...doc.data(),
    is_active: doc.id === activeRoutineId,
  }));

  return { items, count: items.length };
}

// ---------------------------------------------------------------------------
// createRoutine
// ---------------------------------------------------------------------------

/**
 * Create a new routine, validating template_ids exist.
 * Auto-activates if user has no active routine.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {Object} routineInput - Raw routine payload (validated via RoutineSchema)
 * @returns {{ routine: Object, routineId: string, activated: boolean }}
 */
async function createRoutine(db, userId, routineInput) {
  if (!userId) {
    throw new ValidationError('Missing userId');
  }

  const parsed = RoutineSchema.safeParse(routineInput);
  if (!parsed.success) {
    const details = formatValidationResponse(routineInput, parsed.error.errors, null);
    throw new ValidationError('Invalid routine data', details);
  }

  // Collect template IDs from either format
  const templateIds = routineInput.template_ids || routineInput.templateIds || [];

  // Declare outside the if-block so it's always available for enhancedRoutine
  let templateNames = {};

  // Validate all template_ids exist
  if (templateIds.length > 0) {
    const templatesCol = db.collection('users').doc(userId).collection('templates');
    const templateRefs = templateIds.map(tid => templatesCol.doc(tid));
    const templateDocs = await db.getAll(...templateRefs);

    const missingIds = [];
    templateDocs.forEach((doc, idx) => {
      if (!doc.exists) {
        missingIds.push(templateIds[idx]);
      }
    });

    if (missingIds.length > 0) {
      throw new ValidationError('Templates not found', {
        missing_template_ids: missingIds,
        hint: `Templates [${missingIds.join(', ')}] do not exist. Create templates first using tool_save_workout_as_template, or use tool_propose_routine which creates templates automatically when user saves.`,
        retryable: true,
        recovery_options: [
          'Create the missing templates first',
          'Use tool_propose_routine instead (recommended)',
          'Remove the invalid template_ids from the request',
        ],
      });
    }

    // Extract template names from already-fetched docs (no additional reads)
    templateDocs.forEach((doc, idx) => {
      if (doc.exists) {
        const data = doc.data();
        templateNames[templateIds[idx]] = data.name || 'Untitled';
      }
    });
  }

  const now = admin.firestore.FieldValue.serverTimestamp();
  const enhancedRoutine = {
    ...routineInput,
    frequency: routineInput.frequency || 3,
    template_ids: templateIds,
    template_names: templateNames,
    created_at: now,
    updated_at: now,
  };
  // Remove camelCase version if it exists
  delete enhancedRoutine.templateIds;

  // Create the routine document
  const routineRef = db.collection('users').doc(userId).collection('routines').doc();
  await routineRef.set(enhancedRoutine);

  // Write the id field into the document
  const routineId = routineRef.id;
  await routineRef.update({ id: routineId });

  // Auto-activate if user has no active routine
  // Note: Non-atomic read-then-write — preserved from original handler.
  // A concurrent routine create could race here, but the impact is benign
  // (worst case: a different routine becomes active). Not worth the transaction
  // overhead given routine creation is infrequent and user-initiated.
  const userDoc = await db.collection('users').doc(userId).get();
  const hasActiveRoutine = userDoc.exists && userDoc.data().activeRoutineId;
  if (!hasActiveRoutine) {
    await db.collection('users').doc(userId).update({ activeRoutineId: routineId });
  }

  // Fetch created routine for response
  const createdSnap = await routineRef.get();
  const createdRoutine = { id: createdSnap.id, ...createdSnap.data() };

  return { routine: createdRoutine, routineId, activated: !hasActiveRoutine };
}

// ---------------------------------------------------------------------------
// patchRoutine
// ---------------------------------------------------------------------------

/**
 * Patch a routine with a narrow set of allowed fields.
 * Validates template_ids exist. Clears cursor if the last-completed template
 * is removed from template_ids.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} routineId
 * @param {Object} patch - Patch object with allowed fields
 * @returns {{ routineId: string, patchedFields: string[], cursorCleared: boolean, message: string }}
 */
async function patchRoutine(db, userId, routineId, patch) {
  if (!routineId) {
    throw new ValidationError('Missing routineId');
  }
  if (!patch || typeof patch !== 'object') {
    throw new ValidationError('Missing or invalid patch object');
  }

  const routineRef = db.collection('users').doc(userId).collection('routines').doc(routineId);
  const routineDoc = await routineRef.get();

  if (!routineDoc.exists) {
    throw new NotFoundError('Routine not found');
  }

  const current = routineDoc.data();

  // Allowed patch fields
  const ALLOWED_FIELDS = ['name', 'description', 'frequency', 'template_ids'];
  const sanitizedPatch = {};
  const patchedFields = [];

  for (const field of ALLOWED_FIELDS) {
    if (patch[field] !== undefined) {
      sanitizedPatch[field] = patch[field];
      patchedFields.push(field);
    }
  }

  if (patchedFields.length === 0) {
    throw new ValidationError('No valid fields to patch. Allowed: name, description, frequency, template_ids');
  }

  // Validate name if provided
  if (sanitizedPatch.name !== undefined) {
    if (typeof sanitizedPatch.name !== 'string' || sanitizedPatch.name.trim().length === 0) {
      throw new ValidationError('name must be a non-empty string');
    }
    sanitizedPatch.name = sanitizedPatch.name.trim();
  }

  // Validate frequency if provided
  if (sanitizedPatch.frequency !== undefined) {
    if (typeof sanitizedPatch.frequency !== 'number' || sanitizedPatch.frequency < 1 || sanitizedPatch.frequency > 7) {
      throw new ValidationError('frequency must be a number between 1 and 7');
    }
  }

  // Validate template_ids if provided
  if (sanitizedPatch.template_ids !== undefined) {
    if (!Array.isArray(sanitizedPatch.template_ids)) {
      throw new ValidationError('template_ids must be an array');
    }

    // Validate all templates exist and collect names
    if (sanitizedPatch.template_ids.length === 0) {
      sanitizedPatch.template_names = {};
      // Clear dangling cursor when all templates removed
      if (current.last_completed_template_id) {
        sanitizedPatch.last_completed_template_id = null;
        sanitizedPatch.last_completed_at = null;
        patchedFields.push('last_completed_template_id', 'last_completed_at');
      }
    } else {
      const templatesCol = db.collection('users').doc(userId).collection('templates');
      const templateRefs = sanitizedPatch.template_ids.map(tid => templatesCol.doc(tid));
      const templateDocs = await db.getAll(...templateRefs);

      const missing = [];
      const templateNames = {};
      templateDocs.forEach((doc, idx) => {
        const tid = sanitizedPatch.template_ids[idx];
        if (!doc.exists) {
          missing.push(tid);
        } else {
          templateNames[tid] = doc.data().name || 'Untitled';
        }
      });

      if (missing.length > 0) {
        throw new ValidationError(`Templates not found: ${missing.join(', ')}`);
      }

      sanitizedPatch.template_names = templateNames;

      // Cursor consistency: clear if last_completed_template_id is no longer in template_ids
      const currentCursorId = current.last_completed_template_id;
      if (currentCursorId && !sanitizedPatch.template_ids.includes(currentCursorId)) {
        sanitizedPatch.last_completed_template_id = null;
        sanitizedPatch.last_completed_at = null;
        patchedFields.push('last_completed_template_id', 'last_completed_at');
      }
    }
  }

  // Add timestamp
  sanitizedPatch.updated_at = admin.firestore.FieldValue.serverTimestamp();

  // Apply patch
  await routineRef.update(sanitizedPatch);

  return {
    routineId,
    patchedFields,
    cursorCleared: sanitizedPatch.last_completed_template_id === null,
    message: 'Routine updated successfully',
  };
}

// ---------------------------------------------------------------------------
// deleteRoutine
// ---------------------------------------------------------------------------

/**
 * Delete a routine. Clears activeRoutineId if this was the active routine.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} routineId
 * @returns {{ message: string, routineId: string, activeRoutineCleared: boolean }}
 */
async function deleteRoutine(db, userId, routineId) {
  if (!userId || !routineId) {
    throw new ValidationError('Missing required parameters', ['userId', 'routineId']);
  }

  const routineRef = db.collection('users').doc(userId).collection('routines').doc(routineId);
  const routineSnap = await routineRef.get();
  if (!routineSnap.exists) {
    throw new NotFoundError('Routine not found');
  }

  // Check if this is the active routine and clear it
  // Note: Non-atomic read-then-write — preserved from original handler.
  // Benign race: concurrent delete + set-active could leave stale pointer,
  // but set-active always validates routine existence first.
  const userRef = db.collection('users').doc(userId);
  const userSnap = await userRef.get();
  const user = userSnap.exists ? { id: userSnap.id, ...userSnap.data() } : null;
  const wasActive = user?.activeRoutineId === routineId;

  if (wasActive) {
    await userRef.update({
      activeRoutineId: null,
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  await routineRef.delete();

  return { message: 'Routine deleted', routineId, activeRoutineCleared: wasActive };
}

// ---------------------------------------------------------------------------
// getActiveRoutine
// ---------------------------------------------------------------------------

/**
 * Get the active routine for a user.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @returns {{ routine: Object|null, message?: string }}
 */
async function getActiveRoutine(db, userId) {
  const userSnap = await db.collection('users').doc(userId).get();
  if (!userSnap.exists) {
    throw new NotFoundError('User not found');
  }

  const user = userSnap.data();
  if (!user.activeRoutineId) {
    return { routine: null, message: 'No active routine set' };
  }

  const routineSnap = await db.collection('users').doc(userId)
    .collection('routines').doc(user.activeRoutineId).get();

  const routine = routineSnap.exists ? { id: routineSnap.id, ...routineSnap.data() } : null;
  return { routine };
}

// ---------------------------------------------------------------------------
// setActiveRoutine
// ---------------------------------------------------------------------------

/**
 * Set the active routine for a user.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} routineId
 * @returns {{ message: string, routineId: string, routine: Object }}
 */
async function setActiveRoutine(db, userId, routineId) {
  if (!userId || !routineId) {
    throw new ValidationError('Missing required parameters', ['userId', 'routineId']);
  }

  const routineSnap = await db.collection('users').doc(userId)
    .collection('routines').doc(routineId).get();

  if (!routineSnap.exists) {
    throw new NotFoundError('Routine not found');
  }

  const routine = { id: routineSnap.id, ...routineSnap.data() };

  // Update user's active routine (upsert to handle missing user doc)
  const userRef = db.collection('users').doc(userId);
  const userSnap = await userRef.get();
  const now = admin.firestore.FieldValue.serverTimestamp();
  const payload = { activeRoutineId: routineId, updated_at: now };
  if (!userSnap.exists) {
    payload.created_at = now;
  }
  await userRef.set(payload, { merge: true });

  return { message: 'Active routine set', routineId, routine };
}

// ---------------------------------------------------------------------------
// getNextWorkout
// ---------------------------------------------------------------------------

/**
 * Determine the next template in the routine rotation.
 *
 * Selection methods (in priority order):
 * 1. cursor — O(1) via routine.last_completed_template_id
 * 2. history_scan — O(N) fallback scanning last 50 workouts
 * 3. default_first — no history, start with first template
 * 4. fallback_first_available — referenced template missing, use first valid
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @returns {Object} { template, routine, templateIndex, templateCount, selectionMethod, ... }
 */
async function getNextWorkout(db, userId) {
  // 1. Get user and check for active routine
  const userSnap = await db.collection('users').doc(userId).get();

  if (!userSnap.exists || !userSnap.data().activeRoutineId) {
    return {
      template: null,
      routine: null,
      reason: 'no_active_routine',
      message: 'No active routine set',
    };
  }

  const activeRoutineId = userSnap.data().activeRoutineId;

  // 2. Get the active routine
  const routineSnap = await db.collection('users').doc(userId)
    .collection('routines').doc(activeRoutineId).get();

  if (!routineSnap.exists) {
    return {
      template: null,
      routine: null,
      reason: 'routine_not_found',
      message: 'Active routine not found',
    };
  }

  const routine = { id: routineSnap.id, ...routineSnap.data() };

  // Canonical field is template_ids, fallback to templateIds for legacy
  const templateIds = routine.template_ids || routine.templateIds || [];
  if (templateIds.length === 0) {
    return {
      template: null,
      routine,
      reason: 'empty_routine',
      message: 'Routine has no templates',
    };
  }

  // 3. Determine next template using cursor or fallback
  let nextTemplateId;
  let nextTemplateIndex;
  let selectionMethod;

  // Primary: Use cursor field if available
  if (routine.last_completed_template_id && templateIds.includes(routine.last_completed_template_id)) {
    const lastIndex = templateIds.indexOf(routine.last_completed_template_id);
    nextTemplateIndex = (lastIndex + 1) % templateIds.length;
    nextTemplateId = templateIds[nextTemplateIndex];
    selectionMethod = 'cursor';
  } else {
    // Fallback: Scan last N workouts
    const N = 50;
    const workoutsSnap = await db.collection('users').doc(userId).collection('workouts')
      .orderBy('end_time', 'desc')
      .limit(N)
      .get();

    const templateSet = new Set(templateIds);
    let lastMatchingWorkout = null;
    for (const doc of workoutsSnap.docs) {
      const w = doc.data();
      if (w.source_template_id && templateSet.has(w.source_template_id)) {
        lastMatchingWorkout = w;
        break;
      }
    }

    if (lastMatchingWorkout) {
      const lastIndex = templateIds.indexOf(lastMatchingWorkout.source_template_id);
      if (lastIndex >= 0) {
        nextTemplateIndex = (lastIndex + 1) % templateIds.length;
        nextTemplateId = templateIds[nextTemplateIndex];
        selectionMethod = 'history_scan';
      }
    }

    // If still no match, start at first template
    if (!nextTemplateId) {
      nextTemplateIndex = 0;
      nextTemplateId = templateIds[0];
      selectionMethod = 'default_first';
    }
  }

  // 4. Fetch the next template
  const templateSnap = await db.collection('users').doc(userId)
    .collection('templates').doc(nextTemplateId).get();

  if (!templateSnap.exists) {
    // Template referenced in routine doesn't exist — fall back to first available
    for (let i = 0; i < templateIds.length; i++) {
      const fallbackSnap = await db.collection('users').doc(userId)
        .collection('templates').doc(templateIds[i]).get();
      if (fallbackSnap.exists) {
        return {
          template: { id: fallbackSnap.id, ...fallbackSnap.data() },
          routine,
          templateIndex: i,
          templateCount: templateIds.length,
          selectionMethod: 'fallback_first_available',
          warning: `Original next template ${nextTemplateId} not found`,
        };
      }
    }
    return {
      template: null,
      routine,
      reason: 'no_valid_templates',
      message: 'None of the routine templates exist',
    };
  }

  return {
    template: { id: templateSnap.id, ...templateSnap.data() },
    routine,
    templateIndex: nextTemplateIndex,
    templateCount: templateIds.length,
    selectionMethod,
  };
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
};
