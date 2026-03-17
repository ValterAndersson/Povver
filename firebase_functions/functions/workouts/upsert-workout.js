/**
 * =============================================================================
 * upsert-workout.js - Create or Update Workout with Analytics & Set Facts
 * =============================================================================
 *
 * Thin HTTP wrapper — business logic lives in shared/workouts.js
 *
 * CALLED BY:
 * - scripts/import_strong_csv.js
 * - Any admin script needing to bulk-import workouts
 *
 * NOT EXPOSED TO:
 * - AI agents (uses requireFlexibleAuth, not agent-accessible)
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const AnalyticsCalc = require('../utils/analytics-calculator');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const {
  generateSetFactsForWorkout,
  writeSetFactsInChunks,
  updateSeriesForWorkout,
} = require('../training/set-facts-generator');
const { CAPS } = require('../utils/caps');
const { upsertWorkout } = require('../shared/workouts');
const { mapErrorToResponse } = require('../shared/errors');
const { enqueueWorkoutCompletion } = require('../utils/enqueue-workout-task');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * Main upsert handler — delegates to shared/workouts.upsertWorkout
 */
async function upsertWorkoutHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const uid = getAuthenticatedUserId(req);
    if (!uid) return fail(res, 'INVALID_ARGUMENT', 'Missing userId (header X-User-Id or body.userId)', null, 400);

    const body = req.body || {};
    const input = body.workout || body;

    const result = await upsertWorkout(db, uid, input, {
      AnalyticsCalc,
      generateSetFactsForWorkout,
      writeSetFactsInChunks,
      updateSeriesForWorkout,
      FIRESTORE_BATCH_LIMIT: CAPS.FIRESTORE_BATCH_LIMIT,
    });

    // Enqueue Cloud Task for post-completion analytics pipeline
    // upsertWorkout requires end_time, so every upserted workout is completed
    if (result.workout_id) {
      try {
        await enqueueWorkoutCompletion(uid, result.workout_id);
      } catch (enqueueErr) {
        // Non-fatal — watchdog will catch missed completions
        console.warn('[upsertWorkout] Failed to enqueue completion task:', enqueueErr?.message || enqueueErr);
      }
    }

    return ok(res, result);
  } catch (error) {
    return mapErrorToResponse(res, error);
  }
}

exports.upsertWorkout = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(upsertWorkoutHandler)
);
