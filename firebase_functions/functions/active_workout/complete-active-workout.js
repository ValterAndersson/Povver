/**
 * =============================================================================
 * complete-active-workout.js - Finish and Archive Workout
 * =============================================================================
 *
 * PURPOSE:
 * Called when user finishes a workout. Archives the active_workout to the
 * permanent workouts collection and triggers routine cursor advancement.
 *
 * COMPLETION FLOW:
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │ User taps "Finish Workout"                                             │
 * │          │                                                              │
 * │          ▼                                                              │
 * │ ┌─────────────────────────────────────────────────────────────────────┐│
 * ││ complete-active-workout.js                                           ││
 * ││  1. Load active_workout doc                                          ││
 * ││  2. Normalize sets (weight → weight_kg)                              ││
 * ││  3. Calculate analytics (sets per muscle, volume, etc.)              ││
 * ││  4. Create workout doc in users/{uid}/workouts                       ││
 * ││  5. Update active_workout status = 'completed'                       ││
 * │└─────────────────────────────────────────────────────────────────────┘│
 * │          │                                                              │
 * │          ▼ (Firestore onCreate trigger)                                │
 * │ ┌─────────────────────────────────────────────────────────────────────┐│
 * ││ workout-routine-cursor.js (trigger)                                  ││
 * ││  If source_routine_id present:                                       ││
 * ││    → Advance routine.cursor to next template                         ││
 * ││    → Updates routine.last_workout_at                                 ││
 * │└─────────────────────────────────────────────────────────────────────┘│
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * FIRESTORE OPERATIONS:
 * - Reads: users/{uid}/active_workouts/{workout_id}
 * - Creates: users/{uid}/workouts/{new_id} (permanent record)
 * - Updates: users/{uid}/active_workouts/{workout_id} → status='completed'
 *
 * ARCHIVED WORKOUT SCHEMA:
 * {
 *   user_id: string,
 *   source_template_id: string | null,  // Template used for this workout
 *   source_routine_id: string | null,   // Routine this belongs to (for cursor)
 *   created_at: timestamp,
 *   start_time: timestamp,
 *   end_time: timestamp,
 *   exercises: [{ exercise_id, sets: [{ weight_kg, reps, rir, tempo }] }],
 *   notes: string | null,
 *   analytics: {                         // Computed by AnalyticsCalc
 *     total_sets, total_reps, total_weight,
 *     sets_per_muscle_group, reps_per_muscle, etc.
 *   }
 * }
 *
 * CALLED BY:
 * - iOS: ActiveWorkoutManager.completeWorkout()
 *   → MYON2/MYON2/Services/ActiveWorkoutManager.swift
 *
 * RELATED FILES:
 * - start-active-workout.js: Creates the active_workout doc
 * - log-set.js: Adds sets during workout
 * - ../triggers/workout-routine-cursor.js: Advances routine cursor
 * - ../utils/analytics-calculator.js: Computes workout analytics
 *
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');
const AnalyticsCalc = require('../utils/analytics-calculator');
const { generateTemplateDiff } = require('../utils/template-diff-generator');
const { logger } = require('firebase-functions');
const { enqueueWorkoutCompletion } = require('../utils/enqueue-workout-task');

const firestore = admin.firestore();

/**
 * Sync template set weights from completed workout actuals.
 * For each exercise in the workout that matches a template exercise (by exercise_id),
 * update the template's working set weights to the max weight used.
 *
 * This prevents template weight regression when analyst auto-deloads
 * after the user has already self-progressed.
 *
 * IMPORTANT: Only syncs UPWARD. If the user used a lower weight than the template
 * prescribes (deload day, warmup, etc.), the template is NOT downgraded.
 * The analyst handles deloads explicitly via recommendations.
 */
async function syncTemplateWeightsFromWorkout(db, userId, templateId, exercises) {
  if (!Array.isArray(exercises) || exercises.length === 0) return;

  const templateRef = db.collection('users').doc(userId)
    .collection('templates').doc(templateId);

  await db.runTransaction(async (tx) => {
    const templateSnap = await tx.get(templateRef);
    if (!templateSnap.exists) return;

    const templateData = templateSnap.data();
    const templateExercises = templateData.exercises || [];
    let changed = false;

    for (const workoutEx of exercises) {
      const exId = workoutEx.exercise_id;
      if (!exId) continue;

      // Find matching template exercise by exercise_id
      const templateIdx = templateExercises.findIndex(
        te => te.exercise_id === exId
      );
      if (templateIdx === -1) continue;

      // Get max completed working set weight from workout
      const workingSets = (workoutEx.sets || []).filter(
        s => (s.type || 'working') !== 'warmup' && s.is_completed
      );
      if (workingSets.length === 0) continue;
      const maxWeight = Math.max(...workingSets.map(s => s.weight_kg || 0));
      // Upper bound: no single exercise exceeds 1000kg in any real training
      if (maxWeight <= 0 || maxWeight > 1000) continue;

      // Update template working sets — only sync UPWARD
      const templateSets = templateExercises[templateIdx].sets || [];
      for (const tSet of templateSets) {
        if ((tSet.type || 'working') === 'warmup') continue;
        const currentWeight = tSet.weight || 0;
        if (currentWeight < maxWeight) {
          tSet.weight = maxWeight;
          changed = true;
        }
      }
    }

    if (changed) {
      tx.update(templateRef, {
        exercises: templateExercises,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });
      logger.info('[completeActiveWorkout] Template weights synced from workout', {
        userId, templateId,
      });
    }
  });
}

async function completeActiveWorkoutHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }
    const userId = req.user?.uid || req.auth?.uid;
    if (!userId) return res.status(401).json({ success: false, error: 'Unauthorized' });

    const { workout_id } = req.body || {};
    if (!workout_id) return fail(res, 'INVALID_ARGUMENT', 'Missing workout_id', null, 400);

    // Load active doc
    const activeRef = firestore.collection('users').doc(userId).collection('active_workouts').doc(workout_id);
    const activeSnap = await activeRef.get();
    if (!activeSnap.exists) return fail(res, 'NOT_FOUND', 'Active workout not found', null, 404);
    const active = activeSnap.data();

    // Archive minimal workout (analytics TBD)
    const archiveParent = `users/${userId}/workouts`;
    // Normalize active workout fields to archived workout format.
    // Active workout uses: set_type, status, instance_id, weight
    // Archived format uses: type, is_completed, id, weight_kg
    const normalizedExercises = (active.exercises || []).map(ex => ({
      id: ex.instance_id || ex.id || null,
      exercise_id: ex.exercise_id,
      name: ex.name || null,
      position: ex.position ?? 0,
      notes: ex.notes || null,
      sets: (ex.sets || []).map(s => ({
        id: s.id || null,
        reps: typeof s.reps === 'number' ? s.reps : 0,
        rir: typeof s.rir === 'number' ? s.rir : null,
        type: s.set_type || s.type || 'working',
        weight_kg: typeof s.weight === 'number' ? s.weight : (typeof s.weight_kg === 'number' ? s.weight_kg : 0),
        is_completed: s.status === 'done',
      })),
      analytics: ex.analytics || null,
    }));

    // Compute full analytics if missing using analytics-calculator
    let analytics = active.analytics;
    try {
      if (!analytics) {
        const workoutLike = { exercises: normalizedExercises };
        const { workoutAnalytics } = await AnalyticsCalc.calculateWorkoutAnalytics(workoutLike);
        analytics = workoutAnalytics;
      }
    } catch (e) {
      console.warn('Non-fatal: failed to compute full analytics, falling back to totals', e?.message || e);
      analytics = {
        total_sets: active?.totals?.sets || 0,
        total_reps: active?.totals?.reps || 0,
        total_weight: active?.totals?.volume || 0,
        weight_format: 'kg',
        avg_reps_per_set: 0,
        avg_weight_per_set: 0,
        avg_weight_per_rep: 0,
        weight_per_muscle_group: {},
        weight_per_muscle: {},
        reps_per_muscle_group: {},
        reps_per_muscle: {},
        sets_per_muscle_group: {},
        sets_per_muscle: {},
      };
    }

    // ==========================================================================
    // TEMPLATE DIFF: Compare workout exercises against source template
    // ==========================================================================
    let templateDiff = null;
    if (active.source_template_id) {
      try {
        const templateRef = firestore.doc(`users/${userId}/templates/${active.source_template_id}`);
        const templateSnap = await templateRef.get();
        if (templateSnap.exists) {
          const templateData = templateSnap.data();
          templateDiff = generateTemplateDiff(normalizedExercises, templateData.exercises || []);
        } else {
          logger.warn('[completeActiveWorkout] Source template not found, skipping diff', {
            userId, templateId: active.source_template_id
          });
        }
      } catch (diffErr) {
        logger.warn('[completeActiveWorkout] Failed to generate template diff', {
          userId, error: diffErr?.message || diffErr
        });
        // Non-fatal: continue without diff
      }
    }

    // ==========================================================================
    // ATOMIC TRANSACTION: Archive + Update Status + Clear Lock
    // ==========================================================================
    const archiveRef = firestore.collection('users').doc(userId).collection('workouts').doc();

    const result = await firestore.runTransaction(async (tx) => {
      const activeRef = firestore.collection('users').doc(userId).collection('active_workouts').doc(workout_id);
      const lockRef = firestore.collection('users').doc(userId).collection('meta').doc('active_workout_state');

      // Read workout inside transaction
      const workoutSnap = await tx.get(activeRef);
      if (!workoutSnap.exists) {
        throw { httpCode: 404, code: 'NOT_FOUND', message: 'Active workout not found' };
      }

      const currentWorkout = workoutSnap.data();

      // Guard: if already completed, skip
      if (currentWorkout.status !== 'in_progress') {
        return { already_completed: true };
      }

      const now = admin.firestore.FieldValue.serverTimestamp();

      // 1. Create archived workout in workouts collection
      const archived = {
        id: archiveRef.id,  // Needed for iOS Workout model decoding
        user_id: userId,
        name: active.name || null,
        source_template_id: active.source_template_id || null,
        source_routine_id: active.source_routine_id || null,
        created_at: active.created_at || now,
        start_time: active.start_time || now,
        end_time: now,
        exercises: normalizedExercises,
        notes: active.notes || null,
        analytics,
        ...(templateDiff !== null && { template_diff: templateDiff })
      };

      tx.set(archiveRef, archived);

      // 2. Update active workout status to completed
      tx.update(activeRef, {
        status: 'completed',
        end_time: now,
        updated_at: now
      });

      // 3. Clear lock document
      tx.set(lockRef, {
        active_workout_id: null,
        status: 'completed',
        updated_at: now
      });

      return { workout_id: archiveRef.id, archived: true };
    });

    if (result.already_completed) {
      return ok(res, { workout_id: workout_id, archived: false, message: 'Already completed' });
    }

    // Write changelog entry if template diff detected changes (non-critical, outside transaction)
    if (templateDiff && templateDiff.changes_detected && active.source_template_id) {
      try {
        const changelogRef = firestore.collection('users').doc(userId)
          .collection('templates').doc(active.source_template_id)
          .collection('changelog').doc();
        await changelogRef.set({
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          source: 'workout_completion',
          workout_id: result.workout_id,
          recommendation_id: null,
          changes: [{ field: 'exercises', operation: 'deviated', summary: templateDiff.summary || 'User deviated from template' }],
          expires_at: new Date(Date.now() + 90 * 24 * 60 * 60 * 1000)
        });
      } catch (changelogErr) {
        logger.warn('[completeActiveWorkout] Failed to write changelog', { error: changelogErr?.message });
        // Non-fatal: workout already archived successfully
      }
    }

    // Sync template weights from workout actuals.
    // When the user completes a workout, update the template to reflect
    // their actual working weights — prevents the "ghost regression" problem
    // where templates stay stale and analyst deloads overwrite user progress.
    if (active.source_template_id && result.workout_id) {
      try {
        await syncTemplateWeightsFromWorkout(
          firestore, userId, active.source_template_id, normalizedExercises
        );
      } catch (syncErr) {
        // Non-fatal — don't block workout completion
        logger.warn('[completeActiveWorkout] Template sync failed', {
          userId, templateId: active.source_template_id, error: syncErr?.message || String(syncErr),
        });
      }
    }

    // Enqueue Cloud Task for post-completion analytics pipeline
    try {
      await enqueueWorkoutCompletion(userId, result.workout_id);
    } catch (enqueueErr) {
      // Non-fatal — watchdog will catch missed completions
      logger.warn('[completeActiveWorkout] Failed to enqueue completion task', {
        userId, workoutId: result.workout_id, error: enqueueErr?.message || String(enqueueErr),
      });
    }

    logger.info(`[completeActiveWorkout] Completed workout ${workout_id}, archived as ${result.workout_id}`);

    return ok(res, result);
  } catch (error) {
    console.error('complete-active-workout error:', error);
    return fail(res, 'INTERNAL', 'Failed to complete active workout', { message: error.message }, 500);
  }
}

exports.completeActiveWorkout = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(completeActiveWorkoutHandler)
);
