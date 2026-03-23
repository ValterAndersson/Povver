/**
 * addExercise - Add a new exercise to an active workout
 *
 * Per FOCUS_MODE_WORKOUT_EXECUTION.md spec:
 * - Adds exercise to exercises array with client-provided instance_id
 * - Creates event with exercise_added type
 * - Uses workout-scoped idempotency
 *
 * CONCURRENCY: All reads and writes are inside a Firestore transaction
 * to prevent lost updates from concurrent requests.
 */
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const {
  ensureWorkoutIdempotent,
  storeWorkoutIdempotentTx
} = require('../utils/idempotency');
const { logger } = require('firebase-functions');
const { z } = require('zod');
const { IdSchema } = require('../utils/validators');

const db = admin.firestore();

// Constants from validators.js
const MAX_NAME_LENGTH = 200;
const MAX_SETS_PER_EXERCISE = 100;
const MAX_REPS = 500;
const MAX_WEIGHT_KG = 1500;

// Validation schema for add-exercise request
const AddExerciseSchema = z.object({
  workout_id: IdSchema,
  instance_id: IdSchema,
  exercise_id: IdSchema,
  name: z.string().max(MAX_NAME_LENGTH).optional(),
  position: z.number().int().nonnegative().optional(),
  sets: z.array(z.object({
    id: IdSchema.optional(),
    set_type: z.enum(['warmup', 'working', 'dropset']).optional(),
    status: z.enum(['planned', 'in_progress', 'completed', 'skipped']).optional(),
    target_reps: z.number().int().min(0).max(MAX_REPS).optional(),
    reps: z.number().int().min(0).max(MAX_REPS).optional(),
    target_rir: z.number().int().min(0).max(5).optional(),
    rir: z.number().int().min(0).max(5).optional(),
    target_weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable().optional(),
    weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable().optional(),
    tags: z.record(z.any()).optional(),
  })).max(MAX_SETS_PER_EXERCISE).optional(),
  idempotency_key: IdSchema.optional(),
  client_timestamp: z.string().optional(),
});

// Function options - allow public invocations (auth handled at application level)
const functionOptions = {
  invoker: 'public',
};

async function addExerciseHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const userId = getAuthenticatedUserId(req);

    // Validate input
    const parseResult = AddExerciseSchema.safeParse(req.body);
    if (!parseResult.success) {
      return fail(res, 'INVALID_INPUT', 'Invalid request data', null, 400);
    }

    // 1. Parse and validate required fields (pure — no Firestore reads)
    const {
      workout_id: workoutId,
      instance_id: instanceId,
      exercise_id: exerciseId,
      name,
      position,
      sets,
      idempotency_key: idempotencyKey,
      client_timestamp: clientTimestamp,
    } = parseResult.data;

    // 2. Process sets outside transaction (pure transformation)
    const processedSets = [];
    for (const set of (sets || [])) {
      const reps = set.target_reps ?? set.reps ?? null;
      const rir = set.target_rir ?? set.rir ?? null;
      const weight = set.target_weight ?? set.weight ?? null;

      processedSets.push({
        id: set.id,
        set_type: set.set_type || 'working',
        status: set.status || 'planned',
        weight,
        reps,
        rir,
        tags: set.tags || {},
      });
    }

    // 3. Pre-generate refs outside transaction
    const workoutRef = db.doc(`users/${userId}/active_workouts/${workoutId}`);
    const eventRef = db.collection(`users/${userId}/active_workouts/${workoutId}/events`).doc();

    // 4. Run everything in a transaction
    const result = await db.runTransaction(async (tx) => {
      // 4a. Check idempotency inside transaction
      if (idempotencyKey) {
        const idem = await ensureWorkoutIdempotent(tx, userId, workoutId, idempotencyKey);
        if (idem.isDuplicate && idem.cachedResponse) {
          return { duplicate: true, response: idem.cachedResponse };
        }
      }

      // 4b. Read workout
      const workoutSnap = await tx.get(workoutRef);
      if (!workoutSnap.exists) {
        throw { httpCode: 404, code: 'NOT_FOUND', message: 'Workout not found' };
      }

      const workout = workoutSnap.data();

      if (workout.status !== 'in_progress') {
        throw { httpCode: 400, code: 'INVALID_STATE', message: 'Workout is not in progress' };
      }

      // 4c. Check for duplicate instance_id
      const existingExercise = (workout.exercises || []).find(ex => ex.instance_id === instanceId);
      if (existingExercise) {
        throw { httpCode: 400, code: 'DUPLICATE_INSTANCE_ID', message: 'Exercise instance already exists' };
      }

      // 4d. Build new exercise object
      const exercisePosition = typeof position === 'number' ? position : (workout.exercises || []).length;

      const newExercise = {
        instance_id: instanceId,
        exercise_id: exerciseId,
        name: name || null,
        position: exercisePosition,
        sets: processedSets,
      };

      // 4e. Add to exercises array
      const updatedExercises = [...(workout.exercises || []), newExercise];

      // 4f. Version increment
      const nextVersion = (workout.version || 0) + 1;

      // 4g. Build event
      const event = {
        id: eventRef.id,
        type: 'exercise_added',
        payload: {
          exercise_instance_id: instanceId,
          exercise_id: exerciseId,
          name: name || null,
          position: exercisePosition,
          sets_count: processedSets.length,
        },
        diff_ops: [{
          op: 'add',
          path: `/exercises/-`,
          value: newExercise,
        }],
        cause: 'user_edit',
        ui_source: 'add_exercise_button',
        idempotency_key: idempotencyKey || null,
        client_timestamp: clientTimestamp || null,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      };

      // 4h. Write workout update + event
      tx.update(workoutRef, {
        exercises: updatedExercises,
        version: nextVersion,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(eventRef, event);

      // 4i. Build response and store idempotency
      const response = {
        success: true,
        exercise_instance_id: instanceId,
        event_id: eventRef.id,
        version: nextVersion,
      };

      if (idempotencyKey) {
        storeWorkoutIdempotentTx(tx, userId, workoutId, idempotencyKey, response);
      }

      return response;
    });

    // 5. Handle duplicate
    if (result.duplicate) {
      return ok(res, result.response);
    }

    return ok(res, result);
  } catch (error) {
    if (error.httpCode) {
      return fail(res, error.code, error.message, error.details || null, error.httpCode);
    }
    logger.error('[addExercise] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to add exercise', null, 500);
  }
}

exports.addExercise = onRequest(functionOptions, requireFlexibleAuth(addExerciseHandler));
