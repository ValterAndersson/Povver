/**
 * =============================================================================
 * workout-completion-task.js - Cloud Tasks HTTP Handler
 * =============================================================================
 *
 * PURPOSE:
 * Receives Cloud Tasks HTTP requests with {userId, workoutId} and delegates
 * to the unified processWorkoutCompletion pipeline.
 *
 * INVOKED BY:
 * - Cloud Tasks queue 'workout-completion' (enqueued by upsert-workout.js
 *   and complete-active-workout.js)
 * - Watchdog scheduler (workout-completion-watchdog.js) for missed completions
 *
 * AUTHENTICATION:
 * Cloud Tasks sends requests with an OIDC token from the project's default
 * service account. Firebase Functions v2 validates this automatically when
 * invoker is not set to 'public'.
 *
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { processWorkoutCompletion } = require('../training/process-workout-completion');
const logger = require('firebase-functions/logger');

exports.processWorkoutCompletionTask = onRequest(
  { region: 'us-central1', memory: '512MiB', timeoutSeconds: 120 },
  async (req, res) => {
    const { userId, workoutId } = req.body;
    if (!userId || !workoutId) {
      res.status(400).send('Missing userId or workoutId');
      return;
    }
    try {
      const result = await processWorkoutCompletion(userId, workoutId);
      res.status(200).json(result);
    } catch (err) {
      logger.error('[workout-completion-task] processing_failed', {
        userId, workoutId, error: err.message,
      });
      res.status(500).send('Internal processing error');
    }
  }
);
