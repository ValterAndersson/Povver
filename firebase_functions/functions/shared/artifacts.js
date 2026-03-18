/**
 * shared/artifacts.js — Pure business logic for artifact actions.
 *
 * Each exported function takes (db, userId, conversationId, artifactId, options)
 * and returns a result object. No req/res — errors are thrown using shared
 * error types so the HTTP wrapper can map them to status codes.
 *
 * Collection name uses 'canvases' until Phase 7 renames to 'conversations'.
 */

const { ValidationError, NotFoundError, PremiumRequiredError } = require('./errors');
const { convertPlanToTemplate } = require('../utils/plan-to-template-converter');
const { isPremiumUser } = require('../utils/subscription-gate');
const admin = require('firebase-admin');

const CONVERSATION_COLLECTION = process.env.CONVERSATION_COLLECTION || 'conversations';
const MAX_WORKOUTS_PER_ROUTINE = 14; // 2-week program max

// Actions that require premium subscription
const PREMIUM_ACTIONS = ['save_routine', 'save_template', 'start_workout', 'save_as_new'];

/**
 * Resolve the artifact Firestore ref and snapshot.
 * Throws NotFoundError if it doesn't exist.
 */
async function getArtifact(db, userId, conversationId, artifactId) {
  const ref = db
    .collection('users').doc(userId)
    .collection(CONVERSATION_COLLECTION).doc(conversationId)
    .collection('artifacts').doc(artifactId);

  const snap = await ref.get();
  if (!snap.exists) {
    throw new NotFoundError('Artifact not found');
  }
  return { ref, data: snap.data() };
}

/**
 * Gate premium actions. No-op for non-premium actions.
 */
async function enforcePremiumGate(action, userId) {
  if (PREMIUM_ACTIONS.includes(action)) {
    const hasPremium = await isPremiumUser(userId);
    if (!hasPremium) {
      throw new PremiumRequiredError();
    }
  }
}

// ─── Action handlers ────────────────────────────────────────────────────────

async function acceptArtifact(db, userId, conversationId, artifactId) {
  const { ref } = await getArtifact(db, userId, conversationId, artifactId);
  const now = admin.firestore.FieldValue.serverTimestamp();
  await ref.update({ status: 'accepted', updated_at: now });
  return { status: 'accepted' };
}

async function dismissArtifact(db, userId, conversationId, artifactId) {
  const { ref } = await getArtifact(db, userId, conversationId, artifactId);
  const now = admin.firestore.FieldValue.serverTimestamp();
  await ref.update({ status: 'dismissed', updated_at: now });
  return { status: 'dismissed' };
}

async function saveRoutine(db, userId, conversationId, artifactId) {
  const { ref: artifactRef, data: artifact } = await getArtifact(db, userId, conversationId, artifactId);
  await enforcePremiumGate('save_routine', userId);

  if (artifact.type !== 'routine_summary') {
    throw new ValidationError('save_routine requires routine_summary artifact');
  }

  const content = artifact.content || {};
  const workouts = content.workouts || [];
  const sourceRoutineId = content.source_routine_id;

  if (workouts.length === 0) {
    throw new ValidationError('Routine has no workouts');
  }
  if (workouts.length > MAX_WORKOUTS_PER_ROUTINE) {
    throw new ValidationError(`Routine has too many workouts (max ${MAX_WORKOUTS_PER_ROUTINE})`);
  }

  const now = admin.firestore.FieldValue.serverTimestamp();
  const templateIds = [];
  const templatesPath = `users/${userId}/templates`;

  for (const workout of workouts) {
    const sourceTemplateId = workout.source_template_id;
    const templateData = convertPlanToTemplate({
      title: workout.title || `Day ${workout.day}`,
      blocks: workout.blocks || [],
      estimated_duration: workout.estimated_duration,
    });

    if (sourceTemplateId) {
      const templateRef = db.doc(`${templatesPath}/${sourceTemplateId}`);
      const templateSnap = await templateRef.get();

      if (templateSnap.exists) {
        const batch = db.batch();
        batch.update(templateRef, {
          name: templateData.name,
          exercises: templateData.exercises,
          analytics: null,
          updated_at: now,
        });

        const changelogRef = templateRef.collection('changelog').doc();
        batch.set(changelogRef, {
          timestamp: now,
          source: 'agent_coached_edit',
          changes: [{ field: 'exercises', operation: 'update', summary: 'Updated via routine edit' }],
          expires_at: new Date(Date.now() + 90 * 24 * 60 * 60 * 1000),
        });

        await batch.commit();
        templateIds.push(sourceTemplateId);
      } else {
        const newRef = db.collection(templatesPath).doc();
        await newRef.set({
          id: newRef.id,
          user_id: userId,
          ...templateData,
          created_at: now,
          updated_at: now,
        });
        templateIds.push(newRef.id);
      }
    } else {
      const newRef = db.collection(templatesPath).doc();
      await newRef.set({
        id: newRef.id,
        user_id: userId,
        ...templateData,
        created_at: now,
        updated_at: now,
      });
      templateIds.push(newRef.id);
    }
  }

  // Create or update routine
  const routinesPath = `users/${userId}/routines`;
  const routineData = {
    name: content.name || 'My Routine',
    description: content.description || null,
    frequency: content.frequency || templateIds.length,
    template_ids: templateIds,
    updated_at: now,
  };

  let routineId;
  let isUpdate = false;

  if (sourceRoutineId) {
    const existingRef = db.doc(`${routinesPath}/${sourceRoutineId}`);
    const existingSnap = await existingRef.get();
    if (existingSnap.exists) {
      await existingRef.update(routineData);
      routineId = sourceRoutineId;
      isUpdate = true;
    }
  }

  if (!routineId) {
    const newRoutineRef = db.collection(routinesPath).doc();
    routineId = newRoutineRef.id;
    await newRoutineRef.set({
      id: routineId,
      user_id: userId,
      ...routineData,
      cursor: 0,
      created_at: now,
    });
  }

  // Set as active routine
  await db.doc(`users/${userId}`).update({ activeRoutineId: routineId });

  // Mark artifact as accepted
  await artifactRef.update({ status: 'accepted', updated_at: now });

  return { routineId, templateIds, isUpdate };
}

async function startWorkout(db, userId, conversationId, artifactId, { day } = {}) {
  const { ref: artifactRef, data: artifact } = await getArtifact(db, userId, conversationId, artifactId);
  await enforcePremiumGate('start_workout', userId);

  let plan;

  if (artifact.type === 'session_plan') {
    plan = {
      title: artifact.content?.title || 'Workout',
      blocks: artifact.content?.blocks || [],
    };
  } else if (artifact.type === 'routine_summary') {
    const dayIndex = (day || 1) - 1;
    const workouts = artifact.content?.workouts || [];
    if (dayIndex < 0 || dayIndex >= workouts.length) {
      throw new ValidationError(`Invalid day: ${day}`);
    }
    const workout = workouts[dayIndex];
    plan = {
      title: workout.title || `Day ${day}`,
      blocks: workout.blocks || [],
    };
  } else {
    throw new ValidationError('start_workout requires session_plan or routine_summary artifact');
  }

  const now = admin.firestore.FieldValue.serverTimestamp();
  await artifactRef.update({ status: 'accepted', updated_at: now });

  return { plan, status: 'accepted' };
}

async function saveTemplate(db, userId, conversationId, artifactId) {
  const { ref: artifactRef, data: artifact } = await getArtifact(db, userId, conversationId, artifactId);
  await enforcePremiumGate('save_template', userId);

  if (artifact.type !== 'session_plan') {
    throw new ValidationError('save_template requires session_plan artifact');
  }

  const content = artifact.content || {};
  const sourceTemplateId = content.source_template_id;
  const templateData = convertPlanToTemplate({
    title: content.title || 'Workout',
    blocks: content.blocks || [],
    estimated_duration: content.estimated_duration_minutes,
  });

  const now = admin.firestore.FieldValue.serverTimestamp();
  const templatesPath = `users/${userId}/templates`;
  let templateId;
  let isUpdate = false;

  if (sourceTemplateId) {
    const existingRef = db.doc(`${templatesPath}/${sourceTemplateId}`);
    const existingSnap = await existingRef.get();
    if (existingSnap.exists) {
      const batch = db.batch();
      batch.update(existingRef, {
        name: templateData.name,
        exercises: templateData.exercises,
        analytics: null,
        updated_at: now,
      });

      const changelogRef = existingRef.collection('changelog').doc();
      batch.set(changelogRef, {
        timestamp: now,
        source: 'agent_coached_edit',
        changes: [{ field: 'exercises', operation: 'update', summary: 'Updated via template edit' }],
        expires_at: new Date(Date.now() + 90 * 24 * 60 * 60 * 1000),
      });

      await batch.commit();
      templateId = sourceTemplateId;
      isUpdate = true;
    }
  }

  if (!templateId) {
    const newRef = db.collection(templatesPath).doc();
    templateId = newRef.id;
    await newRef.set({
      id: templateId,
      user_id: userId,
      ...templateData,
      created_at: now,
      updated_at: now,
    });
  }

  await artifactRef.update({ status: 'accepted', updated_at: now });

  return { templateId, isUpdate };
}

async function saveAsNew(db, userId, conversationId, artifactId) {
  const { ref: artifactRef, data: artifact } = await getArtifact(db, userId, conversationId, artifactId);
  await enforcePremiumGate('save_as_new', userId);

  const now = admin.firestore.FieldValue.serverTimestamp();

  if (artifact.type === 'routine_summary') {
    const content = artifact.content || {};
    const workouts = content.workouts || [];
    if (workouts.length > MAX_WORKOUTS_PER_ROUTINE) {
      throw new ValidationError(`Routine has too many workouts (max ${MAX_WORKOUTS_PER_ROUTINE})`);
    }
    const templateIds = [];
    const templatesPath = `users/${userId}/templates`;

    for (const workout of workouts) {
      const templateData = convertPlanToTemplate({
        title: workout.title || `Day ${workout.day}`,
        blocks: workout.blocks || [],
        estimated_duration: workout.estimated_duration,
      });
      const newRef = db.collection(templatesPath).doc();
      await newRef.set({
        id: newRef.id,
        user_id: userId,
        ...templateData,
        created_at: now,
        updated_at: now,
      });
      templateIds.push(newRef.id);
    }

    const routinesPath = `users/${userId}/routines`;
    const newRoutineRef = db.collection(routinesPath).doc();
    const routineId = newRoutineRef.id;
    await newRoutineRef.set({
      id: routineId,
      user_id: userId,
      name: content.name || 'My Routine',
      description: content.description || null,
      frequency: content.frequency || templateIds.length,
      template_ids: templateIds,
      cursor: 0,
      created_at: now,
      updated_at: now,
    });

    await db.doc(`users/${userId}`).update({ activeRoutineId: routineId });
    await artifactRef.update({ status: 'accepted', updated_at: now });

    return { routineId, templateIds, isUpdate: false };
  }

  if (artifact.type === 'session_plan') {
    const content = artifact.content || {};
    const templateData = convertPlanToTemplate({
      title: content.title || 'Workout',
      blocks: content.blocks || [],
      estimated_duration: content.estimated_duration_minutes,
    });
    const templatesPath = `users/${userId}/templates`;
    const newRef = db.collection(templatesPath).doc();
    const templateId = newRef.id;
    await newRef.set({
      id: templateId,
      user_id: userId,
      ...templateData,
      created_at: now,
      updated_at: now,
    });

    await artifactRef.update({ status: 'accepted', updated_at: now });
    return { templateId, isUpdate: false };
  }

  throw new ValidationError('save_as_new requires routine_summary or session_plan artifact');
}

/**
 * Dispatch an artifact action by name.
 * Validates inputs and delegates to the appropriate handler.
 *
 * @param {Object} db - Firestore instance
 * @param {string} userId
 * @param {string} conversationId
 * @param {string} artifactId
 * @param {string} action - One of: accept, dismiss, save_routine, start_workout, save_template, save_as_new
 * @param {Object} options - Action-specific options (e.g. { day } for start_workout)
 * @returns {Object} Action result
 */
async function executeArtifactAction(db, userId, conversationId, artifactId, action, options = {}) {
  if (!userId || !conversationId || !artifactId || !action) {
    throw new ValidationError('userId, conversationId, artifactId, and action are required');
  }

  switch (action) {
    case 'accept':
      return acceptArtifact(db, userId, conversationId, artifactId);
    case 'dismiss':
      return dismissArtifact(db, userId, conversationId, artifactId);
    case 'save_routine':
      return saveRoutine(db, userId, conversationId, artifactId);
    case 'start_workout':
      return startWorkout(db, userId, conversationId, artifactId, options);
    case 'save_template':
      return saveTemplate(db, userId, conversationId, artifactId);
    case 'save_as_new':
      return saveAsNew(db, userId, conversationId, artifactId);
    default:
      throw new ValidationError(`Unknown action: ${action}`);
  }
}

module.exports = {
  executeArtifactAction,
  acceptArtifact,
  dismissArtifact,
  saveRoutine,
  startWorkout,
  saveTemplate,
  saveAsNew,
  // Exported for testing
  CONVERSATION_COLLECTION,
  MAX_WORKOUTS_PER_ROUTINE,
  PREMIUM_ACTIONS,
};
