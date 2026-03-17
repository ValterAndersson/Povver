const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { resolveExercise } = require('../shared/exercises');
const { mapErrorToResponse } = require('../shared/errors');

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

/**
 * Firebase Function: Resolve Exercise
 * Thin wrapper — business logic lives in shared/exercises.js
 */
async function resolveExerciseHandler(req, res) {
  try {
    const q = req.query.q || req.body?.q || req.query.name || req.body?.name;
    if (!q) return fail(res, 'INVALID_ARGUMENT', 'Missing q');
    const context = req.body?.context || {};

    const result = await resolveExercise(db, { q, context });
    return ok(res, result);
  } catch (error) {
    return mapErrorToResponse(res, error);
  }
}

exports.resolveExercise = onRequest(requireFlexibleAuth(resolveExerciseHandler));


