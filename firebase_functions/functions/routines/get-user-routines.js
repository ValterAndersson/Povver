const { onRequest } = require('firebase-functions/v2/https');
const { logger } = require('firebase-functions');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { listRoutines } = require('../shared/routines');
const { AuthenticationError, mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Get User Routines
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 */
async function getUserRoutinesHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return mapErrorToResponse(res, new AuthenticationError());

  try {
    const result = await listRoutines(admin.firestore(), userId);
    return ok(res, result);
  } catch (e) {
    logger.error('[getUserRoutines] Failed to get user routines', { userId, error: e.message });
    return mapErrorToResponse(res, e);
  }
}

exports.getUserRoutines = onRequest(requireFlexibleAuth(getUserRoutinesHandler));
