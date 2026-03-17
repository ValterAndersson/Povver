/**
 * Query Sets Endpoint — thin wrapper
 * Business logic lives in shared/training-queries.js
 *
 * Uses onRequest (not onCall) for compatibility with HTTP clients.
 * Bearer auth (iOS + agent)
 *
 * @see docs/TRAINING_ANALYTICS_API_V2_SPEC.md Section 6.1
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ValidationError } = require('../shared/errors');
const { querySets: querySetsCore, aggregateSets: aggregateSetsCore } = require('../shared/training-queries');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * training.sets.query
 */
exports.querySets = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return fail(res, 'MISSING_USER_ID', 'userId is required', null, 400);
    }

    const result = await querySetsCore(db, userId, req.body || {});
    return ok(res, result);

  } catch (error) {
    if (error instanceof ValidationError) {
      return fail(res, 'INVALID_ARGUMENT', error.message, error.details, 400);
    }
    console.error('Error in querySets:', error);
    return fail(res, 'INTERNAL', error.message, null, 500);
  }
}));

/**
 * training.sets.aggregate
 */
exports.aggregateSets = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return fail(res, 'MISSING_USER_ID', 'userId is required', null, 400);
    }

    const result = await aggregateSetsCore(db, userId, req.body || {});
    return ok(res, result);

  } catch (error) {
    if (error instanceof ValidationError) {
      return fail(res, 'INVALID_ARGUMENT', error.message, error.details, 400);
    }
    console.error('Error in aggregateSets:', error);
    return fail(res, 'INTERNAL', error.message, null, 500);
  }
}));
