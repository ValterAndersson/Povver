/**
 * completeCurrentSet - Mark the first planned working/dropset as done
 *
 * Simplified endpoint for focus mode: finds the first planned set and marks it done.
 * Uses the same transaction pattern as log-set.js.
 *
 * REQUEST BODY:
 * {
 *   workout_id: string (required)
 * }
 *
 * RESPONSE:
 * {
 *   success: true,
 *   data: {
 *     exercise_name: string,
 *     set_number: number,
 *     total_sets: number,
 *     weight: number,
 *     reps: number
 *   }
 * }
 */
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { fail, ok } = require('../utils/response');
const { computeTotals } = require('../utils/active-workout-helpers');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

const db = admin.firestore();

async function completeCurrentSetHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    // User ID from Firebase Auth or API key middleware
    const userId = getAuthenticatedUserId(req);

    const { workout_id: workoutId } = req.body || {};
    if (!workoutId) {
      return fail(res, 'INVALID_ARGUMENT', 'Missing workout_id', null, 400);
    }

    // Pre-generate refs outside transaction
    const workoutRef = db.doc(`users/${userId}/active_workouts/${workoutId}`);
    const eventRef = db.collection(`users/${userId}/active_workouts/${workoutId}/events`).doc();

    // Run everything in a transaction
    const result = await db.runTransaction(async (tx) => {
      // Read workout
      const workoutSnap = await tx.get(workoutRef);
      if (!workoutSnap.exists) {
        throw { httpCode: 404, code: 'NOT_FOUND', message: 'Workout not found' };
      }

      const workout = workoutSnap.data();

      // Validate status
      if (workout.status !== 'in_progress') {
        throw { httpCode: 400, code: 'INVALID_STATE', message: 'Workout is not in progress', details: { status: workout.status } };
      }

      // Find first exercise with a planned working/dropset set
      let targetExerciseIndex = -1;
      let targetSetIndex = -1;
      let targetExercise = null;
      let targetSet = null;

      for (let exIdx = 0; exIdx < (workout.exercises || []).length; exIdx++) {
        const exercise = workout.exercises[exIdx];
        for (let setIdx = 0; setIdx < (exercise.sets || []).length; setIdx++) {
          const set = exercise.sets[setIdx];
          const setType = (set.set_type || 'working').toLowerCase();
          if (set.status === 'planned' && (setType === 'working' || setType === 'dropset')) {
            targetExerciseIndex = exIdx;
            targetSetIndex = setIdx;
            targetExercise = exercise;
            targetSet = set;
            break;
          }
        }
        if (targetSet) break;
      }

      if (!targetSet) {
        throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'No planned working/dropset sets found' };
      }

      // Mark set as done
      const updatedSet = {
        ...targetSet,
        status: 'done',
      };

      // Update exercises array
      const updatedExercises = workout.exercises.map((ex, exIdx) => {
        if (exIdx !== targetExerciseIndex) return ex;
        return {
          ...ex,
          sets: ex.sets.map((s, sIdx) => {
            if (sIdx !== targetSetIndex) return s;
            return updatedSet;
          }),
        };
      });

      // Recompute totals
      const totals = computeTotals(updatedExercises);

      // Version increment
      const nextVersion = (workout.version || 0) + 1;

      // Build event
      const event = {
        id: eventRef.id,
        type: 'set_done',
        payload: {
          exercise_instance_id: targetExercise.instance_id,
          set_id: targetSet.id,
          fields_changed: ['status'],
        },
        diff_ops: [
          { op: 'replace', path: `/exercises/${targetExerciseIndex}/sets/${targetSetIndex}/status`, value: 'done' },
        ],
        cause: 'user_edit',
        ui_source: 'complete_current_set',
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      };

      // Write workout update + event inside transaction
      tx.update(workoutRef, {
        exercises: updatedExercises,
        totals,
        version: nextVersion,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(eventRef, event);

      // Count total working/dropset sets for this exercise (default to 'working' when unset)
      const isCountedType = (s) => { const t = (s.set_type || 'working').toLowerCase(); return t === 'working' || t === 'dropset'; };
      const totalSets = targetExercise.sets.filter(isCountedType).length;
      const setNumber = targetExercise.sets
        .filter(isCountedType)
        .findIndex(s => s.id === targetSet.id) + 1;

      return {
        exercise_name: targetExercise.name || 'Unknown',
        set_number: setNumber,
        total_sets: totalSets,
        weight: updatedSet.weight ?? 0,
        reps: updatedSet.reps ?? 0,
      };
    });

    return ok(res, result);
  } catch (error) {
    // Structured errors thrown from inside the transaction
    if (error.httpCode) {
      return fail(res, error.code, error.message, error.details || null, error.httpCode);
    }
    console.error('complete-current-set error:', error);
    return fail(res, 'INTERNAL', 'Failed to complete current set', { message: error.message }, 500);
  }
}

exports.completeCurrentSet = onRequest(requireFlexibleAuth(completeCurrentSetHandler));
