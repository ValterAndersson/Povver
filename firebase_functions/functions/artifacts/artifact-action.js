/**
 * artifact-action.js - Handle artifact lifecycle actions
 *
 * Single endpoint for all artifact actions: accept, dismiss, save_routine,
 * start_workout, save_template. Replaces the canvas apply-action reducer
 * for artifact-based flows.
 *
 * Input: { userId, conversationId, artifactId, action, day? }
 * Output: { success, ... action-specific data }
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');
const { convertPlanToTemplate } = require('../utils/plan-to-template-converter');
const { fail } = require('../utils/response');
const { isPremiumUser } = require('../utils/subscription-gate');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();
const MAX_WORKOUTS_PER_ROUTINE = 14; // 2-week program max

async function artifactActionHandler(req, res) {
  // Secure userId derivation — prevents IDOR via auth-helpers
  const userId = getAuthenticatedUserId(req);
  const conversationId = req.body?.conversationId;
  const artifactId = req.body?.artifactId;
  const action = req.body?.action;
  const day = req.body?.day; // For per-day workout start in routine artifacts

  if (!userId || !conversationId || !artifactId || !action) {
    return res.status(400).json({
      success: false,
      error: 'userId, conversationId, artifactId, and action are required',
    });
  }

  const artifactRef = db
    .collection('users').doc(userId)
    .collection('conversations').doc(conversationId)
    .collection('artifacts').doc(artifactId);

  try {
    const artifactSnap = await artifactRef.get();
    if (!artifactSnap.exists) {
      return res.status(404).json({ success: false, error: 'Artifact not found' });
    }

    const artifact = artifactSnap.data();
    const now = admin.firestore.FieldValue.serverTimestamp();

    // Premium gate — only mutation actions require premium
    const premiumActions = ['save_routine', 'save_template', 'start_workout', 'save_as_new'];
    if (premiumActions.includes(action)) {
      const hasPremium = await isPremiumUser(userId);
      if (!hasPremium) {
        return fail(res, 'PREMIUM_REQUIRED', 'Premium subscription required', null, 403);
      }
    }

    switch (action) {
      case 'accept': {
        await artifactRef.update({ status: 'accepted', updated_at: now });
        return res.status(200).json({ success: true, status: 'accepted' });
      }

      case 'dismiss': {
        await artifactRef.update({ status: 'dismissed', updated_at: now });
        return res.status(200).json({ success: true, status: 'dismissed' });
      }

      case 'save_routine': {
        // Create routine + templates from routine_summary artifact
        if (artifact.type !== 'routine_summary') {
          return res.status(400).json({ success: false, error: 'save_routine requires routine_summary artifact' });
        }

        const content = artifact.content || {};
        const workouts = content.workouts || [];
        const sourceRoutineId = content.source_routine_id;

        if (workouts.length === 0) {
          return res.status(400).json({ success: false, error: 'Routine has no workouts' });
        }
        if (workouts.length > MAX_WORKOUTS_PER_ROUTINE) {
          return res.status(400).json({ success: false, error: `Routine has too many workouts (max ${MAX_WORKOUTS_PER_ROUTINE})` });
        }

        // Create templates for each workout day
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
            // Update existing template
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

              // Changelog entry for audit trail
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

        logger.info('[artifactAction] save_routine complete', {
          routineId, templateIds, isUpdate,
        });

        return res.status(200).json({
          success: true,
          routineId,
          templateIds,
          isUpdate,
        });
      }

      case 'start_workout': {
        // Start active workout from session_plan or routine_summary artifact
        let plan;

        if (artifact.type === 'session_plan') {
          plan = {
            title: artifact.content?.title || 'Workout',
            blocks: artifact.content?.blocks || [],
          };
        } else if (artifact.type === 'routine_summary') {
          // Start a specific day from the routine
          const dayIndex = (day || 1) - 1;
          const workouts = artifact.content?.workouts || [];
          if (dayIndex < 0 || dayIndex >= workouts.length) {
            return res.status(400).json({ success: false, error: `Invalid day: ${day}` });
          }
          const workout = workouts[dayIndex];
          plan = {
            title: workout.title || `Day ${day}`,
            blocks: workout.blocks || [],
          };
        } else {
          return res.status(400).json({ success: false, error: 'start_workout requires session_plan or routine_summary artifact' });
        }

        // Mark artifact as accepted
        await artifactRef.update({ status: 'accepted', updated_at: now });

        // Return plan data — iOS calls startActiveWorkout separately with this plan
        return res.status(200).json({
          success: true,
          plan,
          status: 'accepted',
        });
      }

      case 'save_template': {
        // Save session_plan artifact as template (create or update)
        if (artifact.type !== 'session_plan') {
          return res.status(400).json({ success: false, error: 'save_template requires session_plan artifact' });
        }

        const content = artifact.content || {};
        const sourceTemplateId = content.source_template_id;
        const templateData = convertPlanToTemplate({
          title: content.title || 'Workout',
          blocks: content.blocks || [],
          estimated_duration: content.estimated_duration_minutes,
        });

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

            // Changelog entry for audit trail
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

        return res.status(200).json({
          success: true,
          templateId,
          isUpdate,
        });
      }

      case 'save_as_new': {
        // Save as a new routine/template (ignore source IDs)
        if (artifact.type === 'routine_summary') {
          // Same as save_routine but without source IDs
          const content = artifact.content || {};
          const workouts = content.workouts || [];
          if (workouts.length > MAX_WORKOUTS_PER_ROUTINE) {
            return res.status(400).json({ success: false, error: `Routine has too many workouts (max ${MAX_WORKOUTS_PER_ROUTINE})` });
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

          return res.status(200).json({ success: true, routineId, templateIds, isUpdate: false });
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
          return res.status(200).json({ success: true, templateId, isUpdate: false });
        }

        return res.status(400).json({ success: false, error: 'save_as_new requires routine_summary or session_plan artifact' });
      }

      default:
        return res.status(400).json({ success: false, error: `Unknown action: ${action}` });
    }
  } catch (error) {
    logger.error('[artifactAction] Error', { error: error.message, action, artifactId });
    const httpStatus = error.http || 500;
    return res.status(httpStatus).json({
      success: false,
      error: error.message || 'Internal error',
    });
  }
}

exports.artifactAction = onRequest({
  timeoutSeconds: 60,
  memory: '256MiB',
  maxInstances: 30,
}, requireFlexibleAuth(artifactActionHandler));
