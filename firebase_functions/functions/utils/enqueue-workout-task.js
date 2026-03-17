/**
 * =============================================================================
 * enqueue-workout-task.js - Cloud Tasks Enqueue Helper
 * =============================================================================
 *
 * PURPOSE:
 * Enqueues a workout completion task to the 'workout-completion' Cloud Tasks
 * queue. Uses named tasks for deduplication — if a task with the same name
 * already exists, the enqueue is silently skipped (idempotent).
 *
 * CALLED BY:
 * - complete-active-workout.js (after archiving workout)
 * - upsert-workout.js (after upserting a workout with end_time)
 * - workout-completion-watchdog.js (daily catch-up for missed completions)
 *
 * CLOUD TASKS QUEUE:
 * Queue 'workout-completion' must be created in GCP before first use:
 *   gcloud tasks queues create workout-completion --location=us-central1
 *
 * =============================================================================
 */

const { CloudTasksClient } = require('@google-cloud/tasks');
const logger = require('firebase-functions/logger');

const client = new CloudTasksClient();
const PROJECT = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'myon-53d85';
const LOCATION = 'us-central1';
const QUEUE = 'workout-completion';

/**
 * Enqueue a workout completion task.
 *
 * @param {string} userId
 * @param {string} workoutId
 */
async function enqueueWorkoutCompletion(userId, workoutId) {
  const parent = client.queuePath(PROJECT, LOCATION, QUEUE);
  const url = `https://${LOCATION}-${PROJECT}.cloudfunctions.net/processWorkoutCompletionTask`;

  const task = {
    httpRequest: {
      httpMethod: 'POST',
      url,
      headers: { 'Content-Type': 'application/json' },
      body: Buffer.from(JSON.stringify({ userId, workoutId })).toString('base64'),
      oidcToken: {
        serviceAccountEmail: `${PROJECT}@appspot.gserviceaccount.com`,
      },
    },
    // Named task prevents duplicate enqueues for the same workout
    name: `${parent}/tasks/workout-${userId.slice(0, 8)}-${workoutId}`,
  };

  try {
    await client.createTask({ parent, task });
    logger.info('Enqueued workout completion task', { userId, workoutId });
  } catch (err) {
    if (err.code === 6) {
      // ALREADY_EXISTS — task was already enqueued, which is fine (idempotent)
      logger.info('Task already exists (idempotent)', { userId, workoutId });
    } else {
      throw err;
    }
  }
}

module.exports = { enqueueWorkoutCompletion };
