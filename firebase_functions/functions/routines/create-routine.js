const { onRequest } = require('firebase-functions/v2/https');
const { logger } = require('firebase-functions');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { createRoutine } = require('../shared/routines');
const { mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

/**
 * Firebase Function: Create Routine
 *
 * Thin HTTP wrapper — business logic lives in shared/routines.js
 */
async function createRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routine } = req.body || {};

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
