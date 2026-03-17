const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { getExercise } = require('../shared/exercises');
const { mapErrorToResponse } = require('../shared/errors');

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

/**
 * Firebase Function: Get Specific Exercise
 * Thin wrapper — business logic lives in shared/exercises.js
 */
async function getExerciseHandler(req, res) {
  const exerciseId = req.query.exerciseId || req.body?.exerciseId;
  const name = req.query.name || req.body?.name;
  const slug = req.query.slug || req.body?.slug;

  if (!exerciseId && !name && !slug) {
    return fail(res, 'INVALID_ARGUMENT', 'Provide exerciseId or name or slug');
  }

  try {
    const exercise = await getExercise(db, { exerciseId, name, slug });

    if (!exercise) {
      return fail(res, 'NOT_FOUND', 'Exercise not found', { exerciseId, name, slug }, 404);
    }

    return ok(res, exercise);
  } catch (error) {
    return mapErrorToResponse(res, error);
  }
}

exports.getExercise = onRequest(requireFlexibleAuth(getExerciseHandler)); 