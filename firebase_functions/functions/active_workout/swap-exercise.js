const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ensureIdempotent } = require('../utils/idempotency');
const { ok, fail } = require('../utils/response');
const { logger } = require('firebase-functions');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

const db = admin.firestore();

async function swapExerciseHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return fail(res, 'METHOD_NOT_ALLOWED', 'Method Not Allowed', null, 405);
    }
    const userId = getAuthenticatedUserId(req);

    const { workout_id, from_exercise_id, to_exercise_id, reason } = req.body || {};
    const idempotencyKey = req.body?.idempotency_key;
    if (idempotencyKey) {
      const idem = await ensureIdempotent(userId, 'swap_exercise', idempotencyKey);
      if (idem.isDuplicate) return ok(res, { duplicate: true });
    }
    if (!workout_id || !from_exercise_id || !to_exercise_id) {
      return fail(res, 'INVALID_ARGUMENT', 'Missing parameters', { required: ['workout_id','from_exercise_id','to_exercise_id'] }, 400);
    }

    // Validate reason length
    if (reason && typeof reason === 'string' && reason.length > 5000) {
      return fail(res, 'INVALID_ARGUMENT', 'Reason too long', null, 400);
    }

    const workoutRef = db.doc(`users/${userId}/active_workouts/${workout_id}`);
    const eventRef = db.collection(`users/${userId}/active_workouts/${workout_id}/events`).doc();

    // Run swap in transaction
    const result = await db.runTransaction(async (tx) => {
      // Read workout
      const workoutSnap = await tx.get(workoutRef);
      if (!workoutSnap.exists) {
        throw { httpCode: 404, code: 'NOT_FOUND', message: 'Workout not found' };
      }

      const workout = workoutSnap.data();

      if (workout.status !== 'in_progress') {
        throw { httpCode: 400, code: 'INVALID_STATE', message: 'Workout is not in progress' };
      }

      // Find exercise by from_exercise_id (match on instance_id — callers send instance_id)
      let targetExerciseIndex = -1;
      let targetExercise = null;
      for (let i = 0; i < (workout.exercises || []).length; i++) {
        if (workout.exercises[i].instance_id === from_exercise_id) {
          targetExerciseIndex = i;
          targetExercise = workout.exercises[i];
          break;
        }
      }

      if (!targetExercise) {
        throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise not found', details: { from_exercise_id } };
      }

      // Fetch new exercise name from catalog
      const newExerciseRef = db.doc(`exercises/${to_exercise_id}`);
      const newExerciseSnap = await tx.get(newExerciseRef);
      if (!newExerciseSnap.exists) {
        throw { httpCode: 404, code: 'EXERCISE_NOT_FOUND', message: 'Target exercise not found in catalog', details: { to_exercise_id } };
      }

      const newExerciseData = newExerciseSnap.data();
      const newExerciseName = newExerciseData.name || to_exercise_id;

      // Replace exercise data, preserving instance_id and set structure
      const swappedExercise = {
        ...targetExercise,
        exercise_id: to_exercise_id,
        name: newExerciseName,
      };

      // Update exercises array
      const updatedExercises = workout.exercises.map((ex, idx) => {
        if (idx !== targetExerciseIndex) return ex;
        return swappedExercise;
      });

      // Version increment
      const nextVersion = (workout.version || 0) + 1;

      // Build event
      const event = {
        id: eventRef.id,
        type: 'exercise_swapped',
        payload: { from_exercise_id, to_exercise_id, reason: reason || null },
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      };

      // Write workout update + event
      tx.update(workoutRef, {
        exercises: updatedExercises,
        version: admin.firestore.FieldValue.increment(1),
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(eventRef, event);

      return { event_id: eventRef.id, version: nextVersion };
    });

    return ok(res, result);
  } catch (error) {
    if (error.httpCode) {
      return fail(res, error.code, error.message, error.details || null, error.httpCode);
    }
    logger.error('[swapExercise] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to swap exercise', null, 500);
  }
}

exports.swapExercise = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(swapExerciseHandler)
);
