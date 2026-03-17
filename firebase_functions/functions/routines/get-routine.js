const { onRequest } = require('firebase-functions/v2/https');
const { logger } = require('firebase-functions');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getRoutine } = require('../shared/routines');
const { mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Get Specific Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 */
async function getRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return mapErrorToResponse(res, new (require('../shared/errors').AuthenticationError)());

  const routineId = req.query.routineId || req.body?.routineId;

  try {
    const routine = await getRoutine(admin.firestore(), userId, routineId);
    return ok(res, routine);
  } catch (e) {
    logger.error('[getRoutine] Failed to get routine', { userId, routineId, error: e.message });
    return mapErrorToResponse(res, e);
  }
}

exports.getRoutine = onRequest(requireFlexibleAuth(getRoutineHandler));
