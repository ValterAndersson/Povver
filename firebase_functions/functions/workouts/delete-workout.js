/**
 * =============================================================================
 * delete-workout.js - Permanently Delete a Completed Workout
 * =============================================================================
 *
 * Thin HTTP wrapper — business logic lives in shared/workouts.js
 *
 * AUTH: requireFlexibleAuth (Bearer lane — iOS app calls)
 * userId derived from req.auth.uid, never from client body.
 *
 * The existing onWorkoutDeleted Firestore trigger in triggers/weekly-analytics.js
 * handles rolling back weekly_stats automatically.
 *
 * CALLED BY:
 * - iOS: WorkoutRepository.deleteWorkout()
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { deleteWorkout } = require('../shared/workouts');

const db = admin.firestore();

async function deleteWorkoutHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const userId = req.user?.uid || req.auth?.uid;
    if (!userId) return res.status(401).json({ success: false, error: 'Unauthorized' });

    const { workout_id } = req.body || {};
    const result = await deleteWorkout(db, userId, workout_id);
    return ok(res, result);
  } catch (error) {
    if (error.code && error.http) {
      return fail(res, error.code, error.message, null, error.http);
    }
    console.error('delete-workout error:', error);
    return fail(res, 'INTERNAL', 'Failed to delete workout', { message: error.message }, 500);
  }
}

exports.deleteWorkout = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(deleteWorkoutHandler)
);
