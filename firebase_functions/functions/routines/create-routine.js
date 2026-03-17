const { onRequest } = require('firebase-functions/v2/https');
const { logger } = require('firebase-functions');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { createRoutine } = require('../shared/routines');
const { mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Create Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 *
 * Note: This handler reads userId from req.body (API-key lane pattern),
 * not from getAuthenticatedUserId. Preserving original behavior.
 */
async function createRoutineHandler(req, res) {
  const { userId, routine } = req.body || {};

  try {
    const result = await createRoutine(admin.firestore(), userId, routine);
    logger.info('[createRoutine] Created routine', {
      userId,
      routineId: result.routineId,
      activated: result.activated,
    });
    return ok(res, result);
  } catch (e) {
    logger.error('[createRoutine] Failed to create routine', { userId, error: e.message });
    return mapErrorToResponse(res, e);
  }
}

exports.createRoutine = onRequest(requireFlexibleAuth(createRoutineHandler));
