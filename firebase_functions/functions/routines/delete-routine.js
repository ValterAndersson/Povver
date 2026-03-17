const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { deleteRoutine } = require('../shared/routines');
const { mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Delete Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 *
 * Note: This handler reads userId from req.body (API-key lane pattern).
 */
async function deleteRoutineHandler(req, res) {
  const { userId, routineId } = req.body || {};

  try {
    const result = await deleteRoutine(admin.firestore(), userId, routineId);
    return ok(res, result);
  } catch (e) {
    console.error('delete-routine function error:', e);
    return mapErrorToResponse(res, e);
  }
}

exports.deleteRoutine = onRequest(requireFlexibleAuth(deleteRoutineHandler));
