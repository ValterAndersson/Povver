/**
 * Shared training query logic extracted from training handlers.
 *
 * Each function takes (db, userId, options) — no req/res.
 * Throws ValidationError for bad input.
 * Returns plain data objects; the handler decides response format.
 *
 * Collections used:
 *   - set_facts              (per-user)
 *   - analytics_series_exercise       (per-user, keyed by exercise_id)
 *   - analytics_series_muscle_group   (per-user, keyed by muscle_group)
 *   - series_muscles           (per-user, keyed by muscle — note: analytics-writes.js uses analytics_series_muscle separately)
 *   - analysis_insights       (per-user)
 *   - weekly_reviews          (per-user)
 *   - agent_recommendations   (per-user)
 *   - exercises               (global catalog)
 */

const { ValidationError } = require('./errors');
const {
  CAPS,
  buildResponse,
  enforceQueryCaps,
  validateExactlyOneTarget,
  applyProjection,
  decodeCursor,
  encodeCursor,
  getWeekStart,
  transformWeeklyPoint,
} = require('../utils/caps');
const {
  isValidMuscleGroup,
  isValidMuscle,
  getMuscleGroupDisplay,
  getMuscleDisplay,
  validateMuscleGroupWithRecovery,
  validateMuscleWithRecovery,
} = require('../utils/muscle-taxonomy');

// ---------------------------------------------------------------------------
// Shared helpers (duplicated across series-endpoints.js & progress-summary.js)
// ---------------------------------------------------------------------------

const SORT_OPTIONS = ['date_desc', 'date_asc', 'e1rm_desc', 'volume_desc'];

/**
 * Get last N week-start dates as YYYY-MM-DD array (oldest first).
 */
function getRecentWeekStarts(weeks) {
  const result = [];
  const now = new Date();
  for (let i = 0; i < weeks; i++) {
    const d = new Date(now);
    d.setDate(d.getDate() - (i * 7));
    result.push(getWeekStart(d));
  }
  return result.reverse();
}

/**
 * Extract weekly points from a series document.
 * Returns recent weeks OR all available weeks if recent is empty.
 */
function extractWeeklyPoints(seriesDoc, weekIds) {
  if (!seriesDoc.exists) return [];

  const data = seriesDoc.data();
  const weeks = data.weeks || {};

  const recentPoints = weekIds
    .filter(wk => weeks[wk])
    .map(wk => {
      const raw = weeks[wk];
      return transformWeeklyPoint({ week_start: wk, ...raw });
    });

  // If no recent data, return ALL available weeks (sorted, capped at 52)
  if (recentPoints.length === 0) {
    const allWeeks = Object.keys(weeks).sort();
    return allWeeks.slice(-52).map(wk => {
      const raw = weeks[wk];
      return transformWeeklyPoint({ week_start: wk, ...raw });
    });
  }

  return recentPoints;
}

/**
 * Detect plateau - best weekly e1RM within +/-2% for last 4 weeks.
 */
function detectPlateau(points) {
  if (points.length < 4) return false;
  const lastFour = points.slice(-4);
  const e1rms = lastFour.filter(p => p.e1rm_max).map(p => p.e1rm_max);
  if (e1rms.length < 3) return false;
  const max = Math.max(...e1rms);
  const min = Math.min(...e1rms);
  const range = (max - min) / ((max + min) / 2);
  return range <= 0.02;
}

/**
 * Detect deload - volume drop > 40% week over week.
 */
function detectDeload(points) {
  if (points.length < 2) return false;
  const lastTwo = points.slice(-2);
  const prev = lastTwo[0].effective_volume || lastTwo[0].volume || 0;
  const curr = lastTwo[1].effective_volume || lastTwo[1].volume || 0;
  if (prev === 0) return false;
  const drop = (prev - curr) / prev;
  return drop > 0.4;
}

/**
 * Detect overreach - high failure rate + rising volume for 2+ weeks.
 */
function detectOverreach(points) {
  if (points.length < 2) return false;
  const lastTwo = points.slice(-2);
  const avgFailure = lastTwo.reduce((s, p) => s + (p.failure_rate || 0), 0) / lastTwo.length;
  const avgRir = lastTwo.reduce((s, p) => s + (p.avg_rir || 2), 0) / lastTwo.length;
  const volumeTrend = lastTwo.length >= 2 &&
    (lastTwo[1].volume || 0) > (lastTwo[0].volume || 0);
  return avgFailure > 0.35 && avgRir < 1 && volumeTrend;
}

/**
 * Normalize exercise name for matching.
 */
function normalizeExerciseName(name) {
  if (!name) return '';
  return name.toLowerCase()
    .replace(/[-_]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Find exercise series doc by fuzzy name search.
 * Searches user's analytics_series_exercise collection.
 */
async function findExerciseSeriesByName(db, userId, searchName) {
  const normalized = normalizeExerciseName(searchName);
  if (!normalized) return null;

  const seriesSnap = await db.collection('users').doc(userId)
    .collection('analytics_series_exercise')
    .get();

  if (seriesSnap.empty) return null;

  let bestMatch = null;
  let bestScore = 0;

  for (const doc of seriesSnap.docs) {
    const data = doc.data();
    const exerciseName = data.exercise_name;
    if (!exerciseName) continue;

    const docNormalized = normalizeExerciseName(exerciseName);

    // Exact match
    if (docNormalized === normalized) {
      return { doc, exerciseId: doc.id, exerciseName };
    }

    // Contains match
    if (docNormalized.includes(normalized) || normalized.includes(docNormalized)) {
      const score = Math.min(normalized.length, docNormalized.length) /
                    Math.max(normalized.length, docNormalized.length);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = { doc, exerciseId: doc.id, exerciseName };
      }
    }

    // Word match
    const searchWords = normalized.split(' ');
    const docWords = docNormalized.split(' ');
    const matchingWords = searchWords.filter(w => docWords.some(dw => dw.includes(w) || w.includes(dw)));
    if (matchingWords.length > 0) {
      const score = matchingWords.length / Math.max(searchWords.length, docWords.length);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = { doc, exerciseId: doc.id, exerciseName };
      }
    }
  }

  return bestScore >= 0.5 ? bestMatch : null;
}

/**
 * Compute summary statistics from weekly points.
 * Used by series endpoints.
 */
function computeSeriesSummary(points) {
  if (points.length === 0) {
    return {
      total_weeks: 0,
      avg_weekly_sets: 0,
      avg_weekly_volume: 0,
      avg_weekly_hard_sets: 0,
      trend_direction: null,
    };
  }

  const totalSets = points.reduce((s, p) => s + (p.sets || 0), 0);
  const totalVolume = points.reduce((s, p) => s + (p.volume || 0), 0);
  const totalHardSets = points.reduce((s, p) => s + (p.hard_sets || 0), 0);

  // Simple trend: compare first half to second half
  const mid = Math.floor(points.length / 2);
  let trendDirection = null;
  if (points.length >= 4) {
    const firstHalfAvg = points.slice(0, mid).reduce((s, p) => s + (p.volume || 0), 0) / mid;
    const secondHalfAvg = points.slice(mid).reduce((s, p) => s + (p.volume || 0), 0) / (points.length - mid);
    const change = (secondHalfAvg - firstHalfAvg) / (firstHalfAvg || 1);
    if (change > 0.1) trendDirection = 'increasing';
    else if (change < -0.1) trendDirection = 'decreasing';
    else trendDirection = 'stable';
  }

  return {
    total_weeks: points.length,
    avg_weekly_sets: Math.round((totalSets / points.length) * 10) / 10,
    avg_weekly_volume: Math.round((totalVolume / points.length) * 10) / 10,
    avg_weekly_hard_sets: Math.round((totalHardSets / points.length) * 10) / 10,
    trend_direction: trendDirection,
  };
}

/**
 * Helper to aggregate a set_fact into a group bucket.
 */
function aggregateToGroup(groups, key, sf, weight) {
  if (!groups.has(key)) {
    groups.set(key, {
      sets: 0,
      hard_sets: 0,
      volume: 0,
      effective_volume: 0,
      rir_sum: 0,
      rir_count: 0,
      failure_sets: 0,
      e1rm_max: null,
    });
  }

  const agg = groups.get(key);
  agg.sets += 1;
  agg.hard_sets += (sf.hard_set_credit || 0) * weight;
  agg.volume += (sf.volume || 0) * weight;
  agg.effective_volume += (sf.volume || 0) * weight;

  if (sf.rir !== null && sf.rir !== undefined) {
    agg.rir_sum += sf.rir;
    agg.rir_count += 1;
  }

  if (sf.is_failure) {
    agg.failure_sets += 1;
  }

  if (sf.e1rm !== null && (agg.e1rm_max === null || sf.e1rm > agg.e1rm_max)) {
    agg.e1rm_max = sf.e1rm;
  }
}

// ---------------------------------------------------------------------------
// querySets
// ---------------------------------------------------------------------------

/**
 * Query set_facts with filters, pagination, and projection.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} options - { target, classification, effort, performance, sort, cursor, start, end, limit, fields }
 * @returns {Object} - Standard buildResponse envelope
 */
async function querySets(db, userId, options = {}) {
  const { target, classification, effort, performance, sort, cursor, start, end, limit, fields } = options;

  // Validate exactly one target
  validateExactlyOneTarget(target);

  // Enforce caps
  const caps = enforceQueryCaps({ limit, fields, target });
  const actualLimit = caps.limit;
  const projectedFields = caps.fields;

  // Validate sort
  const sortMode = sort || 'date_desc';
  if (!SORT_OPTIONS.includes(sortMode)) {
    throw new ValidationError(`Invalid sort: ${sortMode}. Valid: ${SORT_OPTIONS.join(', ')}`);
  }

  // Decode cursor if present
  const cursorData = decodeCursor(cursor, sortMode);

  // Build query
  let query = db.collection('users').doc(userId).collection('set_facts');

  // Target filter (exactly one) with self-healing validation
  if (target.muscle_group) {
    const validation = validateMuscleGroupWithRecovery(target.muscle_group);
    if (!validation.valid) {
      throw new ValidationError(validation.message, {
        validOptions: validation.validOptions,
        hint: 'Use one of the validOptions values for muscle_group',
      });
    }
    query = query.where('muscle_group_keys', 'array-contains', target.muscle_group);
  } else if (target.muscle) {
    const validation = validateMuscleWithRecovery(target.muscle);
    if (!validation.valid) {
      throw new ValidationError(validation.message, {
        validOptions: validation.validOptions,
        suggestions: validation.suggestions,
        hint: 'Use one of the suggestions or validOptions values for muscle',
      });
    }
    query = query.where('muscle_keys', 'array-contains', target.muscle);
  } else if (target.exercise_name) {
    // Fuzzy search by exercise name - find matching exercise_ids from user's set_facts
    const nameQuery = target.exercise_name.toLowerCase().trim();
    const exerciseScan = await db.collection('users').doc(userId).collection('set_facts')
      .where('is_warmup', '==', false)
      .orderBy('workout_end_time', 'desc')
      .limit(500)
      .get();

    // Find distinct exercise_ids where name matches
    const matchingIds = new Set();
    for (const doc of exerciseScan.docs) {
      const sf = doc.data();
      const exerciseName = (sf.exercise_name || '').toLowerCase();
      if (exerciseName.includes(nameQuery) || nameQuery.includes(exerciseName.split(' ')[0])) {
        matchingIds.add(sf.exercise_id);
        if (matchingIds.size >= CAPS.MAX_EXERCISE_IDS_FILTER) break;
      }
    }

    if (matchingIds.size === 0) {
      // Return empty result with helpful message
      return buildResponse([], {
        limit: actualLimit,
        hasMore: false,
        message: `No exercises found matching "${target.exercise_name}" in your training history`,
      });
    }

    query = query.where('exercise_id', 'in', Array.from(matchingIds));
  } else if (target.exercise_ids?.length > 0) {
    query = query.where('exercise_id', 'in', target.exercise_ids.slice(0, CAPS.MAX_EXERCISE_IDS_FILTER));
  }

  // Date range filters
  if (start) {
    query = query.where('workout_date', '>=', start);
  }
  if (end) {
    query = query.where('workout_date', '<=', end);
  }

  // Classification filters
  if (classification) {
    if (classification.equipment) {
      query = query.where('equipment', '==', classification.equipment);
    }
    if (classification.movement_pattern) {
      query = query.where('movement_pattern', '==', classification.movement_pattern);
    }
    if (classification.is_isolation !== undefined) {
      query = query.where('is_isolation', '==', classification.is_isolation);
    }
  }

  // Effort filters
  const includeWarmups = effort?.include_warmups || false;
  if (!includeWarmups) {
    query = query.where('is_warmup', '==', false);
  }
  if (effort?.is_failure !== undefined) {
    query = query.where('is_failure', '==', effort.is_failure);
  }

  // Apply sort and pagination
  // When date range filters (start/end) are present, Firestore requires
  // the first orderBy to be on the inequality field (workout_date).
  const hasDateRange = !!(start || end);
  let firestoreSort = hasDateRange ? 'workout_date' : 'workout_end_time';
  let firestoreDirection = 'desc';

  if (sortMode === 'date_asc') {
    firestoreDirection = 'asc';
  }

  query = query.orderBy(firestoreSort, firestoreDirection);

  // Apply cursor
  if (cursorData?.last_value) {
    // When sorting by workout_date (string), use string cursor; otherwise Date
    const cursorValue = hasDateRange ? cursorData.last_value : new Date(cursorData.last_value);
    query = query.startAfter(cursorValue);
  }

  // Limit +1 to detect hasMore
  query = query.limit(actualLimit + 1);

  // Execute query
  const snapshot = await query.get();
  let results = snapshot.docs.map(doc => ({ ...doc.data(), set_id: doc.id }));

  // Post-query filters (for fields not supported in Firestore query)
  if (effort?.rir_min !== undefined) {
    results = results.filter(r => r.rir !== null && r.rir >= effort.rir_min);
  }
  if (effort?.rir_max !== undefined) {
    results = results.filter(r => r.rir !== null && r.rir <= effort.rir_max);
  }
  if (effort?.rpe_min !== undefined) {
    results = results.filter(r => r.rpe !== null && r.rpe >= effort.rpe_min);
  }
  if (effort?.rpe_max !== undefined) {
    results = results.filter(r => r.rpe !== null && r.rpe <= effort.rpe_max);
  }

  if (performance?.reps_min !== undefined) {
    results = results.filter(r => r.reps >= performance.reps_min);
  }
  if (performance?.reps_max !== undefined) {
    results = results.filter(r => r.reps <= performance.reps_max);
  }
  if (performance?.weight_min !== undefined) {
    results = results.filter(r => r.weight_kg >= performance.weight_min);
  }
  if (performance?.weight_max !== undefined) {
    results = results.filter(r => r.weight_kg <= performance.weight_max);
  }
  if (performance?.e1rm_min !== undefined) {
    results = results.filter(r => r.e1rm !== null && r.e1rm >= performance.e1rm_min);
  }
  if (performance?.e1rm_max !== undefined) {
    results = results.filter(r => r.e1rm !== null && r.e1rm <= performance.e1rm_max);
  }

  // Handle special sorts that require post-query sorting
  if (sortMode === 'e1rm_desc') {
    results.sort((a, b) => (b.e1rm || 0) - (a.e1rm || 0));
  } else if (sortMode === 'volume_desc') {
    results.sort((a, b) => (b.volume || 0) - (a.volume || 0));
  }

  // Check hasMore
  const hasMore = results.length > actualLimit;
  if (hasMore) {
    results = results.slice(0, actualLimit);
  }

  // Build next cursor
  let nextCursorData = null;
  if (hasMore && results.length > 0) {
    const lastResult = results[results.length - 1];
    const endTime = lastResult.workout_end_time;
    nextCursorData = {
      sort: sortMode,
      last_value: endTime?.toDate ? endTime.toDate().toISOString() : endTime,
    };
  }

  // Apply projection
  const projectedResults = results.map(r => applyProjection(r, projectedFields));

  return buildResponse(projectedResults, {
    limit: actualLimit,
    hasMore,
    cursorData: nextCursorData,
  });
}

// ---------------------------------------------------------------------------
// aggregateSets
// ---------------------------------------------------------------------------

/**
 * Compute rollups from set_facts for custom grouping.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} options - { target, group_by, metrics, start, end }
 * @returns {Object} - Standard buildResponse envelope
 */
async function aggregateSets(db, userId, options = {}) {
  const { target, group_by, metrics, start, end } = options;

  // Validate target
  validateExactlyOneTarget(target);

  // Validate group_by
  const validGroupBy = ['day', 'week', 'exercise', 'muscle_group', 'muscle'];
  const groupBy = group_by || 'week';
  if (!validGroupBy.includes(groupBy)) {
    throw new ValidationError(`Invalid group_by: ${groupBy}. Valid: ${validGroupBy.join(', ')}`);
  }

  // Validate metrics
  const validMetrics = ['sets', 'hard_sets', 'volume', 'effective_volume', 'avg_rir', 'failure_rate', 'e1rm_max'];
  const requestedMetrics = metrics || ['sets', 'volume'];
  for (const m of requestedMetrics) {
    if (!validMetrics.includes(m)) {
      throw new ValidationError(`Invalid metric: ${m}`);
    }
  }

  // Build query
  let query = db.collection('users').doc(userId).collection('set_facts')
    .where('is_warmup', '==', false);

  // Target filter
  if (target.muscle_group) {
    query = query.where('muscle_group_keys', 'array-contains', target.muscle_group);
  } else if (target.muscle) {
    query = query.where('muscle_keys', 'array-contains', target.muscle);
  } else if (target.exercise_ids?.length > 0) {
    query = query.where('exercise_id', 'in', target.exercise_ids.slice(0, CAPS.MAX_EXERCISE_IDS_FILTER));
  }

  // Date range
  if (start) {
    query = query.where('workout_date', '>=', start);
  }
  if (end) {
    query = query.where('workout_date', '<=', end);
  }

  // Limit to prevent overfetch
  query = query.limit(CAPS.MAX_LIMIT * 10); // 2000 max for aggregation

  const snapshot = await query.get();
  const results = snapshot.docs.map(doc => doc.data());

  // Group results
  const groups = new Map();

  for (const sf of results) {
    let groupKey;

    switch (groupBy) {
      case 'day':
        groupKey = sf.workout_date;
        break;
      case 'week': {
        const d = new Date(sf.workout_date);
        const day = d.getDay();
        const diff = d.getDate() - day + (day === 0 ? -6 : 1);
        const monday = new Date(d.setDate(diff));
        groupKey = monday.toISOString().split('T')[0];
        break;
      }
      case 'exercise':
        groupKey = sf.exercise_id;
        break;
      case 'muscle_group':
        for (const group of sf.muscle_group_keys || []) {
          aggregateToGroup(groups, group, sf, target.muscle_group === group ? 1 : (sf.muscle_group_contrib?.[group] || 0.5));
        }
        continue; // Skip main aggregation
      case 'muscle':
        for (const muscle of sf.muscle_keys || []) {
          aggregateToGroup(groups, muscle, sf, target.muscle === muscle ? 1 : (sf.muscle_contrib?.[muscle] || 0.5));
        }
        continue; // Skip main aggregation
      default:
        groupKey = 'all';
    }

    aggregateToGroup(groups, groupKey, sf, 1);
  }

  // Format output
  const output = [];
  for (const [key, agg] of groups) {
    const point = { group_key: key };

    for (const metric of requestedMetrics) {
      switch (metric) {
        case 'sets':
          point.sets = agg.sets;
          break;
        case 'hard_sets':
          point.hard_sets = Math.round(agg.hard_sets * 10) / 10;
          break;
        case 'volume':
          point.volume = Math.round(agg.volume * 10) / 10;
          break;
        case 'effective_volume':
          point.effective_volume = Math.round(agg.effective_volume * 10) / 10;
          break;
        case 'avg_rir':
          point.avg_rir = agg.rir_count > 0 ? Math.round((agg.rir_sum / agg.rir_count) * 10) / 10 : null;
          break;
        case 'failure_rate':
          point.failure_rate = agg.sets > 0 ? Math.round((agg.failure_sets / agg.sets) * 100) / 100 : 0;
          break;
        case 'e1rm_max':
          point.e1rm_max = agg.e1rm_max;
          break;
      }
    }

    output.push(point);
  }

  // Sort by group_key
  output.sort((a, b) => a.group_key.localeCompare(b.group_key));

  return buildResponse(output, { limit: output.length });
}

// ---------------------------------------------------------------------------
// getAnalysisSummary
// ---------------------------------------------------------------------------

/**
 * Get today's date in YYYY-MM-DD format (UTC).
 */
function getTodayDateKey() {
  return new Date().toISOString().split('T')[0];
}

/**
 * Returns pre-computed analysis data from multiple collections.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} options - { sections, limit, date }
 * @param {Object} admin - firebase-admin module (needed for Timestamp)
 * @returns {Object} - Analysis summary response payload
 */
async function getAnalysisSummary(db, userId, options = {}, admin) {
  const sections = options.sections || null;
  const insightsLimit = options.limit || 5;
  // eslint-disable-next-line no-unused-vars
  const dateKey = options.date || getTodayDateKey();

  const validSections = ['insights', 'weekly_review', 'recommendation_history'];
  const requestedSections = sections
    ? sections.filter(s => validSections.includes(s))
    : validSections;

  const now = admin.firestore.Timestamp.now();

  // Build parallel reads for only requested sections
  const reads = {};

  if (requestedSections.includes('insights')) {
    reads.insights = db.collection('users').doc(userId)
      .collection('analysis_insights')
      .where('expires_at', '>', now)
      .orderBy('expires_at')
      .limit(50)
      .get();
  }

  if (requestedSections.includes('weekly_review')) {
    reads.weekly_review = db.collection('users').doc(userId)
      .collection('weekly_reviews')
      .orderBy('created_at', 'desc')
      .limit(1)
      .get();
  }

  if (requestedSections.includes('recommendation_history')) {
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    reads.recommendation_history = db.collection('users').doc(userId)
      .collection('agent_recommendations')
      .where('created_at', '>', admin.firestore.Timestamp.fromDate(thirtyDaysAgo))
      .orderBy('created_at', 'desc')
      .limit(20)
      .get();
  }

  // Execute all reads in parallel
  const keys = Object.keys(reads);
  const snapshots = await Promise.all(keys.map(k => reads[k]));
  const results = {};
  keys.forEach((k, i) => { results[k] = snapshots[i]; });

  // Build response payload
  const response = { generated_at: new Date().toISOString() };

  if (results.insights) {
    const insights = [];
    for (const doc of results.insights.docs) {
      const data = doc.data();
      const insight = {
        id: doc.id,
        type: data.type,
        workout_id: data.workout_id || null,
        workout_date: data.workout_date || null,
        summary: data.summary || '',
        highlights: data.highlights || [],
        flags: data.flags || [],
        recommendations: data.recommendations || [],
        created_at: data.created_at?.toDate?.()?.toISOString() || data.created_at,
        expires_at: data.expires_at?.toDate?.()?.toISOString() || data.expires_at,
      };
      if (data.template_diff_summary) {
        insight.template_diff_summary = data.template_diff_summary;
      }
      insights.push(insight);
    }
    // Sort by workout_date descending so most recent workouts come first
    insights.sort((a, b) => (b.workout_date || '').localeCompare(a.workout_date || ''));
    response.insights = insights.slice(0, insightsLimit);
  }

  if (results.weekly_review) {
    let weeklyReview = null;
    if (!results.weekly_review.empty) {
      const doc = results.weekly_review.docs[0];
      const data = doc.data();
      weeklyReview = {
        id: doc.id,
        week_ending: data.week_ending || null,
        summary: data.summary || '',
        training_load: {
          ...(data.training_load || {}),
          acwr: data.training_load?.acwr || null,
        },
        muscle_balance: data.muscle_balance || [],
        exercise_trends: data.exercise_trends || [],
        progression_candidates: data.progression_candidates || [],
        stalled_exercises: data.stalled_exercises || [],
        periodization: data.periodization || null,
        routine_recommendations: data.routine_recommendations || [],
        fatigue_status: data.fatigue_status || null,
        created_at: data.created_at?.toDate?.()?.toISOString() || data.created_at,
      };
    }
    response.weekly_review = weeklyReview;
  }

  if (results.recommendation_history) {
    const recommendations = [];
    for (const doc of results.recommendation_history.docs) {
      const data = doc.data();
      const rec = data.recommendation || {};
      const target = data.target || {};
      recommendations.push({
        id: doc.id,
        created_at: data.created_at?.toDate?.()?.toISOString() || data.created_at,
        state: data.state || 'unknown',
        scope: data.scope || null,
        trigger: data.trigger || null,
        target: {
          exercise_name: target.exercise_name || null,
          template_name: target.template_name || null,
          muscle_group: target.muscle_group || null,
        },
        recommendation: {
          type: rec.type || null,
          summary: rec.summary || '',
          rationale: rec.rationale || null,
          confidence: rec.confidence || null,
          change_count: (rec.changes || []).length,
        },
        applied_at: data.applied_at?.toDate?.()?.toISOString() || data.applied_at || null,
        applied_by: data.applied_by || null,
      });
    }
    response.recommendation_history = recommendations;
  }

  return response;
}

// ---------------------------------------------------------------------------
// getMuscleGroupSummary
// ---------------------------------------------------------------------------

/**
 * Summary for a muscle group with series, top exercises, and flags.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} options - { muscle_group, window_weeks, include_distribution }
 * @returns {Object} - buildResponse envelope
 */
async function getMuscleGroupSummary(db, userId, options = {}) {
  const { muscle_group, window_weeks, include_distribution } = options;

  // Self-healing validation with recovery info
  const validation = validateMuscleGroupWithRecovery(muscle_group);
  if (!validation.valid) {
    throw new ValidationError(validation.message, {
      validOptions: validation.validOptions,
      hint: 'Use one of the validOptions values for muscle_group',
    });
  }

  const weeks = Math.min(Math.max(1, window_weeks || CAPS.DEFAULT_WEEKS), CAPS.MAX_WEEKS);
  const weekIds = getRecentWeekStarts(weeks);

  // Get muscle group series
  const seriesRef = db.collection('users').doc(userId)
    .collection('analytics_series_muscle_group').doc(muscle_group);
  const seriesDoc = await seriesRef.get();
  const weeklyPoints = extractWeeklyPoints(seriesDoc, weekIds);

  // Get top exercises by volume (from set_facts)
  const cutoffDate = weekIds[0];
  const exerciseQuery = db.collection('users').doc(userId)
    .collection('set_facts')
    .where('muscle_group_keys', 'array-contains', muscle_group)
    .where('workout_date', '>=', cutoffDate)
    .where('is_warmup', '==', false)
    .limit(500);

  const exerciseSnap = await exerciseQuery.get();
  const exerciseVolumes = new Map();

  for (const doc of exerciseSnap.docs) {
    const sf = doc.data();
    const exId = sf.exercise_id;
    const contrib = sf.muscle_group_contrib?.[muscle_group] || 0.5;
    const effVol = (sf.volume || 0) * contrib;

    if (!exerciseVolumes.has(exId)) {
      exerciseVolumes.set(exId, {
        exercise_id: exId,
        exercise_name: sf.exercise_name,
        effective_volume: 0,
        sets: 0,
      });
    }

    const entry = exerciseVolumes.get(exId);
    entry.effective_volume += effVol;
    entry.sets += 1;
  }

  // Sort by volume and take top 5
  const topExercises = Array.from(exerciseVolumes.values())
    .sort((a, b) => b.effective_volume - a.effective_volume)
    .slice(0, CAPS.MAX_TOP_EXERCISES)
    .map(e => ({
      exercise_id: e.exercise_id,
      exercise_name: e.exercise_name,
      effective_volume: Math.round(e.effective_volume * 10) / 10,
      sets: e.sets,
    }));

  // Compute summary stats
  const totalVolume = weeklyPoints.reduce((s, p) => s + (p.effective_volume || p.volume || 0), 0);
  const totalSets = weeklyPoints.reduce((s, p) => s + (p.sets || 0), 0);
  const totalHardSets = weeklyPoints.reduce((s, p) => s + (p.hard_sets || 0), 0);

  const avgWeeklyVolume = weeklyPoints.length > 0 ? totalVolume / weeklyPoints.length : 0;
  const avgWeeklySets = weeklyPoints.length > 0 ? totalSets / weeklyPoints.length : 0;

  // Detect flags
  const flags = {
    plateau: detectPlateau(weeklyPoints),
    deload: detectDeload(weeklyPoints),
    overreach: detectOverreach(weeklyPoints),
  };

  // Optional: include reps distribution
  let repDistribution = null;
  if (include_distribution) {
    repDistribution = {
      '1-5': 0,
      '6-10': 0,
      '11-15': 0,
      '16-20': 0,
    };
    for (const p of weeklyPoints) {
      if (p.reps_bucket) {
        for (const [bucket, count] of Object.entries(p.reps_bucket)) {
          repDistribution[bucket] = (repDistribution[bucket] || 0) + count;
        }
      }
    }
  }

  return buildResponse({
    muscle_group,
    display_name: getMuscleGroupDisplay(muscle_group),
    weekly_points: weeklyPoints,
    top_exercises: topExercises,
    summary: {
      total_weeks_with_data: weeklyPoints.length,
      avg_weekly_volume: Math.round(avgWeeklyVolume * 10) / 10,
      avg_weekly_sets: Math.round(avgWeeklySets * 10) / 10,
      avg_weekly_hard_sets: Math.round((totalHardSets / Math.max(weeklyPoints.length, 1)) * 10) / 10,
    },
    flags,
    reps_distribution: repDistribution,
  }, { limit: weeks });
}

// ---------------------------------------------------------------------------
// getMuscleSummary
// ---------------------------------------------------------------------------

/**
 * Summary for a specific muscle with series, top exercises, and flags.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} options - { muscle, window_weeks }
 * @returns {Object} - buildResponse envelope
 */
async function getMuscleSummary(db, userId, options = {}) {
  const { muscle, window_weeks } = options;

  // Self-healing validation with recovery info
  const validation = validateMuscleWithRecovery(muscle);
  if (!validation.valid) {
    throw new ValidationError(validation.message, {
      validOptions: validation.validOptions,
      suggestions: validation.suggestions,
      hint: 'Use one of the suggestions or validOptions values for muscle',
    });
  }

  const weeks = Math.min(Math.max(1, window_weeks || CAPS.DEFAULT_WEEKS), CAPS.MAX_WEEKS);
  const weekIds = getRecentWeekStarts(weeks);

  // Get muscle series
  const seriesRef = db.collection('users').doc(userId)
    .collection('series_muscles').doc(muscle);
  const seriesDoc = await seriesRef.get();
  const weeklyPoints = extractWeeklyPoints(seriesDoc, weekIds);

  // Get top exercises for this muscle
  const cutoffDate = weekIds[0];
  const exerciseQuery = db.collection('users').doc(userId)
    .collection('set_facts')
    .where('muscle_keys', 'array-contains', muscle)
    .where('workout_date', '>=', cutoffDate)
    .where('is_warmup', '==', false)
    .limit(500);

  const exerciseSnap = await exerciseQuery.get();
  const exerciseVolumes = new Map();

  for (const doc of exerciseSnap.docs) {
    const sf = doc.data();
    const exId = sf.exercise_id;
    const contrib = sf.muscle_contrib?.[muscle] || 0.5;
    const effVol = (sf.volume || 0) * contrib;

    if (!exerciseVolumes.has(exId)) {
      exerciseVolumes.set(exId, {
        exercise_id: exId,
        exercise_name: sf.exercise_name,
        effective_volume: 0,
        sets: 0,
      });
    }

    const entry = exerciseVolumes.get(exId);
    entry.effective_volume += effVol;
    entry.sets += 1;
  }

  // Sort by volume and take top 5
  const topExercises = Array.from(exerciseVolumes.values())
    .sort((a, b) => b.effective_volume - a.effective_volume)
    .slice(0, CAPS.MAX_TOP_EXERCISES)
    .map(e => ({
      exercise_id: e.exercise_id,
      exercise_name: e.exercise_name,
      effective_volume: Math.round(e.effective_volume * 10) / 10,
      sets: e.sets,
    }));

  // Compute summary stats
  const totalVolume = weeklyPoints.reduce((s, p) => s + (p.effective_volume || p.volume || 0), 0);
  const totalSets = weeklyPoints.reduce((s, p) => s + (p.sets || 0), 0);

  // Detect flags
  const flags = {
    plateau: detectPlateau(weeklyPoints),
    deload: detectDeload(weeklyPoints),
    overreach: detectOverreach(weeklyPoints),
  };

  return buildResponse({
    muscle,
    display_name: getMuscleDisplay(muscle),
    weekly_points: weeklyPoints,
    top_exercises: topExercises,
    summary: {
      total_weeks_with_data: weeklyPoints.length,
      avg_weekly_volume: Math.round((totalVolume / Math.max(weeklyPoints.length, 1)) * 10) / 10,
      avg_weekly_sets: Math.round((totalSets / Math.max(weeklyPoints.length, 1)) * 10) / 10,
    },
    flags,
  }, { limit: weeks });
}

// ---------------------------------------------------------------------------
// getExerciseSummary
// ---------------------------------------------------------------------------

/**
 * Summary for a specific exercise with series, last session, PR markers, and flags.
 *
 * @param {Firestore} db
 * @param {string} userId
 * @param {Object} options - { exercise_id, exercise_name, window_weeks }
 * @returns {Object} - buildResponse envelope
 */
async function getExerciseSummary(db, userId, options = {}) {
  let { exercise_id, exercise_name, window_weeks } = options;

  // Resolve exercise_name to exercise_id via user's training history
  if (!exercise_id && exercise_name) {
    const nameQuery = exercise_name.toLowerCase().trim();
    const scan = await db.collection('users').doc(userId).collection('set_facts')
      .where('is_warmup', '==', false)
      .orderBy('workout_end_time', 'desc')
      .limit(200)
      .get();
    for (const doc of scan.docs) {
      const sf = doc.data();
      const name = (sf.exercise_name || '').toLowerCase();
      if (name.includes(nameQuery)) {
        exercise_id = sf.exercise_id;
        break;
      }
    }
  }

  if (!exercise_id) {
    throw new ValidationError('exercise_id or exercise_name is required');
  }

  const weeks = Math.min(Math.max(1, window_weeks || CAPS.DEFAULT_WEEKS), CAPS.MAX_WEEKS);
  const weekIds = getRecentWeekStarts(weeks);

  // Get exercise series
  const seriesRef = db.collection('users').doc(userId)
    .collection('analytics_series_exercise').doc(exercise_id);
  const seriesDoc = await seriesRef.get();
  const weeklyPoints = extractWeeklyPoints(seriesDoc, weekIds);

  // Get exercise name from catalog
  let exerciseName = null;
  try {
    const exDoc = await db.collection('exercises').doc(exercise_id).get();
    if (exDoc.exists) {
      exerciseName = exDoc.data().name;
    }
  } catch (e) {
    // Ignore - name is optional
  }

  // Get last session recap (last 3 sets)
  const lastSessionQuery = db.collection('users').doc(userId)
    .collection('set_facts')
    .where('exercise_id', '==', exercise_id)
    .where('is_warmup', '==', false)
    .orderBy('workout_end_time', 'desc')
    .limit(10);

  const lastSnap = await lastSessionQuery.get();

  // Group by workout to get last session
  const workoutSets = new Map();
  for (const doc of lastSnap.docs) {
    const sf = doc.data();
    const wId = sf.workout_id;
    if (!workoutSets.has(wId)) {
      workoutSets.set(wId, []);
    }
    workoutSets.get(wId).push({
      set_index: sf.set_index,
      reps: sf.reps,
      weight_kg: sf.weight_kg,
      rir: sf.rir,
      e1rm: sf.e1rm,
    });
  }

  // Get first workout's sets (most recent) - all working sets
  let lastSessionSets = [];
  for (const [_, sets] of workoutSets) {
    lastSessionSets = sets.sort((a, b) => a.set_index - b.set_index);
    break;
  }

  // Find PR markers
  let allTimeE1rmMax = null;
  let windowE1rmMax = null;

  for (const p of weeklyPoints) {
    if (p.e1rm_max !== null && p.e1rm_max !== undefined) {
      if (windowE1rmMax === null || p.e1rm_max > windowE1rmMax) {
        windowE1rmMax = p.e1rm_max;
      }
    }
  }

  // All-time: check series doc
  if (seriesDoc.exists) {
    const data = seriesDoc.data();
    const allWeeks = data.weeks || {};
    for (const wk of Object.values(allWeeks)) {
      if (wk.e1rm_max !== null && wk.e1rm_max !== undefined) {
        if (allTimeE1rmMax === null || wk.e1rm_max > allTimeE1rmMax) {
          allTimeE1rmMax = wk.e1rm_max;
        }
      }
    }
  }

  // Detect plateau
  const flags = {
    plateau: detectPlateau(weeklyPoints),
  };

  return buildResponse({
    exercise_id,
    exercise_name: exerciseName,
    weekly_points: weeklyPoints,
    last_session: lastSessionSets,
    pr_markers: {
      all_time_e1rm: allTimeE1rmMax,
      window_e1rm: windowE1rmMax,
    },
    summary: {
      total_weeks_with_data: weeklyPoints.length,
      avg_weekly_volume: weeklyPoints.length > 0
        ? Math.round((weeklyPoints.reduce((s, p) => s + (p.volume || 0), 0) / weeklyPoints.length) * 10) / 10
        : 0,
      avg_weekly_sets: weeklyPoints.length > 0
        ? Math.round((weeklyPoints.reduce((s, p) => s + (p.sets || 0), 0) / weeklyPoints.length) * 10) / 10
        : 0,
    },
    flags,
  }, { limit: weeks });
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  // Core query functions
  querySets,
  aggregateSets,
  getAnalysisSummary,
  getMuscleGroupSummary,
  getMuscleSummary,
  getExerciseSummary,

  // Exported for series-endpoints (onCall handlers that build their own response)
  getRecentWeekStarts,
  extractWeeklyPoints,
  computeSeriesSummary,
  findExerciseSeriesByName,
  normalizeExerciseName,

  // Exported for testing
  detectPlateau,
  detectDeload,
  detectOverreach,
  aggregateToGroup,
  SORT_OPTIONS,
};
