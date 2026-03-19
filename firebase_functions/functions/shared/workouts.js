/**
 * =============================================================================
 * shared/workouts.js — Pure business logic for workout CRUD
 * =============================================================================
 *
 * All functions accept (db, userId, ...) — no req/res/auth concerns.
 * Handlers in workouts/*.js become thin HTTP wrappers that call these.
 *
 * Naming: weight_kg everywhere (never "weight" for recorded workout sets).
 * =============================================================================
 */

const admin = require('firebase-admin');
const { ValidationError, NotFoundError, AuthenticationError } = require('./errors');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_LIST_LIMIT = 50;
const MAX_LIST_LIMIT = 200;

// ---------------------------------------------------------------------------
// Helpers (exported for testing)
// ---------------------------------------------------------------------------

/**
 * Convert various date formats to Firestore Timestamp.
 */
function toTimestamp(value) {
  if (!value) return null;
  if (value instanceof admin.firestore.Timestamp) return value;
  if (value instanceof Date) return admin.firestore.Timestamp.fromDate(value);
  if (typeof value === 'number') return admin.firestore.Timestamp.fromMillis(value);
  if (typeof value === 'string') {
    const d = new Date(value);
    if (!isNaN(d.getTime())) return admin.firestore.Timestamp.fromDate(d);
  }
  return null;
}

/**
 * Normalize exercises array with proper weight_kg conversion and defaults.
 * Accepts legacy `weight` field and converts to `weight_kg`.
 */
function normalizeExercises(rawExercises, defaultCompleted = true) {
  const list = Array.isArray(rawExercises) ? rawExercises : [];
  return list.map(ex => {
    const sets = Array.isArray(ex.sets) ? ex.sets : [];
    const normSets = sets.map(s => {
      // Prefer explicit kg; accept weight/weight_lbs and convert when unit provided
      let weightKg = null;
      if (typeof s.weight_kg === 'number') {
        weightKg = s.weight_kg;
      } else if (typeof s.weight === 'number') {
        const unit = (s.unit || s.weight_unit || 'kg').toLowerCase();
        weightKg = unit === 'lbs' || unit === 'pounds' ? +(s.weight / 2.2046226218).toFixed(3) : s.weight;
      } else if (typeof s.weight_lbs === 'number') {
        weightKg = +(s.weight_lbs / 2.2046226218).toFixed(3);
      }
      return {
        id: s.id || null,
        reps: typeof s.reps === 'number' ? s.reps : 0,
        rir: typeof s.rir === 'number' ? s.rir : null,
        type: s.type || 'working set',
        weight_kg: typeof weightKg === 'number' ? weightKg : 0,
        is_completed: s.is_completed !== undefined ? !!s.is_completed : !!defaultCompleted,
      };
    });
    return {
      exercise_id: String(ex.exercise_id || ex.exerciseId || ''),
      name: ex.name || null,
      position: typeof ex.position === 'number' ? ex.position : null,
      sets: normSets,
    };
  });
}

/**
 * Compute summary metrics for a single workout document.
 * Always uses weight_kg for volume calculations.
 */
function computeWorkoutMetrics(workout) {
  const metrics = {
    duration: null,
    totalSets: 0,
    totalReps: 0,
    totalVolume: 0,
    exerciseCount: workout.exercises?.length || 0,
  };

  if (workout.start_time && workout.end_time) {
    const start = workout.start_time instanceof Date ? workout.start_time : new Date(workout.start_time);
    const end = workout.end_time instanceof Date ? workout.end_time : new Date(workout.end_time);
    metrics.duration = Math.round((end - start) / (1000 * 60));
  }
  // Legacy field fallback for older docs that use startedAt/completedAt
  if (metrics.duration === null && workout.startedAt && workout.completedAt) {
    metrics.duration = Math.round((new Date(workout.completedAt) - new Date(workout.startedAt)) / (1000 * 60));
  }

  if (workout.exercises) {
    workout.exercises.forEach(exercise => {
      if (exercise.sets) {
        metrics.totalSets += exercise.sets.length;
        exercise.sets.forEach(set => {
          if (set.reps) metrics.totalReps += set.reps;
          // Use weight_kg; fall back to weight for legacy docs
          const w = set.weight_kg ?? set.weight ?? 0;
          if (w && set.reps) metrics.totalVolume += w * set.reps;
        });
      }
    });
  }
  return metrics;
}

/**
 * Compute analytics summary for a list of workouts.
 * Always uses weight_kg for volume calculations.
 */
function computeListAnalytics(workouts) {
  const analytics = {
    totalWorkouts: workouts.length,
    dateRange: {
      earliest: workouts[workouts.length - 1]?.end_time || null,
      latest: workouts[0]?.end_time || null,
    },
    templates: {},
    averageDuration: null,
    totalVolume: 0,
    exerciseFrequency: {},
  };

  if (workouts.length === 0) return analytics;

  // Template usage
  const templateCounts = {};
  workouts.forEach(workout => {
    if (workout.templateId) {
      templateCounts[workout.templateId] = (templateCounts[workout.templateId] || 0) + 1;
    }
  });
  analytics.templates = templateCounts;

  // Duration analysis
  const durations = workouts
    .filter(w => w.start_time && w.end_time)
    .map(w => (new Date(w.end_time) - new Date(w.start_time)) / (1000 * 60));

  if (durations.length > 0) {
    analytics.averageDuration = Math.round(durations.reduce((a, b) => a + b, 0) / durations.length);
  }

  // Exercise frequency and volume
  const exerciseCounts = {};
  let totalWeight = 0;

  workouts.forEach(workout => {
    if (workout.exercises) {
      workout.exercises.forEach(exercise => {
        exerciseCounts[exercise.exerciseId || exercise.exercise_id] =
          (exerciseCounts[exercise.exerciseId || exercise.exercise_id] || 0) + 1;

        if (exercise.sets) {
          exercise.sets.forEach(set => {
            const w = set.weight_kg ?? set.weight ?? 0;
            if (w && set.reps) {
              totalWeight += w * set.reps;
            }
          });
        }
      });
    }
  });

  analytics.exerciseFrequency = exerciseCounts;
  analytics.totalVolume = totalWeight;
  return analytics;
}

/**
 * Compact a workout to summary shape for agent consumption.
 * Drops per-set data, keeps exercise names and counts.
 */
function summarizeWorkout(w) {
  const exercises = (w.exercises || []).map(ex => ({
    name: ex.name || null,
    exercise_id: ex.exercise_id || null,
    sets: (ex.sets || []).length,
  }));

  const startTime = w.start_time ? new Date(w.start_time) : null;
  const endTime = w.end_time ? new Date(w.end_time) : null;
  const durationMin = (startTime && endTime && !isNaN(startTime) && !isNaN(endTime))
    ? Math.round((endTime - startTime) / (1000 * 60))
    : null;

  return {
    id: w.id,
    end_time: w.end_time,
    name: w.name || null,
    source_template_id: w.source_template_id || null,
    exercises,
    total_sets: w.analytics?.total_sets || null,
    total_volume: w.analytics?.total_weight || null,
    duration_min: durationMin,
  };
}

// ---------------------------------------------------------------------------
// Core CRUD
// ---------------------------------------------------------------------------

/**
 * Get a single workout by ID with computed metrics.
 *
 * @param {Firestore} db - Firestore instance
 * @param {string} userId
 * @param {string} workoutId
 * @returns {{ workout, template, metrics }} or throws
 */
async function getWorkout(db, userId, workoutId) {
  if (!userId) throw new ValidationError('Missing userId');
  if (!workoutId) throw new ValidationError('Missing workoutId');

  const doc = await db.collection('users').doc(userId).collection('workouts').doc(workoutId).get();
  if (!doc.exists) throw new NotFoundError('Workout not found');

  const workout = { id: doc.id, ...doc.data() };

  // Fetch template info if available
  let template = null;
  const templateId = workout.templateId || workout.source_template_id;
  if (templateId) {
    const tDoc = await db.collection('users').doc(userId).collection('templates').doc(templateId).get();
    if (tDoc.exists) template = { id: tDoc.id, ...tDoc.data() };
  }

  const metrics = computeWorkoutMetrics(workout);
  return { workout, template, metrics };
}

/**
 * List workouts for a user with cursor-based pagination.
 *
 * Ordered by start_time desc (most recent first).
 * Cursor is the start_time value of the last returned doc — the next page
 * continues from just before that value.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} opts
 * @param {number}  [opts.limit=50]       - Page size (capped at MAX_LIST_LIMIT)
 * @param {string}  [opts.startDate]      - ISO date lower bound on end_time
 * @param {string}  [opts.endDate]        - ISO date upper bound on end_time
 * @param {*}       [opts.cursor]         - Firestore doc snapshot or Timestamp to startAfter
 * @returns {{ items, analytics, hasMore, nextCursor }}
 */
async function listWorkouts(db, userId, opts = {}) {
  if (!userId) throw new ValidationError('Missing userId');

  const limit = Math.min(Math.max(1, parseInt(opts.limit) || DEFAULT_LIST_LIMIT), MAX_LIST_LIMIT);

  let query = db.collection('users').doc(userId).collection('workouts')
    .orderBy('start_time', 'desc');

  // Date filters on end_time (matching existing behaviour)
  if (opts.startDate) {
    query = query.where('end_time', '>=', new Date(opts.startDate));
  }
  if (opts.endDate) {
    query = query.where('end_time', '<=', new Date(opts.endDate));
  }

  // Cursor-based pagination: startAfter the provided cursor value
  if (opts.cursor) {
    query = query.startAfter(opts.cursor);
  }

  // Fetch limit + 1 to detect hasMore
  const snapshot = await query.limit(limit + 1).get();
  const docs = snapshot.docs.map(d => ({ id: d.id, ...d.data() }));

  const hasMore = docs.length > limit;
  const items = hasMore ? docs.slice(0, limit) : docs;

  // Cursor for next page = start_time of last item
  const nextCursor = hasMore && items.length > 0
    ? items[items.length - 1].start_time
    : null;

  const analytics = computeListAnalytics(items);

  // Apply view projection
  const outputItems = opts.view === 'summary'
    ? items.map(summarizeWorkout)
    : items;

  return { items: outputItems, analytics, hasMore, nextCursor };
}

/**
 * Upsert a completed workout with analytics, set_facts, and series updates.
 *
 * Preserves ALL logic from the original upsert-workout.js handler:
 * 1. Normalise exercises (weight -> weight_kg, defaults)
 * 2. Compute analytics via AnalyticsCalc (with fallback)
 * 3. If updating: delete old set_facts, revert old series (sign=-1)
 * 4. Write workout document
 * 5. Generate new set_facts and update series (sign=+1)
 * 6. Set set_facts_synced_at to prevent duplicate trigger processing
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} input        - Workout payload (exercises, start_time, end_time, ...)
 * @param {Object} deps         - Injected dependencies
 * @param {Object} deps.AnalyticsCalc
 * @param {Function} deps.generateSetFactsForWorkout
 * @param {Function} deps.writeSetFactsInChunks
 * @param {Function} deps.updateSeriesForWorkout
 * @param {number}  [deps.FIRESTORE_BATCH_LIMIT=500]
 * @returns {{ workout_id, created, user_id, set_facts_synced }}
 */
async function upsertWorkout(db, userId, input, deps) {
  if (!userId) throw new ValidationError('Missing userId');
  if (!input || !Array.isArray(input.exercises)) {
    throw new ValidationError('workout.exercises array is required');
  }

  const col = db.collection('users').doc(String(userId)).collection('workouts');

  // Times
  const startTs = toTimestamp(input.start_time) || toTimestamp(input.startTime);
  const endTs = toTimestamp(input.end_time) || toTimestamp(input.endTime);
  if (!endTs) {
    throw new ValidationError('end_time is required (ISO string or millis)');
  }

  const exercises = normalizeExercises(input.exercises, true);

  // Compute analytics (with fallback)
  let workoutAnalytics = null;
  let updatedExercises = exercises;
  try {
    const calc = await deps.AnalyticsCalc.calculateWorkoutAnalytics({ exercises });
    workoutAnalytics = calc.workoutAnalytics;
    updatedExercises = calc.updatedExercises || exercises;
  } catch (e) {
    console.warn('Analytics calculation failed, using fallback:', e.message);
    const totals = exercises.reduce((acc, ex) => {
      const sets = ex.sets || [];
      const reps = sets.reduce((s, v) => s + (v.reps || 0), 0);
      const vol = sets.reduce((s, v) => s + ((v.weight_kg || 0) * (v.reps || 0)), 0);
      return { sets: acc.sets + sets.length, reps: acc.reps + reps, vol: acc.vol + vol };
    }, { sets: 0, reps: 0, vol: 0 });
    workoutAnalytics = {
      total_sets: totals.sets,
      total_reps: totals.reps,
      total_weight: totals.vol,
      weight_format: 'kg',
      avg_reps_per_set: totals.sets > 0 ? totals.reps / totals.sets : 0,
      avg_weight_per_set: totals.sets > 0 ? totals.vol / totals.sets : 0,
      avg_weight_per_rep: totals.reps > 0 ? totals.vol / totals.reps : 0,
      weight_per_muscle_group: {},
      weight_per_muscle: {},
      reps_per_muscle_group: {},
      reps_per_muscle: {},
      sets_per_muscle_group: {},
      sets_per_muscle: {},
    };
  }

  // Select doc id
  let docId = input.id ? String(input.id) : null;
  const docRef = docId ? col.doc(docId) : col.doc();
  docId = docRef.id;

  // Check if existing workout
  const existing = await docRef.get();
  const isUpdate = existing.exists;

  // If updating, clean up old set_facts and revert series
  if (isUpdate) {
    const existingData = existing.data();

    // Delete old set_facts
    const batchLimit = deps.FIRESTORE_BATCH_LIMIT || 500;
    const deletedCount = await _deleteSetFactsForWorkout(db, String(userId), docId, batchLimit);
    if (deletedCount > 0) {
      console.log(`Deleted ${deletedCount} old set_facts for workout ${docId}`);
    }

    // Revert old series contributions
    if (existingData && existingData.exercises && existingData.end_time) {
      try {
        const existingWorkout = { ...existingData, id: docId };
        await deps.updateSeriesForWorkout(db, String(userId), existingWorkout, -1);
        console.log(`Reverted old series for workout ${docId}`);
      } catch (e) {
        console.warn('Failed to revert old series (continuing):', e.message);
      }
    }
  }

  // Payload
  const payload = {
    id: docId,
    user_id: String(userId),
    name: input.name || (isUpdate ? (existing.data()?.name || null) : null),
    source_template_id: input.source_template_id || input.template_id || null,
    created_at: isUpdate ? existing.data()?.created_at : (startTs || admin.firestore.FieldValue.serverTimestamp()),
    start_time: startTs || admin.firestore.FieldValue.serverTimestamp(),
    end_time: endTs,
    notes: input.notes || null,
    source_meta: input.source_meta || input.sourceMeta || null,
    exercises: updatedExercises,
    analytics: input.analytics || workoutAnalytics,
    set_facts_synced_at: admin.firestore.FieldValue.serverTimestamp(),
  };

  // Write workout document
  await docRef.set(payload, { merge: false });

  // Generate and write new set_facts
  const workoutWithId = { ...payload, id: docId, end_time: endTs };
  try {
    const setFacts = deps.generateSetFactsForWorkout({
      userId: String(userId),
      workout: workoutWithId,
    });

    if (setFacts.length > 0) {
      await deps.writeSetFactsInChunks(db, String(userId), setFacts);
      console.log(`Wrote ${setFacts.length} set_facts for workout ${docId}`);

      await deps.updateSeriesForWorkout(db, String(userId), workoutWithId, 1);
      console.log(`Updated series for workout ${docId}`);
    }
  } catch (e) {
    console.error('Failed to generate set_facts/series (workout saved, analytics may be incomplete):', e.message);
  }

  return {
    workout_id: docId,
    created: !isUpdate,
    user_id: userId,
    set_facts_synced: true,
  };
}

/**
 * Delete a workout by ID (after verifying it exists).
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {string} workoutId
 * @returns {{ deleted: true, workout_id }}
 */
async function deleteWorkout(db, userId, workoutId) {
  if (!userId) throw new AuthenticationError('Missing userId');
  if (!workoutId) throw new ValidationError('Missing workout_id');

  const ref = db.collection('users').doc(userId).collection('workouts').doc(workoutId);
  const doc = await ref.get();
  if (!doc.exists) throw new NotFoundError('Workout not found');

  await ref.delete();
  console.log(`Deleted workout ${workoutId} for user ${userId}`);
  return { deleted: true, workout_id: workoutId };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Delete all set_facts for a specific workout (batched).
 * Extracted from upsert-workout.js.
 */
async function _deleteSetFactsForWorkout(db, userId, workoutId, batchLimit = 500) {
  const setFactsQuery = db.collection('users').doc(userId)
    .collection('set_facts')
    .where('workout_id', '==', workoutId);

  const snapshot = await setFactsQuery.get();
  if (snapshot.empty) return 0;

  const docs = snapshot.docs;
  for (let i = 0; i < docs.length; i += batchLimit) {
    const chunk = docs.slice(i, i + batchLimit);
    const batch = db.batch();
    for (const d of chunk) {
      batch.delete(d.ref);
    }
    await batch.commit();
  }
  return snapshot.size;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  // Core CRUD
  getWorkout,
  listWorkouts,
  upsertWorkout,
  deleteWorkout,
  // Helpers (exported for testing and reuse)
  summarizeWorkout,
  toTimestamp,
  normalizeExercises,
  computeWorkoutMetrics,
  computeListAnalytics,
  // Constants
  DEFAULT_LIST_LIMIT,
  MAX_LIST_LIMIT,
};
