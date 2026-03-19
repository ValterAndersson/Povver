/**
 * =============================================================================
 * create-routine-from-draft.js - Routine Materialization from Canvas Draft
 * =============================================================================
 *
 * PURPOSE:
 * Creates permanent routine and template documents from a canvas draft.
 * This is the SINGLE WRITE PATH for saving routine proposals from the agent.
 *
 * ARCHITECTURE CONTEXT:
 * ┌────────────────────────────────────────────────────────────────────────────┐
 * │ ROUTINE CREATION FLOW                                                      │
 * │                                                                            │
 * │ 1. Agent proposes routine (propose-cards.js)                               │
 * │    → Creates routine_summary card + N session_plan cards                   │
 * │    → Cards linked via meta.groupId and workouts[].card_id                  │
 * │    → All cards status='proposed'                                           │
 * │                                                                            │
 * │ 2. User reviews on canvas UI                                               │
 * │    → Can edit individual days, ask for regeneration                        │
 * │                                                                            │
 * │ 3. User accepts (apply-action.js ACCEPT_PROPOSAL)                          │
 * │    → Calls THIS FILE (createRoutineFromDraftCore)                          │
 * │                                                                            │
 * │ 4. This file creates permanent records:                                    │
 * │    ┌─────────────────────────────────────────────────────────────────┐     │
 * │    │ Canvas Cards                  →      Permanent Documents        │     │
 * │    │                                                                 │     │
 * │    │ session_plan card (Day 1)    →  templates/{templateId1}        │     │
 * │    │ session_plan card (Day 2)    →  templates/{templateId2}        │     │
 * │    │ session_plan card (Day 3)    →  templates/{templateId3}        │     │
 * │    │                                                                 │     │
 * │    │ routine_summary card         →  routines/{routineId}           │     │
 * │    │                                  .template_ids = [t1, t2, t3]   │     │
 * │    │                                  .cursor = 0                    │     │
 * │    └─────────────────────────────────────────────────────────────────┘     │
 * │                                                                            │
 * │ 5. Sets user.activeRoutineId = routineId                                   │
 * │                                                                            │
 * │ 6. Marks all draft cards status='accepted'                                 │
 * └────────────────────────────────────────────────────────────────────────────┘
 *
 * FIRESTORE WRITES:
 * - Creates/Updates: users/{uid}/templates/{templateId} (one per day)
 * - Creates/Updates: users/{uid}/routines/{routineId}
 * - Updates: users/{uid} → activeRoutineId
 * - Updates: users/{uid}/canvases/{canvasId}/cards/* → status='accepted'
 *
 * UPDATE vs CREATE LOGIC:
 * - If card.meta.sourceTemplateId exists → Updates that template
 * - If card.meta.sourceRoutineId exists → Updates that routine
 * - Otherwise → Creates new documents
 * 
 * This enables "edit and save" flows where user modifies existing routine.
 *
 * CALLED BY:
 * - apply-action.js: ACCEPT_PROPOSAL for routine_summary cards
 * - Potentially direct API calls for testing
 *
 * RELATED FILES:
 * - ../canvas/propose-cards.js: Creates the draft cards
 * - ../utils/plan-to-template-converter.js: Converts session_plan → template
 * - get-next-workout.js: Uses routine.template_ids + cursor
 * - ../triggers/workout-routine-cursor.js: Advances cursor on completion
 *
 * =============================================================================
 */

const admin = require('firebase-admin');
const { convertPlanToTemplate } = require('../utils/plan-to-template-converter');
const { resolveExerciseNames } = require('../shared/templates');

/**
 * Creates a routine from a canvas draft.
 * 
 * @param {string} userId - The user ID
 * @param {string} canvasId - The canvas ID containing the draft
 * @param {string} draftId - The draft_id from routine_summary.meta.draftId
 * @param {Object} options - Optional settings
 * @param {boolean} options.setActive - Whether to set as active routine (default: true)
 * @returns {Object} { routineId, templateIds, isUpdate }
 */
async function createRoutineFromDraftCore(userId, canvasId, draftId, options = {}) {
  const { setActive = true } = options;
  const db = admin.firestore();
  const { FieldValue } = admin.firestore;
  const now = FieldValue.serverTimestamp();

  const canvasPath = `users/${userId}/canvases/${canvasId}`;
  
  // 1. Find the routine_summary card by draftId
  const summaryQuery = db.collection(`${canvasPath}/cards`)
    .where('type', '==', 'routine_summary')
    .where('meta.draftId', '==', draftId)
    .limit(1);
  
  const summarySnap = await summaryQuery.get();
  if (summarySnap.empty) {
    throw { http: 404, code: 'NOT_FOUND', message: `Draft not found: ${draftId}` };
  }
  
  const summaryDoc = summarySnap.docs[0];
  const summary = summaryDoc.data();
  const summaryContent = summary.content || {};
  const groupId = summary.meta?.groupId;
  
  // Validate summary has workouts
  if (!Array.isArray(summaryContent.workouts) || summaryContent.workouts.length === 0) {
    throw { http: 400, code: 'INVALID_ARGUMENT', message: 'Draft has no workouts' };
  }
  
  // 2. Load all referenced session_plan cards in order from workouts[]
  const templateIds = [];
  const dayCards = [];
  
  for (const workout of summaryContent.workouts) {
    if (!workout.card_id) {
      // Placeholder day - skip or error?
      if (workout.generate) {
        throw { http: 400, code: 'INCOMPLETE_DRAFT', message: `Day ${workout.day} has not been generated yet` };
      }
      continue;
    }
    
    const cardRef = db.doc(`${canvasPath}/cards/${workout.card_id}`);
    const cardSnap = await cardRef.get();
    
    if (!cardSnap.exists) {
      throw { http: 404, code: 'NOT_FOUND', message: `Day card not found: ${workout.card_id}` };
    }
    
    const cardData = cardSnap.data();
    dayCards.push({ ref: cardRef, data: cardData, workout });
  }
  
  // 3. For each day card: create or update template
  const templatesPath = `users/${userId}/templates`;
  
  for (const { ref: dayCardRef, data: dayCard, workout } of dayCards) {
    const sourceTemplateId = dayCard.meta?.sourceTemplateId;
    
    // Convert session_plan to template format
    const templateData = convertPlanToTemplate({
      title: workout.title || dayCard.content?.title || 'Workout',
      blocks: dayCard.content?.blocks || [],
      estimated_duration: workout.estimated_duration || dayCard.content?.estimated_duration_minutes,
    });

    // Resolve missing exercise names from catalog
    const idsToResolve = (templateData.exercises || [])
      .filter(ex => !ex.name && ex.exercise_id)
      .map(ex => ex.exercise_id);
    if (idsToResolve.length > 0) {
      const nameMap = await resolveExerciseNames(db, idsToResolve);
      templateData.exercises.forEach(ex => {
        if (!ex.name && nameMap[ex.exercise_id]) {
          ex.name = nameMap[ex.exercise_id];
        }
      });
    }

    if (sourceTemplateId) {
      // Update existing template
      const templateRef = db.doc(`${templatesPath}/${sourceTemplateId}`);
      const templateSnap = await templateRef.get();
      
      if (templateSnap.exists) {
        await templateRef.update({
          name: templateData.name,
          exercises: templateData.exercises,
          analytics: null, // Will be recomputed by trigger
          updated_at: now,
        });
        templateIds.push(sourceTemplateId);
        console.log('[createRoutineFromDraft] updated template', { templateId: sourceTemplateId });
      } else {
        // Source template doesn't exist, create new
        const newTemplateRef = db.collection(templatesPath).doc();
        await newTemplateRef.set({
          id: newTemplateRef.id,
          user_id: userId,
          ...templateData,
          created_at: now,
          updated_at: now,
        });
        templateIds.push(newTemplateRef.id);
        console.log('[createRoutineFromDraft] created template (source missing)', { templateId: newTemplateRef.id });
      }
    } else {
      // Create new template
      const newTemplateRef = db.collection(templatesPath).doc();
      await newTemplateRef.set({
        id: newTemplateRef.id,
        user_id: userId,
        ...templateData,
        created_at: now,
        updated_at: now,
      });
      templateIds.push(newTemplateRef.id);
      console.log('[createRoutineFromDraft] created template', { templateId: newTemplateRef.id });
    }
  }

  // Build template_names from created templates
  const templateNames = {};
  dayCards.forEach(({ workout }, i) => {
    templateNames[templateIds[i]] = workout.title || dayCards[i].data.content?.title || 'Workout';
  });

  // 4. Create or update routine
  const routinesPath = `users/${userId}/routines`;
  const sourceRoutineId = summary.meta?.sourceRoutineId;
  let routineId;
  let isUpdate = false;

  const routineData = {
    name: summaryContent.name || 'My Routine',
    description: summaryContent.description || null,
    frequency: summaryContent.frequency || templateIds.length,
    template_ids: templateIds,
    template_names: templateNames,
    updated_at: now,
  };
  
  if (sourceRoutineId) {
    // Update existing routine
    const routineRef = db.doc(`${routinesPath}/${sourceRoutineId}`);
    const routineSnap = await routineRef.get();
    
    if (routineSnap.exists) {
      await routineRef.update(routineData);
      routineId = sourceRoutineId;
      isUpdate = true;
      console.log('[createRoutineFromDraft] updated routine', { routineId });
    } else {
      // Source routine doesn't exist, create new
      const newRoutineRef = db.collection(routinesPath).doc();
      await newRoutineRef.set({
        id: newRoutineRef.id,
        user_id: userId,
        ...routineData,
        created_at: now,
      });
      routineId = newRoutineRef.id;
      console.log('[createRoutineFromDraft] created routine (source missing)', { routineId });
    }
  } else {
    // Create new routine
    const newRoutineRef = db.collection(routinesPath).doc();
    await newRoutineRef.set({
      id: newRoutineRef.id,
      user_id: userId,
      ...routineData,
      created_at: now,
    });
    routineId = newRoutineRef.id;
    console.log('[createRoutineFromDraft] created routine', { routineId });
  }
  
  // 5. Set as active routine if requested
  if (setActive && routineId) {
    const userRef = db.doc(`users/${userId}`);
    await userRef.update({ activeRoutineId: routineId });
    console.log('[createRoutineFromDraft] set active routine', { routineId });
  }
  
  // 6. Mark all draft cards as accepted
  const batch = db.batch();
  
  // Mark summary as accepted
  batch.update(summaryDoc.ref, { status: 'accepted', updated_at: now });
  
  // Mark all day cards as accepted
  for (const { ref } of dayCards) {
    batch.update(ref, { status: 'accepted', updated_at: now });
  }
  
  await batch.commit();
  console.log('[createRoutineFromDraft] marked cards accepted', { 
    summaryId: summaryDoc.id, 
    dayCardCount: dayCards.length 
  });
  
  return {
    routineId,
    templateIds,
    isUpdate,
    summaryCardId: summaryDoc.id,
  };
}

module.exports = { createRoutineFromDraftCore };
