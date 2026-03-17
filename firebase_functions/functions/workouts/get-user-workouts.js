const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { listWorkouts } = require('../shared/workouts');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Get User Workouts
 *
 * Thin HTTP wrapper — business logic lives in shared/workouts.js
 */
async function getUserWorkoutsHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  const limit = parseInt(req.query?.limit) || 50;
  const startDate = req.query?.startDate;
  const endDate = req.query?.endDate;
  const cursor = req.query?.cursor || null;

  try {
    const result = await listWorkouts(db, userId, { limit, startDate, endDate, cursor });
    return ok(res, {
      items: result.items,
      analytics: result.analytics,
      hasMore: result.hasMore,
      nextCursor: result.nextCursor,
      filters: { userId, limit, startDate: startDate || null, endDate: endDate || null },
    });
  } catch (error) {
    return mapErrorToResponse(res, error);
  }
}

// Export Firebase Function
exports.getUserWorkouts = onRequest(requireFlexibleAuth(getUserWorkoutsHandler)); 