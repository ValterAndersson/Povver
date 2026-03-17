const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getWorkout } = require('../shared/workouts');

const db = admin.firestore();

/**
 * Firebase Function: Get Specific Workout
 *
 * Thin HTTP wrapper — business logic lives in shared/workouts.js
 */
async function getWorkoutHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  const workoutId = req.query.workoutId || req.body?.workoutId;

  try {
    const result = await getWorkout(db, userId, workoutId);
    return ok(res, result);
  } catch (error) {
    if (error.code && error.http) {
      return fail(res, error.code, error.message, null, error.http);
    }
    console.error('get-workout function error:', error);
    return fail(res, 'INTERNAL', 'Failed to get workout', { message: error.message }, 500);
  }
}

// Export Firebase Function
exports.getWorkout = onRequest(requireFlexibleAuth(getWorkoutHandler)); 