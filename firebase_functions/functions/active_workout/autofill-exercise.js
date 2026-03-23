/**
 * autofillExercise - AI bulk prescription for a single exercise
 *
 * Per FOCUS_MODE_WORKOUT_EXECUTION.md spec:
 * - Updates existing planned sets and/or adds new sets
 * - Only targets planned sets (done/skipped are protected)
 * - Validates all values (reps 1-30, rir 0-5, weight >= 0 or null)
 * - Max 8 sets per exercise after additions
 * - Writes single 'autofill_applied' event
 *
 * CONCURRENCY: All reads and writes are inside a Firestore transaction
 * to prevent lost updates from concurrent requests.
 */
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { fail, ok } = require('../utils/response');
const { AutofillExerciseSchema } = require('../utils/validators');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const {
  ensureWorkoutIdempotent,
  storeWorkoutIdempotentTx
} = require('../utils/idempotency');
const { computeTotals } = require('../utils/active-workout-helpers');

const db = admin.firestore();

const MAX_SETS_PER_EXERCISE = 8;

async function autofillExerciseHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    // User ID from Firebase Auth or API key middleware
    const userId = getAuthenticatedUserId(req);

    // 1. Validate request (pure — no Firestore reads)
    const parsed = AutofillExerciseSchema.safeParse(req.body || {});
    if (!parsed.success) {
      return fail(res, 'INVALID_ARGUMENT', 'Invalid request', parsed.error.flatten(), 400);
    }

    const {
      workout_id: workoutId,
      exercise_instance_id: exerciseInstanceId,
      updates = [],
      additions = [],
      idempotency_key: idempotencyKey,
      client_timestamp: clientTimestamp,
    } = parsed.data;

    // 2. Pre-generate refs outside transaction
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

      if (workout.status !== 'in_progress') {
        throw { httpCode: 400, code: 'INVALID_STATE', message: 'Workout is not in progress' };
      }

      // 3c. Find target exercise
      let exerciseIndex = -1;
      let targetExercise = null;
      for (let i = 0; i < (workout.exercises || []).length; i++) {
        if (workout.exercises[i].instance_id === exerciseInstanceId) {
          exerciseIndex = i;
          targetExercise = workout.exercises[i];
          break;
        }
      }

      if (!targetExercise) {
        throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise not found', details: { exercise_instance_id: exerciseInstanceId } };
      }

      // 3d. Build a map of current sets
      const currentSets = [...(targetExercise.sets || [])];
      const setMap = new Map();
      for (const set of currentSets) {
        setMap.set(set.id, set);
      }

      // 3e. Validate and apply updates
      const setsUpdated = [];
      const diffOps = [];

      for (const update of updates) {
        const existingSet = setMap.get(update.set_id);
        if (!existingSet) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: `Set not found: ${update.set_id}` };
        }

        // AI can only update planned sets
        if (existingSet.status !== 'planned') {
          throw { httpCode: 403, code: 'PERMISSION_DENIED', message: 'AI can only update planned sets', details: { set_id: update.set_id } };
        }

        // Validate AI output bounds
        if (update.reps !== undefined && update.reps !== null && (update.reps < 0 || update.reps > 100)) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'AI prescribed invalid reps (must be 0-100)', details: { reps: update.reps } };
        }
        if (update.rir !== undefined && update.rir !== null && (update.rir < 0 || update.rir > 5)) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'AI prescribed invalid RIR (must be 0-5)', details: { rir: update.rir } };
        }
        if (update.weight !== undefined && update.weight !== null && update.weight < 0) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'AI prescribed invalid weight (must be >= 0)', details: { weight: update.weight } };
        }

        // Apply updates
        if (update.weight !== undefined) {
          existingSet.weight = update.weight;
        }
        if (update.reps !== undefined) {
          existingSet.reps = update.reps;
        }
        if (update.rir !== undefined) {
          existingSet.rir = update.rir;
        }

        setsUpdated.push(update.set_id);
      }

      // 3f. Validate additions
      const setsAdded = [];

      // Check max sets constraint
      const totalSetsAfterAdditions = currentSets.length + additions.length;
      if (totalSetsAfterAdditions > MAX_SETS_PER_EXERCISE) {
        throw {
          httpCode: 400,
          code: 'VALIDATION_ERROR',
          message: `Max ${MAX_SETS_PER_EXERCISE} sets per exercise`,
          details: { current: currentSets.length, adding: additions.length, max: MAX_SETS_PER_EXERCISE }
        };
      }

      // Check for duplicate IDs
      const allSetIds = new Set(currentSets.map(s => s.id));
      for (const addition of additions) {
        if (allSetIds.has(addition.id)) {
          throw { httpCode: 400, code: 'DUPLICATE_SET_ID', message: `Set ID already exists: ${addition.id}` };
        }
        allSetIds.add(addition.id);
      }

      // Add new sets with validation
      for (const addition of additions) {
        // Validate AI output bounds
        if (addition.reps !== undefined && addition.reps !== null && (addition.reps < 0 || addition.reps > 100)) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'AI prescribed invalid reps (must be 0-100)', details: { reps: addition.reps } };
        }
        if (addition.rir !== undefined && addition.rir !== null && (addition.rir < 0 || addition.rir > 5)) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'AI prescribed invalid RIR (must be 0-5)', details: { rir: addition.rir } };
        }
        if (addition.weight !== undefined && addition.weight !== null && addition.weight < 0) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'AI prescribed invalid weight (must be >= 0)', details: { weight: addition.weight } };
        }

        const newSet = {
          id: addition.id,
          set_type: addition.set_type,
          reps: addition.reps,
          rir: addition.rir,
          weight: addition.weight,
          status: 'planned',
          tags: {},
        };
        currentSets.push(newSet);
        setsAdded.push(addition.id);
      }

      // 3g. Update exercise in workout
      const updatedExercises = workout.exercises.map((ex, idx) => {
        if (idx !== exerciseIndex) return ex;
        return {
          ...ex,
          sets: currentSets,
        };
      });

      // 3h. Totals computation - autofill only touches planned sets, totals unchanged
      const totals = workout.totals || computeTotals(updatedExercises);

      // 3i. Version increment
      const nextVersion = (workout.version || 0) + 1;

      // 3j. Build event
      const eventPayload = {
        exercise_instance_id: exerciseInstanceId,
      };
      if (setsUpdated.length > 0) eventPayload.sets_updated = setsUpdated;
      if (setsAdded.length > 0) eventPayload.sets_added = setsAdded;

      const event = {
        id: eventRef.id,
        type: 'autofill_applied',
        payload: eventPayload,
        diff_ops: diffOps,
        cause: 'user_ai_action',
        ui_source: 'ai_button',
        idempotency_key: idempotencyKey,
        client_timestamp: clientTimestamp || null,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      };

      // 3k. Write workout update + event
      tx.update(workoutRef, {
        exercises: updatedExercises,
        totals,
        version: nextVersion,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(eventRef, event);

      // 3l. Build response and store idempotency
      const response = {
        success: true,
        event_id: eventRef.id,
        totals,
        version: nextVersion,
      };

      storeWorkoutIdempotentTx(tx, userId, workoutId, idempotencyKey, response);

      return response;
    });

    // 4. Handle duplicate
    if (result.duplicate) {
      return ok(res, result.response);
    }

    return ok(res, result);
  } catch (error) {
    if (error.httpCode) {
      return fail(res, error.code, error.message, error.details || null, error.httpCode);
    }
    console.error('autofill-exercise error:', error);
    return fail(res, 'INTERNAL', 'Failed to autofill exercise', { message: error.message }, 500);
  }
}

exports.autofillExercise = onRequest(requireFlexibleAuth(autofillExerciseHandler));
