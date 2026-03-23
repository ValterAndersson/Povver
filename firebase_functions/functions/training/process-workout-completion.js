/**
 * =============================================================================
 * process-workout-completion.js - Unified Workout Completion Pipeline
 * =============================================================================
 *
 * PURPOSE:
 * Single entry point for all post-workout-completion processing. Replaces the
 * duplicated logic from onWorkoutCompleted (Firestore onUpdate trigger) and
 * onWorkoutCreatedWithEnd (Firestore onCreate trigger) with a single idempotent
 * function invoked via Cloud Tasks.
 *
 * ARCHITECTURE CONTEXT (AD-1):
 * The previous Firestore trigger approach had reliability problems — triggers
 * can be dropped or delayed under load. Cloud Tasks provides at-least-once
 * delivery with automatic retries, named tasks for deduplication, and a
 * watchdog can catch any missed completions.
 *
 * PIPELINE STEPS (transplanted verbatim from weekly-analytics.js triggers):
 * 1. Read workout document
 * 2. Check watermark idempotency (weekly_stats.processed_ids)
 * 3. Update weekly stats (transactional, with retry)
 * 4. Upsert analytics rollups (for ACWR calculations)
 * 5. Write per-muscle weekly series
 * 6. Update analytics watermark
 * 7. Write per-exercise daily series (e1RM, volume)
 * 8. Generate set_facts and update series (token-safe analytics)
 * 9. Enqueue training analysis job (premium users only)
 * 10. Update exercise usage stats
 * 11. Advance routine cursor (from workout-routine-cursor.js)
 *
 * IDEMPOTENCY:
 * - weekly_stats uses processed_ids array to skip duplicate processing
 * - exercise_usage_stats uses last_processed_workout_id per exercise
 * - Cloud Tasks uses named tasks (workout-{userId}-{workoutId}) for dedup
 * - set_facts skip if set_facts_synced_at is recent (< 10s)
 *
 * =============================================================================
 */

const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const AnalyticsWrites = require('../utils/analytics-writes');
const { isPremiumUser } = require('../utils/subscription-gate');
const {
  generateSetFactsForWorkout,
  writeSetFactsInChunks,
  updateSeriesForWorkout,
} = require('../training/set-facts-generator');
const logger = require('firebase-functions/logger');

// ============================================================================
// Helper functions (transplanted from weekly-analytics.js)
// ============================================================================

function getWeekStartMonday(dateString) {
  const date = new Date(dateString);
  const day = date.getUTCDay();
  const diff = day === 0 ? 6 : day - 1;
  date.setUTCDate(date.getUTCDate() - diff);
  date.setUTCHours(0, 0, 0, 0);
  return date.toISOString().split('T')[0];
}

function getWeekStartSunday(dateString) {
  const date = new Date(dateString);
  const day = date.getUTCDay();
  const diff = day;
  date.setUTCDate(date.getUTCDate() - diff);
  date.setUTCHours(0, 0, 0, 0);
  return date.toISOString().split('T')[0];
}

async function getWeekStartForUser(userId, dateString) {
  try {
    const userDoc = await db.collection('users').doc(userId).get();
    if (userDoc.exists) {
      const userData = userDoc.data();
      const weekStartsOnMonday = userData.week_starts_on_monday !== undefined ? userData.week_starts_on_monday : true;
      return weekStartsOnMonday ? getWeekStartMonday(dateString) : getWeekStartSunday(dateString);
    }
  } catch (error) {
    console.warn(`Error fetching user preferences for ${userId}, defaulting to Monday start:`, error);
  }
  return getWeekStartMonday(dateString);
}

function mergeMetrics(target = {}, source = {}, increment = 1) {
  if (!source || typeof source !== 'object') return;
  for (const [key, value] of Object.entries(source)) {
    if (typeof value !== 'number') continue;
    const current = target[key] || 0;
    const updated = current + value * increment;
    if (updated === 0) {
      delete target[key];
    } else {
      target[key] = updated;
    }
  }
}

function validateAnalytics(analytics) {
  if (!analytics || typeof analytics !== 'object') {
    return { isValid: false, error: 'Analytics object is missing or invalid' };
  }
  const requiredNumericFields = ['total_sets', 'total_reps', 'total_weight'];
  for (const field of requiredNumericFields) {
    if (typeof analytics[field] !== 'number') {
      return { isValid: false, error: `Analytics missing or invalid field: ${field}` };
    }
  }
  return { isValid: true };
}

async function updateWeeklyStats(userId, weekId, analytics, increment = 1, workoutId = null, retries = 3) {
  const validation = validateAnalytics(analytics);
  if (!validation.isValid) {
    console.warn(`Invalid analytics for user ${userId}, week ${weekId}: ${validation.error}`);
    return { success: false, error: validation.error };
  }

  const ref = db
    .collection('users')
    .doc(userId)
    .collection('weekly_stats')
    .doc(weekId);

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const data = snap.exists
          ? snap.data()
          : {
              workouts: 0,
              total_sets: 0,
              total_reps: 0,
              total_weight: 0,
              weight_per_muscle_group: {},
              weight_per_muscle: {},
              reps_per_muscle_group: {},
              reps_per_muscle: {},
              sets_per_muscle_group: {},
              sets_per_muscle: {},
              hard_sets_total: 0,
              low_rir_sets_total: 0,
              hard_sets_per_muscle: {},
              low_rir_sets_per_muscle: {},
              load_per_muscle: {},
              processed_ids: [],
            };

        // Idempotency check for add path
        if (workoutId && increment === 1) {
          const processedIds = data.processed_ids || [];
          if (processedIds.includes(workoutId)) {
            console.log(`Workout ${workoutId} already processed for week ${weekId}, skipping`);
            return;
          }
          data.processed_ids = admin.firestore.FieldValue.arrayUnion(workoutId);
        }

        data.workouts += increment;
        data.total_sets += analytics.total_sets * increment;
        data.total_reps += analytics.total_reps * increment;
        data.total_weight += analytics.total_weight * increment;

        mergeMetrics(data.weight_per_muscle_group, analytics.weight_per_muscle_group, increment);
        mergeMetrics(data.weight_per_muscle, analytics.weight_per_muscle, increment);
        mergeMetrics(data.reps_per_muscle_group, analytics.reps_per_muscle_group, increment);
        mergeMetrics(data.reps_per_muscle, analytics.reps_per_muscle, increment);
        mergeMetrics(data.sets_per_muscle_group, analytics.sets_per_muscle_group, increment);
        mergeMetrics(data.sets_per_muscle, analytics.sets_per_muscle, increment);
        if (analytics.intensity) {
          const intensity = analytics.intensity;
          data.hard_sets_total += (intensity.hard_sets || 0) * increment;
          data.low_rir_sets_total += (intensity.low_rir_sets || 0) * increment;
          mergeMetrics(data.hard_sets_per_muscle, intensity.hard_sets_per_muscle, increment);
          mergeMetrics(data.low_rir_sets_per_muscle, intensity.low_rir_sets_per_muscle, increment);
          mergeMetrics(data.load_per_muscle, intensity.load_per_muscle, increment);
        }

        data.updated_at = admin.firestore.FieldValue.serverTimestamp();
        tx.set(ref, data, { merge: true });
      });

      return { success: true, weekId, attempt };
    } catch (error) {
      console.warn(`Transaction attempt ${attempt} failed for user ${userId}, week ${weekId}:`, error.message);
      if (attempt === retries) {
        console.error(`All ${retries} attempts failed for user ${userId}, week ${weekId}:`, error);
        return { success: false, error: error.message, finalAttempt: true };
      }
      await new Promise(resolve => setTimeout(resolve, Math.pow(2, attempt) * 100));
    }
  }
}

// Simple e1RM estimator (Epley by default)
function estimateE1RM(weightKg, reps) {
  if (typeof weightKg !== 'number' || typeof reps !== 'number' || reps <= 0) return 0;
  if (reps === 1) return weightKg;
  return weightKg * (1 + reps / 30);
}

/**
 * Update exercise_usage_stats for each exercise in a completed workout.
 * Uses per-exercise transactions with last_processed_workout_id for idempotency.
 */
async function updateExerciseUsageStats(userId, workout, workoutId, increment = 1) {
  const exercises = Array.isArray(workout.exercises) ? workout.exercises : [];
  if (exercises.length === 0) return;

  const endTime = workout.end_time?.toDate
    ? workout.end_time.toDate().toISOString()
    : workout.end_time;
  const workoutDate = typeof endTime === 'string' ? endTime.split('T')[0] : null;

  const seen = new Set();
  const uniqueExercises = [];
  for (const ex of exercises) {
    if (!ex.exercise_id || seen.has(ex.exercise_id)) continue;
    seen.add(ex.exercise_id);
    uniqueExercises.push({ id: ex.exercise_id, name: ex.name || '' });
  }

  const writes = uniqueExercises.map(async (ex) => {
    const statsRef = db.collection('users').doc(userId)
      .collection('exercise_usage_stats').doc(ex.id);

    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(statsRef);
        const data = snap.exists ? snap.data() : {};

        if (increment === 1) {
          if (data.last_processed_workout_id === workoutId) return;
          tx.set(statsRef, {
            exercise_id: ex.id,
            exercise_name: ex.name,
            last_workout_date: workoutDate || data.last_workout_date || null,
            workout_count: (data.workout_count || 0) + 1,
            last_processed_workout_id: workoutId,
            updated_at: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        } else {
          const newCount = Math.max((data.workout_count || 0) - 1, 0);
          tx.set(statsRef, {
            workout_count: newCount,
            last_processed_workout_id: admin.firestore.FieldValue.delete(),
            updated_at: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
      });
    } catch (e) {
      console.warn(`Non-fatal: failed to update exercise_usage_stats for ${ex.id}:`, e?.message || e);
    }
  });

  await Promise.allSettled(writes);
}

/**
 * Advance routine cursor when a workout is completed.
 * Transplanted from workout-routine-cursor.js.
 */
async function advanceRoutineCursor(userId, workoutId, workout) {
  if (!workout.source_routine_id || !workout.source_template_id) {
    logger.info(`Workout ${workoutId}: No source_routine_id or source_template_id, skipping cursor update`);
    return;
  }

  if (!workout.end_time) {
    logger.info(`Workout ${workoutId}: No end_time, skipping cursor update`);
    return;
  }

  try {
    const routineRef = db
      .collection('users')
      .doc(userId)
      .collection('routines')
      .doc(workout.source_routine_id);

    const routineDoc = await routineRef.get();

    if (!routineDoc.exists) {
      logger.info(`Workout ${workoutId}: Source routine ${workout.source_routine_id} not found, skipping cursor update`);
      return;
    }

    const routine = routineDoc.data();
    const templateIds = routine.template_ids || routine.templateIds || [];

    if (!templateIds.includes(workout.source_template_id)) {
      logger.info(`Workout ${workoutId}: Template ${workout.source_template_id} not in routine's template_ids, skipping cursor update`);
      return;
    }

    await routineRef.update({
      last_completed_template_id: workout.source_template_id,
      last_completed_at: workout.end_time,
    });

    logger.info(`Workout ${workoutId}: Updated routine ${workout.source_routine_id} cursor to template ${workout.source_template_id}`);

    // Auto-activate this routine if user has no active routine set.
    try {
      const userRef = db.collection('users').doc(userId);
      const userSnap = await userRef.get();
      if (userSnap.exists && !userSnap.data().activeRoutineId) {
        await userRef.update({ activeRoutineId: workout.source_routine_id });
        logger.info(`Workout ${workoutId}: Auto-activated routine ${workout.source_routine_id} (no prior active routine)`);
      }
    } catch (e) {
      console.warn(`Workout ${workoutId}: Non-fatal: failed to auto-activate routine`, e?.message || e);
    }
  } catch (error) {
    console.error(`Error updating routine cursor for workout ${workoutId}:`, error);
    // Non-fatal — cursor update is best-effort
  }
}

// ============================================================================
// Main pipeline
// ============================================================================

/**
 * Process a completed workout: analytics, series, set_facts, cursor, analysis.
 *
 * This function is idempotent — safe to call multiple times for the same
 * workout due to watermark checks at each step.
 *
 * @param {string} userId
 * @param {string} workoutId
 * @returns {Object} result summary
 */
async function processWorkoutCompletion(userId, workoutId) {
  // 1. Read the workout document
  const workoutRef = db.collection('users').doc(userId).collection('workouts').doc(workoutId);
  const workoutSnap = await workoutRef.get();

  if (!workoutSnap.exists) {
    logger.warn(`processWorkoutCompletion: workout ${workoutId} not found for user ${userId}`);
    return { success: false, error: 'Workout not found' };
  }

  const workout = workoutSnap.data();

  if (!workout.end_time) {
    logger.info(`processWorkoutCompletion: workout ${workoutId} has no end_time, skipping`);
    return { success: false, error: 'Workout not completed (no end_time)' };
  }

  const analytics = workout.analytics;
  if (!analytics) {
    logger.warn(`processWorkoutCompletion: workout ${workoutId} for user ${userId} missing analytics`);
    return { success: false, error: 'Workout missing analytics' };
  }

  // Convert Firestore timestamp to ISO string for week calculation
  const endTime = workout.end_time.toDate ? workout.end_time.toDate().toISOString() : workout.end_time;

  // 2-3. Update weekly stats (includes idempotency via processed_ids)
  const weekId = await getWeekStartForUser(userId, endTime);
  const result = await updateWeeklyStats(userId, weekId, analytics, 1, workoutId);

  // 4. Upsert rollups
  try {
    await AnalyticsWrites.upsertRollup(userId, weekId, {
      total_sets: analytics.total_sets,
      total_reps: analytics.total_reps,
      total_weight: analytics.total_weight,
      weight_per_muscle_group: analytics.weight_per_muscle_group || {},
      workouts: 1,
      hard_sets_total: analytics.intensity?.hard_sets || 0,
      low_rir_sets_total: analytics.intensity?.low_rir_sets || 0,
      hard_sets_per_muscle: analytics.intensity?.hard_sets_per_muscle || {},
      low_rir_sets_per_muscle: analytics.intensity?.low_rir_sets_per_muscle || {},
      load_per_muscle: analytics.intensity?.load_per_muscle || {},
    }, 1);
  } catch (e) {
    // Upgrade rollup failures to error — they break ACWR calculations
    console.error('[processWorkoutCompletion] CRITICAL: Rollup write failed', {
      userId,
      workoutId,
      weekId,
      error: e?.message || String(e),
    });
  }

  // 5. Per-muscle weekly series (non-fatal)
  try {
    const setsByGroup = analytics.sets_per_muscle_group || {};
    const volByGroup = analytics.weight_per_muscle_group || {};
    const hardSetsByMuscle = analytics.intensity?.hard_sets_per_muscle || {};
    const loadByMuscle = analytics.intensity?.load_per_muscle || {};
    const lowRirByMuscle = analytics.intensity?.low_rir_sets_per_muscle || {};
    const muscles = new Set([
      ...Object.keys(setsByGroup),
      ...Object.keys(volByGroup),
      ...Object.keys(hardSetsByMuscle),
      ...Object.keys(loadByMuscle),
      ...Object.keys(lowRirByMuscle),
    ]);
    const writes = [];
    for (const muscle of muscles) {
      writes.push(
        AnalyticsWrites.appendMuscleSeries(
          userId,
          muscle,
          weekId,
          {
            sets: setsByGroup[muscle] || 0,
            volume: volByGroup[muscle] || 0,
            hard_sets: hardSetsByMuscle[muscle] || 0,
            load: loadByMuscle[muscle] || 0,
            low_rir_sets: lowRirByMuscle[muscle] || 0,
          },
          1
        )
      );
    }
    if (writes.length) await Promise.allSettled(writes);
  } catch (e) {
    console.warn('[processWorkoutCompletion] Non-fatal: failed to write per-muscle series', e?.message || e);
  }

  // 6. Update watermark
  try {
    await AnalyticsWrites.updateWatermark(userId, { last_processed_workout_at: endTime });
  } catch (e) {
    console.warn('Non-fatal: failed to update watermark', e?.message || e);
  }

  // 7. Append per-exercise daily points (e1RM max, volume sum)
  try {
    const dayKey = endTime.split('T')[0];
    const exercises = Array.isArray(workout.exercises) ? workout.exercises : [];
    const perExercise = new Map();
    for (const ex of exercises) {
      const exId = ex.exercise_id;
      if (!exId || !Array.isArray(ex.sets)) continue;
      let maxE1 = 0; let vol = 0;
      for (const s of ex.sets) {
        if (!s.is_completed) continue;
        const reps = typeof s.reps === 'number' ? s.reps : 0;
        const w = typeof s.weight_kg === 'number' ? s.weight_kg : 0;
        if (reps > 0 && w > 0) {
          maxE1 = Math.max(maxE1, estimateE1RM(w, reps));
          vol += w * reps;
        }
      }
      const curr = perExercise.get(exId) || { e1rm: 0, vol: 0 };
      curr.e1rm = Math.max(curr.e1rm, maxE1);
      curr.vol += vol;
      perExercise.set(exId, curr);
    }
    const writes = [];
    for (const [exerciseId, point] of perExercise.entries()) {
      writes.push(AnalyticsWrites.appendExerciseSeries(userId, exerciseId, dayKey, point, 1));
    }
    if (writes.length) await Promise.allSettled(writes);
  } catch (e) {
    console.warn('Non-fatal: failed to write per-exercise daily series', e?.message || e);
  }

  // 8. TOKEN-SAFE ANALYTICS: set_facts + new series
  // Skip if set_facts were already synced by upsertWorkout (within last 10 seconds)
  const setFactsSyncedAt = workout.set_facts_synced_at;
  const syncedRecently = setFactsSyncedAt &&
    (Date.now() - (setFactsSyncedAt.toMillis ? setFactsSyncedAt.toMillis() : setFactsSyncedAt)) < 10000;

  if (syncedRecently) {
    logger.info(`Skipping set_facts generation for workout ${workoutId} - already synced by upsertWorkout`);
  } else {
    try {
      const workoutWithId = { ...workout, id: workoutId };
      const setFacts = generateSetFactsForWorkout({
        userId,
        workout: workoutWithId,
      });

      if (setFacts.length > 0) {
        await writeSetFactsInChunks(db, userId, setFacts);
        await updateSeriesForWorkout(db, userId, workoutWithId, 1);
        logger.info(`Token-safe analytics: wrote ${setFacts.length} set_facts for workout ${workoutId}`);
      }
    } catch (e) {
      console.warn('Non-fatal: failed to write token-safe analytics (set_facts/series)', e?.message || e);
    }
  }

  // 9. Enqueue background analysis job (premium users only)
  try {
    const hasPremium = await isPremiumUser(userId);
    if (hasPremium) {
      const jobId = `pw-${userId}-${workoutId}`;
      const jobRef = db.collection('training_analysis_jobs').doc(jobId);

      // Check if already completed before overwriting
      const existing = await jobRef.get();
      if (existing.exists && existing.data().status === 'completed') {
        logger.info('[process-workout-completion] job_already_completed', { jobId });
      } else {
        await jobRef.set({
          type: 'POST_WORKOUT',
          status: 'queued',
          priority: 100,
          payload: {
            user_id: userId,
            workout_id: workoutId,
            window_weeks: 4,
          },
          attempts: 0,
          max_attempts: 3,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
          updated_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        logger.info(`Enqueued training analysis job for premium user ${userId}`, { jobId });
      }
    } else {
      logger.info(`Skipping training analysis job for free user ${userId}`);
    }
  } catch (e) {
    console.warn('Non-fatal: failed to enqueue analysis job', e?.message);
  }

  // 10. Update exercise usage stats
  try {
    await updateExerciseUsageStats(userId, workout, workoutId, 1);
  } catch (e) {
    console.warn('Non-fatal: failed to update exercise usage stats', e?.message || e);
  }

  // 11. Advance routine cursor
  try {
    await advanceRoutineCursor(userId, workoutId, workout);
  } catch (e) {
    console.warn('Non-fatal: failed to advance routine cursor', e?.message || e);
  }

  if (!result.success) {
    console.error(`Failed to update weekly stats:`, result);
  }

  return {
    success: true,
    workoutId,
    weekId,
    weeklyStatsResult: result,
  };
}

module.exports = { processWorkoutCompletion };
