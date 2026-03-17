/**
 * Progress Summary Endpoints — thin wrappers
 * Business logic lives in shared/training-queries.js
 *
 * Uses onRequest (not onCall) for compatibility with HTTP clients.
 *
 * @see docs/TRAINING_ANALYTICS_API_V2_SPEC.md Section 6.4
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ValidationError } = require('../shared/errors');
const {
  getMuscleGroupSummary: getMuscleGroupSummaryCore,
  getMuscleSummary: getMuscleSummaryCore,
  getExerciseSummary: getExerciseSummaryCore,
} = require('../shared/training-queries');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * progress.muscle_group.summary
 */
exports.getMuscleGroupSummary = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return res.status(400).json({ success: false, error: 'userId is required' });
    }

    const result = await getMuscleGroupSummaryCore(db, userId, req.body || {});
    return res.json(result);

  } catch (error) {
    if (error instanceof ValidationError) {
      return res.status(400).json({
        success: false,
        error: error.message,
        ...(error.details || {}),
      });
    }
    console.error('Error in getMuscleGroupSummary:', error);
    return res.status(500).json({ success: false, error: 'Internal error' });
  }
}));

/**
 * progress.muscle.summary
 */
exports.getMuscleSummary = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return res.status(400).json({ success: false, error: 'userId is required' });
    }

    const result = await getMuscleSummaryCore(db, userId, req.body || {});
    return res.json(result);

  } catch (error) {
    if (error instanceof ValidationError) {
      return res.status(400).json({
        success: false,
        error: error.message,
        ...(error.details || {}),
      });
    }
    console.error('Error in getMuscleSummary:', error);
    return res.status(500).json({ success: false, error: 'Internal error' });
  }
}));

/**
 * progress.exercise.summary
 */
exports.getExerciseSummary = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return res.status(400).json({ success: false, error: 'userId is required' });
    }

    const result = await getExerciseSummaryCore(db, userId, req.body || {});
    return res.json(result);

  } catch (error) {
    if (error instanceof ValidationError) {
      return res.status(400).json({
        success: false,
        error: error.message,
      });
    }
    console.error('Error in getExerciseSummary:', error);
    return res.status(500).json({ success: false, error: 'Internal error' });
  }
}));
