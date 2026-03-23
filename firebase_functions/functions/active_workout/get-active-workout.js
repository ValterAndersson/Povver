/**
 * =============================================================================
 * get-active-workout.js - Retrieve Current Active Workout
 * =============================================================================
 *
 * PURPOSE:
 * Returns the current in_progress active workout for a user.
 * Uses the lock document as the canonical pointer for consistency.
 *
 * DUAL LOOKUP PATHS:
 * A. Direct ID lookup (workout_id param):
 *    1. If workout_id provided, fetch directly from active_workouts subcollection
 *    2. If doc exists and status is in_progress, return it (skip lock entirely)
 *    3. If not found or wrong status, fall through to lock-based resolution
 *
 * B. Lock-based resolution (default):
 *    1. Read lock doc (users/{uid}/meta/active_workout_state)
 *    2. If lock has active_workout_id, read that workout
 *    3. If workout missing or not in_progress, self-heal by clearing lock
 *    4. Fallback: query for any in_progress workout (repair orphans)
 *    5. Return workout or null
 *
 * SELF-HEALING:
 * This endpoint repairs stale lock pointers automatically:
 * - If lock points to missing doc → clears lock
 * - If lock points to non-in_progress doc → clears lock
 * - If orphan in_progress workout found → repairs lock to point to it
 *
 * This ensures the resume gate in iOS always sees correct state.
 *
 * RESPONSE SHAPE:
 * {
 *   success: true,
 *   workout: { ... full workout doc ... } | null
 * }
 *
 * CALLED BY:
 * - iOS: FocusModeWorkoutService.getActiveWorkout()
 * - iOS: FocusModeWorkoutScreen resume gate
 *
 * RELATED FILES:
 * - start-active-workout.js: Creates workout and sets lock
 * - cancel-active-workout.js: Cancels workout and clears lock
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

async function getActiveWorkoutHandler(req, res) {
  try {
    if (req.method !== 'GET' && req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const userId = req.user?.uid || req.auth?.uid;
    if (!userId) {
      return fail(res, 'UNAUTHENTICATED', 'Unauthorized', null, 401);
    }

    const lockRef = firestore.collection('users').doc(userId).collection('meta').doc('active_workout_state');
    const activeWorkoutsRef = firestore.collection('users').doc(userId).collection('active_workouts');

    // ==========================================================================
    // STEP 0: Direct ID lookup (when agent passes workout_id from context)
    // The agent has workout_id from the context prefix but the lock doc may be
    // stale or cleared. Direct lookup avoids the lock entirely — no ownership
    // check needed because activeWorkoutsRef is already scoped to users/{userId}.
    // ==========================================================================
    const directWorkoutId = req.query.workout_id || req.body.workout_id;
    if (directWorkoutId) {
      const directDoc = await activeWorkoutsRef.doc(directWorkoutId).get();
      if (directDoc.exists && directDoc.data().status === 'in_progress') {
        return ok(res, {
          success: true,
          workout: { id: directDoc.id, ...directDoc.data() }
        });
      }
      // Direct ID miss (deleted or completed) — fall through to lock-based resolution
    }

    // ==========================================================================
    // STEP 1: Read lock document
    // ==========================================================================
    const lockDoc = await lockRef.get();
    const lockData = lockDoc.exists ? lockDoc.data() : { active_workout_id: null };

    // ==========================================================================
    // STEP 2: If lock has pointer, try to read that workout
    // ==========================================================================
    if (lockData.active_workout_id) {
      const workoutDoc = await activeWorkoutsRef.doc(lockData.active_workout_id).get();

      if (workoutDoc.exists && workoutDoc.data().status === 'in_progress') {
        // Valid active workout - return it
        return ok(res, {
          success: true,
          workout: { id: workoutDoc.id, ...workoutDoc.data() }
        });
      }

      // ==========================================================================
      // STEP 3: Stale pointer - self-heal by clearing lock
      // ==========================================================================
      console.log(`Clearing stale lock pointer to ${lockData.active_workout_id}`);
      await lockRef.set({
        active_workout_id: null,
        status: null,
        updated_at: new Date()
      });
    }

    // ==========================================================================
    // STEP 4: Fallback - query for any in_progress workout (repair orphans)
    // ==========================================================================
    const fallbackQuery = await activeWorkoutsRef
      .where('status', '==', 'in_progress')
      .limit(1)
      .get();

    if (!fallbackQuery.empty) {
      const workoutDoc = fallbackQuery.docs[0];

      // Repair lock to point to this orphan workout
      console.log(`Repairing lock to point to orphan workout ${workoutDoc.id}`);
      await lockRef.set({
        active_workout_id: workoutDoc.id,
        status: 'in_progress',
        updated_at: new Date()
      });

      return ok(res, {
        success: true,
        workout: { id: workoutDoc.id, ...workoutDoc.data() }
      });
    }

    // ==========================================================================
    // STEP 5: No active workout found
    // ==========================================================================
    return ok(res, { success: true, workout: null });

  } catch (error) {
    logger.error('[getActiveWorkout] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to get active workout', null, 500);
  }
}

exports.getActiveWorkout = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(getActiveWorkoutHandler)
);
