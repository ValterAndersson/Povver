/**
 * =============================================================================
 * shared/templates.js - Pure business logic for template operations
 * =============================================================================
 *
 * Extracted from templates/*.js handlers. Every function takes (db, userId, ...)
 * where db is a Firestore instance (admin.firestore()). No req/res, no auth.
 *
 * Throws ValidationError / NotFoundError / PermissionDeniedError / ConflictError
 * from shared/errors.js — handlers catch and map to HTTP responses.
 *
 * CALLED BY:
 * - templates/get-template.js
 * - templates/get-user-templates.js
 * - templates/create-template.js
 * - templates/patch-template.js
 * - templates/delete-template.js
 * - templates/create-template-from-plan.js
 * =============================================================================
 */

const admin = require('firebase-admin');
const { TemplateSchema } = require('../utils/validators');
const { convertPlanBlocksToTemplateExercises, validatePlanContent } = require('../utils/plan-to-template-converter');
const { ValidationError, NotFoundError, PermissionDeniedError, ConflictError } = require('./errors');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Firestore reference for a user's template subcollection */
function templateRef(db, userId, templateId) {
  return db.collection('users').doc(userId).collection('templates').doc(templateId);
}

function templatesCol(db, userId) {
  return db.collection('users').doc(userId).collection('templates');
}

/**
 * Resolve exercise names from the master catalog.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string[]} exerciseIds
 * @returns {Promise<Object>} Map of exercise_id -> name
 */
async function resolveExerciseNames(db, exerciseIds) {
  const names = {};
  await Promise.all(exerciseIds.map(async (exerciseId) => {
    const doc = await db.collection('exercises').doc(exerciseId).get();
    if (doc.exists) {
      names[exerciseId] = doc.data().name || exerciseId;
    }
  }));
  return names;
}

// ---------------------------------------------------------------------------
// getTemplate
// ---------------------------------------------------------------------------

/**
 * Get a single template by ID, resolving exercise names from the catalog.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} templateId
 * @returns {Promise<Object>} The template document with exercise names resolved
 * @throws {ValidationError} if templateId is missing
 * @throws {NotFoundError} if template does not exist
 */
async function getTemplate(db, userId, templateId) {
  if (!templateId) throw new ValidationError('Missing templateId parameter');

  const doc = await templateRef(db, userId, templateId).get();
  if (!doc.exists) throw new NotFoundError('Template not found');

  const template = { id: doc.id, ...doc.data() };

  // Resolve exercise names from master catalog when missing
  if (Array.isArray(template.exercises)) {
    const idsToResolve = template.exercises
      .filter(ex => !ex.name && ex.exercise_id)
      .map(ex => ex.exercise_id);

    if (idsToResolve.length > 0) {
      const exerciseNames = await resolveExerciseNames(db, idsToResolve);
      template.exercises = template.exercises.map(ex => {
        if (!ex.name && ex.exercise_id && exerciseNames[ex.exercise_id]) {
          return { ...ex, name: exerciseNames[ex.exercise_id] };
        }
        return ex;
      });
    }
  }

  return template;
}

// ---------------------------------------------------------------------------
// listTemplates
// ---------------------------------------------------------------------------

/**
 * List all templates for a user.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @returns {Promise<{items: Object[], count: number}>}
 */
async function listTemplates(db, userId) {
  const snapshot = await templatesCol(db, userId).limit(500).get();
  const items = snapshot.docs.map(doc => ({ id: doc.id, ...doc.data() }));
  return { items, count: items.length };
}

// ---------------------------------------------------------------------------
// createTemplate
// ---------------------------------------------------------------------------

/**
 * Create a new template.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {Object} templateData - Raw template payload (validated via TemplateSchema)
 * @param {Object} [options] - Optional: { calculateAnalytics: fn, isAgentSource: bool }
 * @returns {Promise<{template: Object, templateId: string}>}
 * @throws {ValidationError} if template data fails Zod validation
 */
async function createTemplate(db, userId, templateData, options = {}) {
  const parsed = TemplateSchema.safeParse(templateData);
  if (!parsed.success) {
    throw new ValidationError('Invalid template data', parsed.error.flatten());
  }

  const col = templatesCol(db, userId);
  const docRef = await col.add({
    ...templateData,
    created_at: admin.firestore.FieldValue.serverTimestamp(),
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });
  const templateId = docRef.id;

  // Store the doc ID as a field for consistency
  await docRef.update({ id: templateId });

  // Read back the created template
  const createdDoc = await docRef.get();
  const createdTemplate = { id: createdDoc.id, ...createdDoc.data() };

  // Calculate analytics for agent-created templates if callback provided
  if (options.calculateAnalytics && options.isAgentSource) {
    try {
      const analytics = await options.calculateAnalytics(createdTemplate);
      await docRef.update({ analytics });
      createdTemplate.analytics = analytics;
    } catch (analyticsError) {
      // Non-fatal: continue without analytics
      console.error('Error calculating analytics:', analyticsError);
    }
  }

  return { template: createdTemplate, templateId };
}

// ---------------------------------------------------------------------------
// patchTemplate
// ---------------------------------------------------------------------------

/**
 * Patch a template with a narrow set of allowed fields.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} templateId
 * @param {Object} patch - Patch object (allowed: name, description, exercises)
 * @param {Object} [meta] - Optional: { change_source, recommendation_id, workout_id }
 * @returns {Promise<Object>} Result with templateId, patchedFields, analyticsWillRecompute
 * @throws {ValidationError} if patch is invalid
 * @throws {NotFoundError} if template does not exist
 * @throws {ConflictError} if concurrent modification detected
 */
async function patchTemplate(db, userId, templateId, patch, meta = {}) {
  if (!templateId) throw new ValidationError('Missing templateId');
  if (!patch || typeof patch !== 'object') {
    throw new ValidationError('Missing or invalid patch object');
  }

  const ref = templateRef(db, userId, templateId);
  const doc = await ref.get();
  if (!doc.exists) throw new NotFoundError('Template not found');

  const current = doc.data();

  // Optional concurrency check
  if (patch.expected_updated_at) {
    const currentUpdatedAt = current.updated_at?.toMillis?.() || 0;
    const expectedUpdatedAt = typeof patch.expected_updated_at === 'number'
      ? patch.expected_updated_at
      : new Date(patch.expected_updated_at).getTime();

    if (currentUpdatedAt !== expectedUpdatedAt) {
      throw new ConflictError(
        'Template was modified concurrently. Please refresh and try again.',
        { current_updated_at: currentUpdatedAt, expected_updated_at: expectedUpdatedAt }
      );
    }
  }

  // Filter to allowed fields
  const ALLOWED_FIELDS = ['name', 'description', 'exercises'];
  const sanitizedPatch = {};
  const patchedFields = [];

  for (const field of ALLOWED_FIELDS) {
    if (patch[field] !== undefined) {
      sanitizedPatch[field] = patch[field];
      patchedFields.push(field);
    }
  }

  if (patchedFields.length === 0) {
    throw new ValidationError('No valid fields to patch. Allowed: name, description, exercises');
  }

  // Validate name if provided
  if (sanitizedPatch.name !== undefined) {
    if (typeof sanitizedPatch.name !== 'string' || sanitizedPatch.name.trim().length === 0) {
      throw new ValidationError('name must be a non-empty string');
    }
    sanitizedPatch.name = sanitizedPatch.name.trim();
  }

  // Validate exercises if provided
  let exercisesChanged = false;
  if (sanitizedPatch.exercises !== undefined) {
    if (!Array.isArray(sanitizedPatch.exercises)) {
      throw new ValidationError('exercises must be an array');
    }
    if (sanitizedPatch.exercises.length === 0) {
      throw new ValidationError('exercises array cannot be empty');
    }

    for (let i = 0; i < sanitizedPatch.exercises.length; i++) {
      const exercise = sanitizedPatch.exercises[i];
      if (!exercise.exercise_id && !exercise.exerciseId) {
        throw new ValidationError(`Exercise at index ${i} missing exercise_id`);
      }
      if (!Array.isArray(exercise.sets)) {
        throw new ValidationError(`Exercise at index ${i} missing sets array`);
      }
      for (let j = 0; j < exercise.sets.length; j++) {
        const set = exercise.sets[j];
        if (typeof set.reps !== 'number') {
          throw new ValidationError(`Exercise ${i} set ${j} missing reps`);
        }
        if (set.rir !== null && set.rir !== undefined && typeof set.rir !== 'number') {
          throw new ValidationError(`Exercise ${i} set ${j} rir must be number or null`);
        }
        if (set.weight !== null && set.weight !== undefined && typeof set.weight !== 'number') {
          throw new ValidationError(`Exercise ${i} set ${j} weight must be number or null`);
        }
      }
    }

    exercisesChanged = JSON.stringify(sanitizedPatch.exercises) !== JSON.stringify(current.exercises);
  }

  // Add timestamp
  sanitizedPatch.updated_at = admin.firestore.FieldValue.serverTimestamp();

  // Clear analytics so trigger will recompute
  if (exercisesChanged) {
    sanitizedPatch.analytics = admin.firestore.FieldValue.delete();
  }

  // Build changelog entry
  const changesSummary = [];
  if (exercisesChanged) {
    const currentExIds = (current.exercises || []).map(e => e.exercise_id);
    const newExIds = (sanitizedPatch.exercises || []).map(e => e.exercise_id);
    const added = newExIds.filter(id => !currentExIds.includes(id));
    const removed = currentExIds.filter(id => !newExIds.includes(id));

    if (added.length > 0 && removed.length > 0) {
      changesSummary.push({ field: 'exercises.swap', operation: 'swap', summary: `Swapped ${removed.length} exercise(s)` });
    } else {
      if (added.length > 0) changesSummary.push({ field: 'exercises', operation: 'add', summary: `Added ${added.length} exercise(s)` });
      if (removed.length > 0) changesSummary.push({ field: 'exercises', operation: 'remove', summary: `Removed ${removed.length} exercise(s)` });
    }
    if (JSON.stringify(newExIds.filter(id => currentExIds.includes(id))) !== JSON.stringify(currentExIds.filter(id => newExIds.includes(id)))) {
      changesSummary.push({ field: 'exercises', operation: 'reorder', summary: 'Reordered exercises' });
    }
    if (changesSummary.length === 0) {
      changesSummary.push({ field: 'exercises', operation: 'update', summary: 'Updated exercise sets' });
    }
  }
  if (sanitizedPatch.name !== undefined) {
    changesSummary.push({ field: 'name', operation: 'update', summary: `Renamed to "${sanitizedPatch.name}"` });
  }
  if (sanitizedPatch.description !== undefined) {
    changesSummary.push({ field: 'description', operation: 'update', summary: 'Updated description' });
  }

  // Batched write: template update + changelog entry
  const batch = db.batch();
  batch.update(ref, sanitizedPatch);

  const changelogRef = ref.collection('changelog').doc();
  batch.set(changelogRef, {
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    source: meta.change_source || 'user_edit',
    workout_id: meta.workout_id || null,
    recommendation_id: meta.recommendation_id || null,
    changes: changesSummary,
    expires_at: new Date(Date.now() + 90 * 24 * 60 * 60 * 1000),
  });

  await batch.commit();

  return {
    templateId,
    patchedFields,
    analyticsWillRecompute: exercisesChanged,
    message: 'Template updated successfully',
  };
}

// ---------------------------------------------------------------------------
// deleteTemplate
// ---------------------------------------------------------------------------

/**
 * Delete a template and clean up routine references.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string} templateId
 * @returns {Promise<Object>} Result with templateId and routinesUpdated count
 * @throws {ValidationError} if parameters are missing
 * @throws {NotFoundError} if template does not exist
 */
async function deleteTemplate(db, userId, templateId) {
  if (!userId || !templateId) {
    throw new ValidationError('Missing required parameters');
  }

  const ref = templateRef(db, userId, templateId);
  const doc = await ref.get();
  if (!doc.exists) throw new NotFoundError('Template not found');

  // Clean up routine references
  // READ BOTH fields for backward compat: template_ids (canonical) and templateIds (legacy)
  const routinesSnapshot = await db.collection('users').doc(userId).collection('routines').get();
  const routines = routinesSnapshot.docs.map(d => ({ id: d.id, ...d.data() }));

  const routinesToUpdate = routines.filter(routine => {
    const tids = routine.template_ids || routine.templateIds || [];
    return tids.includes(templateId);
  });

  // WRITE ONLY canonical field: template_ids
  for (const routine of routinesToUpdate) {
    const currentIds = routine.template_ids || routine.templateIds || [];
    const updatedTemplateIds = currentIds.filter(id => id !== templateId);

    const updateData = { template_ids: updatedTemplateIds };

    if (routine.last_completed_template_id === templateId) {
      updateData.last_completed_template_id = null;
      updateData.last_completed_at = null;
    }

    await db.collection('users').doc(userId).collection('routines').doc(routine.id).update(updateData);
  }

  // Delete the template
  await ref.delete();

  return { message: 'Template deleted', templateId, routinesUpdated: routinesToUpdate.length };
}

// ---------------------------------------------------------------------------
// createTemplateFromPlan
// ---------------------------------------------------------------------------

/**
 * Create or update a template from a session_plan card.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {Object} params
 * @param {string} params.canvasId
 * @param {string} params.cardId
 * @param {string} params.name
 * @param {string} params.mode - 'create' or 'update'
 * @param {string} [params.existingTemplateId] - Required when mode is 'update'
 * @returns {Promise<Object>} Result with templateId, mode, exerciseCount
 * @throws {ValidationError} if parameters are invalid
 * @throws {NotFoundError} if canvas, card, or template not found
 * @throws {PermissionDeniedError} if canvas is not accessible
 */
async function createTemplateFromPlan(db, userId, params) {
  const { canvasId, cardId, name, mode, existingTemplateId } = params;

  // Validate required parameters
  if (!canvasId || !cardId || !name || !mode) {
    throw new ValidationError('Missing required parameters: canvasId, cardId, name, mode');
  }
  if (!['create', 'update'].includes(mode)) {
    throw new ValidationError('mode must be "create" or "update"');
  }
  if (mode === 'update' && !existingTemplateId) {
    throw new ValidationError('existingTemplateId required for update mode');
  }

  // Idempotency check
  const idempotencyKey = `createTemplateFromPlan:${canvasId}:${cardId}:${mode}:${existingTemplateId || 'new'}`;
  const idempotencyRef = db.collection('users').doc(userId).collection('idempotency').doc(idempotencyKey);
  const idempotencyDoc = await idempotencyRef.get();

  if (idempotencyDoc.exists) {
    const existing = idempotencyDoc.data();
    return {
      templateId: existing.result,
      mode,
      idempotent: true,
      message: 'Operation already completed',
    };
  }

  // Verify canvas ownership
  const canvasRef = db.collection('users').doc(userId).collection('canvases').doc(canvasId);
  const canvasDoc = await canvasRef.get();
  if (!canvasDoc.exists) throw new NotFoundError('Canvas not found');

  const canvas = canvasDoc.data();
  if (canvas.meta?.user_id && canvas.meta.user_id !== userId) {
    throw new PermissionDeniedError('Canvas not accessible');
  }

  // Get and validate the card
  const cardRef = canvasRef.collection('cards').doc(cardId);
  const cardDoc = await cardRef.get();
  if (!cardDoc.exists) throw new NotFoundError('Card not found');

  const card = cardDoc.data();
  if (card.type !== 'session_plan') {
    throw new ValidationError(`Card type is "${card.type}", expected "session_plan"`);
  }

  const validation = validatePlanContent(card.content);
  if (!validation.valid) {
    throw new ValidationError('Invalid plan content', { errors: validation.errors });
  }

  // Convert plan blocks to template exercises
  let exercises;
  try {
    exercises = convertPlanBlocksToTemplateExercises(card.content.blocks);
  } catch (conversionError) {
    throw new ValidationError('Failed to convert plan to template', { message: conversionError.message });
  }

  let templateId;

  if (mode === 'create') {
    const templateData = {
      user_id: userId,
      name: name.trim(),
      description: card.content.coach_notes || null,
      exercises,
      source_card_id: cardId,
      source_canvas_id: canvasId,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    };

    const docRef = await db.collection('users').doc(userId).collection('templates').add(templateData);
    templateId = docRef.id;
    await docRef.update({ id: templateId });

  } else if (mode === 'update') {
    const existingRef = templateRef(db, userId, existingTemplateId);
    const existingDoc = await existingRef.get();
    if (!existingDoc.exists) throw new NotFoundError('Template not found');

    await existingRef.update({
      exercises,
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
      analytics: admin.firestore.FieldValue.delete(),
    });

    templateId = existingTemplateId;
  }

  // Record idempotency (TTL: 24 hours)
  await idempotencyRef.set({
    result: templateId,
    mode,
    created_at: admin.firestore.FieldValue.serverTimestamp(),
    expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000),
  });

  return {
    templateId,
    mode,
    exerciseCount: exercises.length,
    message: mode === 'create' ? 'Template created' : 'Template updated',
  };
}

module.exports = {
  getTemplate,
  listTemplates,
  createTemplate,
  patchTemplate,
  deleteTemplate,
  createTemplateFromPlan,
};
