/**
 * Series Endpoints — thin wrappers
 * Business logic for helpers lives in shared/training-queries.js.
 * These remain onCall endpoints; they use the shared helpers but keep
 * their own response shaping because onCall returns data directly.
 *
 * @see docs/TRAINING_ANALYTICS_API_V2_SPEC.md Section 6.3
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const {
  CAPS,
  buildResponse,
  requireAuth,
} = require('../utils/caps');
const { isValidMuscleGroup, isValidMuscle, getMuscleGroupDisplay, getMuscleDisplay } = require('../utils/muscle-taxonomy');
const {
  getRecentWeekStarts,
  extractWeeklyPoints,
  computeSeriesSummary,
  findExerciseSeriesByName,
} = require('../shared/training-queries');

/**
 * series.exercise.get
 * Get weekly series for a specific exercise
 *
 * Accepts either:
 * - exercise_id: direct ID lookup
 * - exercise_name: fuzzy name search (for agent queries like "bench press")
 */
exports.getExerciseSeries = onCall(async (request) => {
  try {
    const userId = requireAuth(request);
    const { exercise_id, exercise_name, window_weeks } = request.data || {};

    if (!exercise_id && !exercise_name) {
      throw new HttpsError('invalid-argument', 'exercise_id or exercise_name is required');
    }

    const weeks = Math.min(Math.max(1, window_weeks || CAPS.DEFAULT_WEEKS), CAPS.MAX_WEEKS);
    const weekIds = getRecentWeekStarts(weeks);

    let seriesDoc = null;
    let resolvedExerciseId = exercise_id;
    let resolvedExerciseName = null;

    if (exercise_id) {
      // Direct ID lookup
      const seriesRef = db.collection('users').doc(userId)
        .collection('analytics_series_exercise').doc(exercise_id);
      seriesDoc = await seriesRef.get();

      // Get exercise name from series doc or catalog
      if (seriesDoc.exists && seriesDoc.data().exercise_name) {
        resolvedExerciseName = seriesDoc.data().exercise_name;
      } else {
        try {
          const exDoc = await db.collection('exercises').doc(exercise_id).get();
          if (exDoc.exists) {
            resolvedExerciseName = exDoc.data().name;
          }
        } catch (e) {
          // Ignore - name is optional
        }
      }
    } else {
      // Name-based search
      const match = await findExerciseSeriesByName(db, userId, exercise_name);

      if (!match) {
        return buildResponse({
          exercise_id: null,
          exercise_name: exercise_name,
          matched: false,
          message: `No training history found for "${exercise_name}". Try a different exercise name or check spelling.`,
          weekly_points: [],
          summary: computeSeriesSummary([]),
        }, { limit: weeks });
      }

      seriesDoc = match.doc;
      resolvedExerciseId = match.exerciseId;
      resolvedExerciseName = match.exerciseName;
    }

    const points = extractWeeklyPoints(seriesDoc, weekIds);
    const summary = computeSeriesSummary(points);

    return buildResponse({
      exercise_id: resolvedExerciseId,
      exercise_name: resolvedExerciseName,
      matched: true,
      weekly_points: points,
      summary,
    }, { limit: weeks });

  } catch (error) {
    if (error instanceof HttpsError) throw error;
    console.error('Error in getExerciseSeries:', error);
    throw new HttpsError('internal', 'Internal error');
  }
});

/**
 * series.muscle_group.get
 * Get weekly series for a muscle group
 */
exports.getMuscleGroupSeries = onCall(async (request) => {
  try {
    const userId = requireAuth(request);
    const { muscle_group, window_weeks } = request.data || {};

    if (!muscle_group) {
      throw new HttpsError('invalid-argument', 'muscle_group is required');
    }

    if (!isValidMuscleGroup(muscle_group)) {
      throw new HttpsError('invalid-argument', `Invalid muscle_group: ${muscle_group}`);
    }

    const weeks = Math.min(Math.max(1, window_weeks || CAPS.DEFAULT_WEEKS), CAPS.MAX_WEEKS);
    const weekIds = getRecentWeekStarts(weeks);

    // Get series document
    const seriesRef = db.collection('users').doc(userId)
      .collection('analytics_series_muscle_group').doc(muscle_group);
    const seriesDoc = await seriesRef.get();

    const points = extractWeeklyPoints(seriesDoc, weekIds);
    const summary = computeSeriesSummary(points);

    return buildResponse({
      muscle_group,
      display_name: getMuscleGroupDisplay(muscle_group),
      weekly_points: points,
      summary,
    }, { limit: weeks });

  } catch (error) {
    if (error instanceof HttpsError) throw error;
    console.error('Error in getMuscleGroupSeries:', error);
    throw new HttpsError('internal', 'Internal error');
  }
});

/**
 * series.muscle.get
 * Get weekly series for a specific muscle
 */
exports.getMuscleSeries = onCall(async (request) => {
  try {
    const userId = requireAuth(request);
    const { muscle, window_weeks } = request.data || {};

    if (!muscle) {
      throw new HttpsError('invalid-argument', 'muscle is required');
    }

    if (!isValidMuscle(muscle)) {
      throw new HttpsError('invalid-argument', `Invalid muscle: ${muscle}`);
    }

    const weeks = Math.min(Math.max(1, window_weeks || CAPS.DEFAULT_WEEKS), CAPS.MAX_WEEKS);
    const weekIds = getRecentWeekStarts(weeks);

    // Get series document
    const seriesRef = db.collection('users').doc(userId)
      .collection('series_muscles').doc(muscle);
    const seriesDoc = await seriesRef.get();

    const points = extractWeeklyPoints(seriesDoc, weekIds);
    const summary = computeSeriesSummary(points);

    return buildResponse({
      muscle,
      display_name: getMuscleDisplay(muscle),
      weekly_points: points,
      summary,
    }, { limit: weeks });

  } catch (error) {
    if (error instanceof HttpsError) throw error;
    console.error('Error in getMuscleSeries:', error);
    throw new HttpsError('internal', 'Internal error');
  }
});
