/**
 * logSet - Mark a set as done (Hot Path)
 *
 * Per FOCUS_MODE_WORKOUT_EXECUTION.md spec:
 * - Uses stable IDs (exercise_instance_id + set_id)
 * - Enforces ALREADY_DONE error if set is already done
 * - Updates workout document with new values and status
 * - Recomputes totals (excludes warmups, skipped, planned)
 * - Writes set_done event with stable IDs
 * - Uses workout-scoped idempotency with response caching
 *
 * CONCURRENCY: All reads and writes are inside a Firestore transaction
 * to prevent lost updates from concurrent requests.
 */
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { fail, ok } = require('../utils/response');
const { LogSetSchemaV2 } = require('../utils/validators');
const {
  ensureWorkoutIdempotent,
  storeWorkoutIdempotentTx
} = require('../utils/idempotency');
const { computeTotals, findExerciseAndSet } = require('../utils/active-workout-helpers');
const { writeLimiter } = require('../utils/rate-limiter');

const db = admin.firestore();

async function logSetHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    // User ID from Firebase Auth or API key middleware
    const userId = req.user?.uid || req.auth?.uid;
    if (!userId) {
      return res.status(401).json({ success: false, error: 'Unauthorized' });
    }

    if (!writeLimiter.check(userId)) {
      return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
    }

    // 1. Validate request body (pure validation — no Firestore reads)
    const parsed = LogSetSchemaV2.safeParse(req.body || {});
    if (!parsed.success) {
      return fail(res, 'INVALID_ARGUMENT', 'Invalid request', parsed.error.flatten(), 400);
    }

    const {
      workout_id: workoutId,
      exercise_instance_id: exerciseInstanceId,
      set_id: setId,
      values,
      is_failure: isFailure,
      idempotency_key: idempotencyKey,
      client_timestamp: clientTimestamp,
    } = parsed.data;

    // 2. Pre-generate refs outside transaction (doc() only generates a random ID, no read)
    const workoutRef = db.doc(`users/${userId}/active_workouts/${workoutId}`);
    const eventRef = db.collection(`users/${userId}/active_workouts/${workoutId}/events`).doc();

    // 3. Run everything in a transaction
    const result = await db.runTransaction(async (tx) => {
      // 3a. Check idempotency inside transaction
      const idem = await ensureWorkoutIdempotent(tx, userId, workoutId, idempotencyKey);
      if (idem.isDuplicate && idem.cachedResponse) {
        return { duplicate: true, response: idem.cachedResponse };
      }

      // 3b. Read workout
      const workoutSnap = await tx.get(workoutRef);
      if (!workoutSnap.exists) {
        throw { httpCode: 404, code: 'NOT_FOUND', message: 'Workout not found' };
      }

      const workout = workoutSnap.data();

      // 3c. Validate status
      if (workout.status !== 'in_progress') {
        throw { httpCode: 400, code: 'INVALID_STATE', message: 'Workout is not in progress', details: { status: workout.status } };
      }

      // 3d. Find exercise and set by stable IDs
      const found = findExerciseAndSet(workout.exercises || [], exerciseInstanceId, setId);
      if (!found) {
        throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise or set not found', details: { exercise_instance_id: exerciseInstanceId, set_id: setId } };
      }

      const { exerciseIndex, setIndex, set: currentSet } = found;

      // 3e. Check ALREADY_DONE
      if (currentSet.status === 'done') {
        throw { httpCode: 400, code: 'ALREADY_DONE', message: 'Set already marked done. Use patchActiveWorkout to edit.' };
      }

      // 3f. Check skipped
      if (currentSet.status === 'skipped') {
        throw { httpCode: 400, code: 'INVALID_STATE', message: 'Cannot mark skipped set as done. Unskip first via patchActiveWorkout.' };
      }

      // 3g. Build updated set
      const updatedSet = {
        ...currentSet,
        weight: values.weight,
        reps: values.reps,
        rir: values.rir,
        status: 'done',
        tags: {
          ...currentSet.tags,
          is_failure: isFailure || null,
        },
      };

      // 3h. Update exercises array (immutable update)
      const updatedExercises = workout.exercises.map((ex, exIdx) => {
        if (exIdx !== exerciseIndex) return ex;
        return {
          ...ex,
          sets: ex.sets.map((s, sIdx) => {
            if (sIdx !== setIndex) return s;
            return updatedSet;
          }),
        };
      });

      // 3i. Recompute totals
      const totals = computeTotals(updatedExercises);

      // 3j. Build diff for event
      const diffOps = [
        { op: 'replace', path: `/exercises/${exerciseIndex}/sets/${setIndex}/status`, value: 'done' },
        { op: 'replace', path: `/exercises/${exerciseIndex}/sets/${setIndex}/weight`, value: values.weight },
        { op: 'replace', path: `/exercises/${exerciseIndex}/sets/${setIndex}/reps`, value: values.reps },
        { op: 'replace', path: `/exercises/${exerciseIndex}/sets/${setIndex}/rir`, value: values.rir },
      ];
      if (isFailure !== undefined) {
        diffOps.push({ op: 'replace', path: `/exercises/${exerciseIndex}/sets/${setIndex}/tags/is_failure`, value: isFailure });
      }

      // 3k. Version increment
      const nextVersion = (workout.version || 0) + 1;

      // 3l. Build event
      const event = {
        id: eventRef.id,
        type: 'set_done',
        payload: {
          exercise_instance_id: exerciseInstanceId,
          set_id: setId,
          fields_changed: ['weight', 'reps', 'rir', 'status'],
        },
        diff_ops: diffOps,
        cause: 'user_edit',
        ui_source: 'set_done_toggle',
        idempotency_key: idempotencyKey,
        client_timestamp: clientTimestamp || null,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      };

      // 3m. Write workout update + event inside transaction
      tx.update(workoutRef, {
        exercises: updatedExercises,
        totals,
        version: nextVersion,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(eventRef, event);

      // 3n. Build response and store idempotency
      const response = {
        success: true,
        event_id: eventRef.id,
        totals,
        version: nextVersion,
      };

      storeWorkoutIdempotentTx(tx, userId, workoutId, idempotencyKey, response);

      return response;
    });

    // 4. Handle duplicate (cached response from idempotency)
    if (result.duplicate) {
      return ok(res, result.response);
    }

    return ok(res, result);
  } catch (error) {
    // Structured errors thrown from inside the transaction
    if (error.httpCode) {
      return fail(res, error.code, error.message, error.details || null, error.httpCode);
    }
    console.error('log-set error:', error);
    return fail(res, 'INTERNAL', 'Failed to log set', { message: error.message }, 500);
  }
}

exports.logSet = onRequest(requireFlexibleAuth(logSetHandler));
