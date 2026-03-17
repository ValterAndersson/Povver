const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { listTemplates } = require('../shared/templates');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Get User Templates
 *
 * Thin HTTP wrapper — business logic lives in shared/templates.js
 *
 * SECURITY: Uses authenticated user ID only. Client-provided userId is IGNORED
 * to prevent data exfiltration (user A requesting user B's templates).
 */
async function getUserTemplatesHandler(req, res) {
  // P0 Security Fix: ONLY use authenticated user ID, ignore any client-provided userId
  const userId = req.user?.uid || req.auth?.uid;
  if (!userId) return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);

  try {
    const result = await listTemplates(db, userId);
    return ok(res, result);
  } catch (err) {
    return fail(res, ...mapErrorToResponse(err));
  }
}

exports.getUserTemplates = onRequest(requireFlexibleAuth(getUserTemplatesHandler));
