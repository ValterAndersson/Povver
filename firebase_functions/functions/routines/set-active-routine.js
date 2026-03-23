const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { setActiveRoutine } = require('../shared/routines');
const { mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Set Active Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 */
async function setActiveRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routineId } = req.body || {};

  try {
    const result = await setActiveRoutine(admin.firestore(), userId, routineId);
    return ok(res, result);
  } catch (e) {
    console.error('set-active-routine function error:', e);
    return mapErrorToResponse(res, e);
  }
}

exports.setActiveRoutine = onRequest(requireFlexibleAuth(setActiveRoutineHandler));
