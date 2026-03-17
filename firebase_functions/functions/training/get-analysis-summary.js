/**
 * Analysis Summary Endpoint — thin wrapper
 * Business logic lives in shared/training-queries.js
 *
 * Uses onRequest (not onCall) for compatibility with HTTP clients.
 * Bearer auth (iOS + agent)
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getAnalysisSummary: getAnalysisSummaryCore } = require('../shared/training-queries');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * getAnalysisSummary
 * Returns pre-computed analysis data from multiple collections
 */
exports.getAnalysisSummary = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return fail(res, 'MISSING_USER_ID', 'userId is required', null, 400);
    }

    const result = await getAnalysisSummaryCore(db, userId, req.body || {}, admin);
    return ok(res, result);

  } catch (error) {
    logger.error('[getAnalysisSummary] Error', { error: error.message });
    return fail(res, 'INTERNAL_ERROR', error.message, null, 500);
  }
}));
