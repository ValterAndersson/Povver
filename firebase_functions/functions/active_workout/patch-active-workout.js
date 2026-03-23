/**
 * patchActiveWorkout - Edit values, add/remove sets
 *
 * Per FOCUS_MODE_WORKOUT_EXECUTION.md spec:
 * - Supports set_field, add_set, remove_set ops
 * - Enforces homogeneous request constraint (one op type per request, same set for set_field)
 * - AI scope validation for user_ai_action cause
 * - Recomputes totals and writes events
 * - Uses workout-scoped idempotency with response caching
 *
 * CONCURRENCY: All reads and writes are inside a Firestore transaction
 * to prevent lost updates from concurrent requests.
 */
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');

// Function options - allow public invocations (auth handled at application level)
const functionOptions = {
  invoker: 'public',
};
const admin = require('firebase-admin');
const { fail, ok } = require('../utils/response');
const { PatchActiveWorkoutSchema } = require('../utils/validators');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const {
  ensureWorkoutIdempotent,
  storeWorkoutIdempotentTx
} = require('../utils/idempotency');
const { computeTotals, findExercise, findSet } = require('../utils/active-workout-helpers');

const db = admin.firestore();

/**
 * Validate homogeneous request constraint
 */
function validateHomogeneous(ops) {
  if (ops.length === 0) return { valid: false, error: 'No ops provided' };

  const opTypes = new Set(ops.map(op => op.op));

  // Only one op type allowed
  if (opTypes.size > 1) {
    return { valid: false, error: 'MIXED_OP_TYPES', message: 'Cannot mix different op types in one request' };
  }

  const opType = ops[0].op;

  // For set_field, all ops must target same set
  if (opType === 'set_field') {
    const targets = new Set(ops.map(op => `${op.target.exercise_instance_id}:${op.target.set_id}`));
    if (targets.size > 1) {
      return { valid: false, error: 'MULTI_SET_EDIT', message: 'set_field ops must target the same set' };
    }
  }

  // For add_set, remove_set, remove_exercise, reorder_exercises, set_workout_field, and set_exercise_field, only one op allowed
  if ((opType === 'add_set' || opType === 'remove_set' || opType === 'remove_exercise' || opType === 'reorder_exercises' || opType === 'set_workout_field' || opType === 'set_exercise_field') && ops.length > 1) {
    return { valid: false, error: 'MULTIPLE_STRUCTURAL_OPS', message: `Only one ${opType} op allowed per request` };
  }

  return { valid: true, opType };
}

/**
 * Validate AI scope restrictions
 */
function validateAIScope(ops, aiScope, exercises) {
  const scopeExerciseId = aiScope.exercise_instance_id;

  for (const op of ops) {
    const targetExerciseId = op.target.exercise_instance_id;

    // Must be within scope
    if (targetExerciseId !== scopeExerciseId) {
      return { valid: false, error: 'PERMISSION_DENIED', message: 'AI action outside scope' };
    }

    if (op.op === 'set_field') {
      // Find the set to check status
      const exFound = findExercise(exercises, targetExerciseId);
      if (!exFound) continue;

      const setFound = findSet(exFound.exercise, op.target.set_id);
      if (!setFound) continue;

      // AI cannot modify done or skipped sets
      if (setFound.set.status === 'done' || setFound.set.status === 'skipped') {
        return { valid: false, error: 'PERMISSION_DENIED', message: 'AI cannot modify completed sets' };
      }

      // AI cannot modify status, set_type, or tags
      if (['status', 'set_type', 'tags.is_failure'].includes(op.field)) {
        return { valid: false, error: 'PERMISSION_DENIED', message: `AI cannot modify ${op.field}` };
      }
    }

    // AI cannot remove sets (but can remove exercises within scope)
    if (op.op === 'remove_set') {
      return { valid: false, error: 'PERMISSION_DENIED', message: 'AI cannot remove sets' };
    }
  }

  return { valid: true };
}

/**
 * Apply set_field operation (pure function)
 */
function applySetField(exercises, op) {
  const { exercise_instance_id: exId, set_id: setId } = op.target;
  const { field, value } = op;

  return exercises.map(ex => {
    if (ex.instance_id !== exId) return ex;
    return {
      ...ex,
      sets: ex.sets.map(s => {
        if (s.id !== setId) return s;
        if (field === 'tags.is_failure') {
          return { ...s, tags: { ...s.tags, is_failure: value } };
        }
        return { ...s, [field]: value };
      }),
    };
  });
}

/**
 * Apply add_set operation (pure function)
 */
function applyAddSet(exercises, op) {
  const { exercise_instance_id: exId } = op.target;
  const newSet = { ...op.value, tags: op.value.tags || {} };

  return exercises.map(ex => {
    if (ex.instance_id !== exId) return ex;
    return {
      ...ex,
      sets: [...ex.sets, newSet],
    };
  });
}

/**
 * Apply remove_set operation (pure function)
 */
function applyRemoveSet(exercises, op) {
  const { exercise_instance_id: exId, set_id: setId } = op.target;

  return exercises.map(ex => {
    if (ex.instance_id !== exId) return ex;
    return {
      ...ex,
      sets: ex.sets.filter(s => s.id !== setId),
    };
  });
}

/**
 * Apply remove_exercise operation (pure function)
 */
function applyRemoveExercise(exercises, op) {
  const { exercise_instance_id: exId } = op.target;
  return exercises.filter(ex => ex.instance_id !== exId);
}

async function patchActiveWorkoutHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    // User ID from Firebase Auth or API key middleware
    const userId = getAuthenticatedUserId(req);

    // 1. Validate request (pure — no Firestore reads)
    const parsed = PatchActiveWorkoutSchema.safeParse(req.body || {});
    if (!parsed.success) {
      return fail(res, 'INVALID_ARGUMENT', 'Invalid request', parsed.error.flatten(), 400);
    }

    const {
      workout_id: workoutId,
      ops,
      cause,
      ui_source: uiSource,
      idempotency_key: idempotencyKey,
      client_timestamp: clientTimestamp,
      ai_scope: aiScope,
    } = parsed.data;

    // 2. Validate homogeneous constraint (pure — checks request body only)
    const homoResult = validateHomogeneous(ops);
    if (!homoResult.valid) {
      return fail(res, homoResult.error, homoResult.message, null, 400);
    }

    // 3. Pre-generate refs outside transaction
    const workoutRef = db.doc(`users/${userId}/active_workouts/${workoutId}`);
    const eventRef = db.collection(`users/${userId}/active_workouts/${workoutId}/events`).doc();

    // 4. Run everything in a transaction
    const result = await db.runTransaction(async (tx) => {
      // 4a. Check idempotency inside transaction
      const idem = await ensureWorkoutIdempotent(tx, userId, workoutId, idempotencyKey);
      if (idem.isDuplicate && idem.cachedResponse) {
        return { duplicate: true, response: idem.cachedResponse };
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

      // 4c. Validate AI scope if applicable
      if (cause === 'user_ai_action') {
        const scopeResult = validateAIScope(ops, aiScope, workout.exercises || []);
        if (!scopeResult.valid) {
          throw { httpCode: 403, code: scopeResult.error, message: scopeResult.message };
        }
      }

      // 4d. Validate targets exist and apply ops
      let exercises = [...workout.exercises];
      const { opType } = homoResult;
      const diffOps = [];
      const fieldsChanged = [];

      if (opType === 'set_field') {
        const target = ops[0].target;
        const exFound = findExercise(exercises, target.exercise_instance_id);
        if (!exFound) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise not found', details: { exercise_instance_id: target.exercise_instance_id } };
        }

        const setFound = findSet(exFound.exercise, target.set_id);
        if (!setFound) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Set not found', details: { set_id: target.set_id } };
        }

        // Validate status transitions
        for (const op of ops) {
          if (op.field === 'status') {
            const currentStatus = setFound.set.status;
            const newStatus = op.value;

            if (currentStatus === 'planned' && newStatus === 'done') {
              throw { httpCode: 400, code: 'VALIDATION_ERROR', message: 'Use logSet to mark sets as done' };
            }
            if (currentStatus === 'done' && newStatus === 'skipped') {
              throw { httpCode: 400, code: 'VALIDATION_ERROR', message: 'Cannot change done to skipped' };
            }
            if (currentStatus === 'skipped' && newStatus === 'done') {
              throw { httpCode: 400, code: 'VALIDATION_ERROR', message: 'Cannot mark skipped as done. Unskip first, then use logSet.' };
            }
          }

          // Validate reps range for planned sets
          if (op.field === 'reps' && cause === 'user_edit') {
            const currentStatus = setFound.set.status;
            if (currentStatus === 'planned' && (op.value < 1 || op.value > 30)) {
              throw { httpCode: 400, code: 'VALIDATION_ERROR', message: 'Planned sets must have reps 1-30' };
            }
          }
        }

        // Apply all set_field ops
        for (const op of ops) {
          exercises = applySetField(exercises, op);
          diffOps.push({
            op: 'replace',
            path: `/exercises/${exFound.index}/sets/${setFound.index}/${op.field.replace('.', '/')}`,
            value: op.value,
          });
          fieldsChanged.push(op.field);
        }
      }

      if (opType === 'add_set') {
        const op = ops[0];
        const exFound = findExercise(exercises, op.target.exercise_instance_id);
        if (!exFound) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise not found' };
        }

        // Check for duplicate set ID
        const duplicateSet = exFound.exercise.sets?.find(s => s.id === op.value.id);
        if (duplicateSet) {
          throw { httpCode: 400, code: 'DUPLICATE_SET_ID', message: 'Set ID already exists in workout' };
        }

        exercises = applyAddSet(exercises, op);
        diffOps.push({
          op: 'add',
          path: `/exercises/${exFound.index}/sets/-`,
          value: op.value,
        });
      }

      if (opType === 'remove_set') {
        const op = ops[0];
        const exFound = findExercise(exercises, op.target.exercise_instance_id);
        if (!exFound) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise not found' };
        }
        const setFound = findSet(exFound.exercise, op.target.set_id);
        if (!setFound) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Set not found' };
        }

        exercises = applyRemoveSet(exercises, op);
        diffOps.push({
          op: 'remove',
          path: `/exercises/${exFound.index}/sets/${setFound.index}`,
        });
      }

      if (opType === 'remove_exercise') {
        const op = ops[0];
        const exFound = findExercise(exercises, op.target.exercise_instance_id);
        if (!exFound) {
          throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: 'Exercise not found' };
        }

        exercises = applyRemoveExercise(exercises, op);

        // Update positions after removal
        exercises = exercises.map((ex, idx) => ({ ...ex, position: idx }));

        diffOps.push({
          op: 'remove',
          path: `/exercises/${exFound.index}`,
        });
      }

      if (opType === 'reorder_exercises') {
        const op = ops[0];
        const newOrder = op.value?.order;

        if (!Array.isArray(newOrder) || newOrder.length === 0) {
          throw { httpCode: 400, code: 'INVALID_ARGUMENT', message: 'reorder_exercises requires order array' };
        }

        // Validate all exercise IDs exist
        const existingIds = new Set(exercises.map(e => e.instance_id));
        for (const id of newOrder) {
          if (!existingIds.has(id)) {
            throw { httpCode: 404, code: 'TARGET_NOT_FOUND', message: `Exercise not found: ${id}` };
          }
        }

        // Create lookup map for new positions
        const orderMap = {};
        newOrder.forEach((id, idx) => {
          orderMap[id] = idx;
        });

        // Sort exercises by new order and update positions
        exercises = exercises
          .sort((a, b) => (orderMap[a.instance_id] ?? 999) - (orderMap[b.instance_id] ?? 999))
          .map((ex, idx) => ({ ...ex, position: idx }));

        diffOps.push({
          op: 'replace',
          path: '/exercises',
          value: newOrder,
        });
      }

      if (opType === 'set_exercise_field') {
        const op = ops[0];
        const { exercise_instance_id } = op.target;
        const { field, value } = op;
        const exerciseIndex = exercises.findIndex(
          (ex) => ex.instance_id === exercise_instance_id
        );
        if (exerciseIndex === -1) {
          throw { httpCode: 404, code: 'NOT_FOUND', message: 'Exercise not found', details: { exercise_instance_id } };
        }
        const normalizedValue = (typeof value === 'string' && value.trim().length > 0) ? value.trim() : null;
        exercises[exerciseIndex][field] = normalizedValue;
        fieldsChanged.push(`exercise.${exercise_instance_id}.${field}`);

        diffOps.push({
          op: 'replace',
          path: `/exercises/${exerciseIndex}/${field}`,
          value: normalizedValue,
        });
      }

      // Handle workout-level field updates (name, start_time, notes)
      let workoutFieldUpdates = {};
      if (opType === 'set_workout_field') {
        const op = ops[0];
        const { field, value } = op;

        if (field === 'start_time') {
          const parsedDate = new Date(value);
          if (isNaN(parsedDate.getTime())) {
            throw { httpCode: 400, code: 'VALIDATION_ERROR', message: 'Invalid start_time format' };
          }
          workoutFieldUpdates.start_time = admin.firestore.Timestamp.fromDate(parsedDate);
          fieldsChanged.push('start_time');
        } else if (field === 'name') {
          if (typeof value !== 'string' || value.trim().length === 0) {
            throw { httpCode: 400, code: 'VALIDATION_ERROR', message: 'Invalid name' };
          }
          workoutFieldUpdates.name = value.trim();
          fieldsChanged.push('name');
        } else if (field === 'notes') {
          workoutFieldUpdates.notes = (typeof value === 'string' && value.trim().length > 0)
            ? value.trim() : null;
          fieldsChanged.push('notes');
        }

        diffOps.push({
          op: 'replace',
          path: `/${field}`,
          value: value,
        });
      }

      // 4e. Recompute totals
      const totals = computeTotals(exercises);

      // 4f. Determine event type
      let eventType;
      if (opType === 'set_field') {
        eventType = 'set_updated';
      } else if (opType === 'add_set') {
        eventType = 'set_added';
      } else if (opType === 'remove_set') {
        eventType = 'set_removed';
      } else if (opType === 'remove_exercise') {
        eventType = 'exercise_removed';
      } else if (opType === 'reorder_exercises') {
        eventType = 'exercises_reordered';
      } else {
        eventType = 'workout_updated';
      }

      // 4g. Build event payload
      let eventPayload;
      if (opType === 'reorder_exercises') {
        eventPayload = {
          new_order: ops[0].value?.order || [],
        };
      } else {
        eventPayload = {
          exercise_instance_id: ops[0].target?.exercise_instance_id || null,
          set_id: ops[0].target?.set_id || ops[0].value?.id || null,
        };
      }
      if (fieldsChanged.length > 0) eventPayload.fields_changed = fieldsChanged;

      // 4h. Version increment
      const nextVersion = (workout.version || 0) + 1;

      const event = {
        id: eventRef.id,
        type: eventType,
        payload: eventPayload,
        diff_ops: diffOps,
        cause,
        ui_source: uiSource,
        idempotency_key: idempotencyKey,
        client_timestamp: clientTimestamp || null,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      };

      // 4i. Write workout update + event
      tx.update(workoutRef, {
        exercises,
        totals,
        version: nextVersion,
        ...workoutFieldUpdates,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(eventRef, event);

      // 4j. Build response and store idempotency
      const response = {
        success: true,
        event_id: eventRef.id,
        totals,
        version: nextVersion,
      };

      storeWorkoutIdempotentTx(tx, userId, workoutId, idempotencyKey, response);

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
    console.error('patch-active-workout error:', error);
    return fail(res, 'INTERNAL', 'An internal error occurred', null, 500);
  }
}

exports.patchActiveWorkout = onRequest(functionOptions, requireFlexibleAuth(patchActiveWorkoutHandler));
