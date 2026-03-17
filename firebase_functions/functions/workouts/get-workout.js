const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getWorkout } = require('../shared/workouts');
const { mapErrorToResponse } = require('../shared/errors');

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
    return mapErrorToResponse(res, error);
  }
}

// Export Firebase Function
exports.getWorkout = onRequest(requireFlexibleAuth(getWorkoutHandler)); 