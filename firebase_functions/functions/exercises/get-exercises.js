const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { listExercises } = require('../shared/exercises');
const { logger } = require('firebase-functions');

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

/**
 * Firebase Function: Get All Exercises
 * Thin wrapper — business logic lives in shared/exercises.js
 */
async function getExercisesHandler(req, res) {
  try {
    const limit = parseInt(req.query.limit) || 200;
    const includeMerged = String(req.query.includeMerged || '').toLowerCase() === 'true';
    const canonicalOnly = includeMerged ? false : (String(req.query.canonicalOnly || 'true').toLowerCase() !== 'false');

    const result = await listExercises(db, { limit, canonicalOnly, includeMerged });

    return ok(res, { ...result, limit, canonicalOnly, includeMerged });
  } catch (error) {
    logger.error('[getExercises] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to get exercises', null, 500);
  }
}

exports.getExercises = onRequest(requireFlexibleAuth(getExercisesHandler)); 