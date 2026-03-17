const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getActiveRoutine } = require('../shared/routines');
const { ValidationError, mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Get Active Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 */
async function getActiveRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return mapErrorToResponse(res, new ValidationError('Missing userId parameter'));

  try {
    const result = await getActiveRoutine(admin.firestore(), userId);
    return ok(res, result);
  } catch (e) {
    console.error('get-active-routine function error:', e);
    return mapErrorToResponse(res, e);
  }
}

exports.getActiveRoutine = onRequest(requireFlexibleAuth(getActiveRoutineHandler));
