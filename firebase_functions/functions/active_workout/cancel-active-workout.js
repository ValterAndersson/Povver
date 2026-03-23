/**
 * =============================================================================
 * cancel-active-workout.js - Cancel/Discard Active Workout
 * =============================================================================
 *
 * PURPOSE:
 * Cancels an active workout by setting status to 'cancelled'.
 * Also clears the lock document if it points to this workout.
 *
 * LOCK CLEARING:
 * Uses a transaction to ensure the lock is cleared atomically with the
 * workout status update. This prevents the resume gate from showing a
 * cancelled workout.
 *
 * REQUEST BODY:
 * {
 *   workout_id: string (required)
 * }
 *
 * RESPONSE SHAPE:
 * {
 *   success: true,
 *   workout_id: string
 * }
 *
 * CALLED BY:
 * - iOS: FocusModeWorkoutScreen "Discard and Start New" button
 * - iOS: FocusModeWorkoutService.cancelWorkout()
 *
 * RELATED FILES:
 * - start-active-workout.js: Creates workout and sets lock
 * - get-active-workout.js: Returns current active workout
 * - complete-active-workout.js: Archives workout and clears lock
 *
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

const firestore = admin.firestore();

async function cancelActiveWorkoutHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const userId = req.user?.uid || req.auth?.uid;
    if (!userId) {
      return fail(res, 'UNAUTHENTICATED', 'Unauthorized', null, 401);
    }

    const { workout_id } = req.body || {};
    if (!workout_id) {
      return fail(res, 'INVALID_ARGUMENT', 'Missing workout_id', null, 400);
    }

    const lockRef = firestore.collection('users').doc(userId).collection('meta').doc('active_workout_state');
    const workoutRef = firestore.collection('users').doc(userId).collection('active_workouts').doc(workout_id);

    // ==========================================================================
    // TRANSACTIONAL CANCEL + LOCK CLEAR
    // ==========================================================================
    await firestore.runTransaction(async (tx) => {
      const workoutDoc = await tx.get(workoutRef);
      const lockDoc = await tx.get(lockRef);

      // Update workout status to cancelled
      if (workoutDoc.exists) {
        tx.update(workoutRef, {
          status: 'cancelled',
          end_time: admin.firestore.FieldValue.serverTimestamp(),
          updated_at: admin.firestore.FieldValue.serverTimestamp()
        });
        console.log(`Cancelled workout ${workout_id}`);
      } else {
        console.log(`Workout ${workout_id} not found, clearing lock anyway`);
      }

      // Clear lock if it points to this workout
      const lockData = lockDoc.exists ? lockDoc.data() : {};
      if (lockData.active_workout_id === workout_id) {
        tx.set(lockRef, {
          active_workout_id: null,
          status: 'cancelled',
          updated_at: admin.firestore.FieldValue.serverTimestamp()
        });
        console.log(`Cleared lock for cancelled workout ${workout_id}`);
      }
    });

    return ok(res, { success: true, workout_id });

  } catch (error) {
    logger.error('[cancelActiveWorkout] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to cancel active workout', null, 500);
  }
}

exports.cancelActiveWorkout = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(cancelActiveWorkoutHandler)
);
