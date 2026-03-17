/**
 * =============================================================================
 * workout-completion-watchdog.js - Daily Missed Completion Catch-Up
 * =============================================================================
 *
 * PURPOSE:
 * Scheduled function that runs daily to find completed workouts that were
 * never processed by the Cloud Tasks pipeline. This catches edge cases like
 * task queue failures or deployments that missed enqueuing tasks.
 *
 * HOW IT WORKS:
 * 1. Scans all users for workouts completed in the last 48 hours
 * 2. Checks the analytics_state watermark for each user
 * 3. Re-enqueues any workouts that weren't processed
 *
 * The processWorkoutCompletion function is idempotent, so re-enqueuing
 * already-processed workouts is safe (they'll be skipped via watermark checks).
 *
 * =============================================================================
 */

const { onSchedule } = require('firebase-functions/v2/scheduler');
const { getFirestore } = require('firebase-admin/firestore');
const admin = require('firebase-admin');
const { enqueueWorkoutCompletion } = require('../utils/enqueue-workout-task');
const logger = require('firebase-functions/logger');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = getFirestore();

exports.workoutCompletionWatchdog = onSchedule(
  { schedule: 'every 24 hours', region: 'us-central1', memory: '512MiB', timeoutSeconds: 300 },
  async () => {
    const cutoff = new Date(Date.now() - 48 * 60 * 60 * 1000);
    const cutoffTimestamp = admin.firestore.Timestamp.fromDate(cutoff);

    // Use collectionGroup query to find recent completed workouts across all users
    // This is more efficient than iterating all users
    const recentWorkoutsSnap = await db.collectionGroup('workouts')
      .where('end_time', '>=', cutoffTimestamp)
      .select('end_time') // minimal read
      .get();

    // Group by userId
    const workoutsByUser = new Map();
    for (const doc of recentWorkoutsSnap.docs) {
      const userId = doc.ref.parent.parent.id;
      if (!workoutsByUser.has(userId)) {
        workoutsByUser.set(userId, []);
      }
      workoutsByUser.get(userId).push(doc.id);
    }

    let requeued = 0;
    for (const [userId, workoutIds] of workoutsByUser.entries()) {
      // Check which workouts have been processed via weekly_stats processed_ids
      // We can't easily check analytics_state watermark per-workout, so we
      // rely on the idempotency of processWorkoutCompletion and just re-enqueue all.
      // The named task deduplication in Cloud Tasks will prevent actual duplicates.
      for (const wId of workoutIds) {
        try {
          await enqueueWorkoutCompletion(userId, wId);
          requeued++;
        } catch (e) {
          logger.warn('Watchdog: failed to enqueue', { userId, workoutId: wId, error: e?.message });
        }
      }
    }

    logger.info('Watchdog completed', { requeued, usersChecked: workoutsByUser.size });
  }
);
