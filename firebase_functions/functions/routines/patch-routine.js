const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { patchRoutine } = require('../shared/routines');
const { AuthenticationError, mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Patch Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 */
async function patchRoutineHandler(req, res) {
  const callerUid = getAuthenticatedUserId(req);
  if (!callerUid) return mapErrorToResponse(res, new AuthenticationError());

  const { routineId, patch } = req.body;

  try {
    const result = await patchRoutine(admin.firestore(), callerUid, routineId, patch);
    return ok(res, result);
  } catch (e) {
    console.error('patch-routine function error:', e);
    return mapErrorToResponse(res, e);
  }
}

exports.patchRoutine = requireFlexibleAuth(patchRoutineHandler);
