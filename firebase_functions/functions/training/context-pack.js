/**
 * Context Pack Endpoint
 * Single small call for initial coaching context
 * 
 * Uses onRequest (not onCall) for compatibility with HTTP clients.
 * 
 * @see docs/TRAINING_ANALYTICS_API_V2_SPEC.md Section 6.5
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { fetchUserContext } = require('../shared/planning-context');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const {
  CAPS,
  buildResponse,
  getWeekStart,
  transformWeeklyPoint,
} = require('../utils/caps');
const { MUSCLE_GROUPS, getMuscleGroupDisplay } = require('../utils/muscle-taxonomy');

/**
 * Helper to get last N weeks as YYYY-MM-DD array
 */
function getRecentWeekStarts(weeks) {
  const result = [];
  const now = new Date();
  
  for (let i = 0; i < weeks; i++) {
    const d = new Date(now);
    d.setDate(d.getDate() - (i * 7));
    result.push(getWeekStart(d));
  }
  
  return result.reverse(); // oldest first
}

/**
 * context.coaching.pack
 * Compact context for coaching agent initialization
 */
exports.getCoachingPack = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    // Get userId from auth or body
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return res.status(400).json({ success: false, error: 'userId is required' });
    }
    
    const { window_weeks, top_n_targets } = req.body || {};
    
    const weeks = Math.min(Math.max(1, window_weeks || 8), CAPS.MAX_WEEKS);
    const topN = Math.min(Math.max(1, top_n_targets || 6), Object.keys(MUSCLE_GROUPS).length);
    const weekIds = getRecentWeekStarts(weeks);
    const cutoffDate = weekIds[0];
    
    // Get all muscle group series docs in parallel
    const muscleGroupIds = Object.keys(MUSCLE_GROUPS);
    const seriesPromises = muscleGroupIds.map(group => 
      db.collection('users').doc(userId)
        .collection('series_muscle_groups').doc(group).get()
    );
    
    const seriesDocs = await Promise.all(seriesPromises);
    
    // Calculate total effective volume per group
    const groupVolumes = [];
    
    for (let i = 0; i < muscleGroupIds.length; i++) {
      const groupId = muscleGroupIds[i];
      const doc = seriesDocs[i];
      
      if (!doc.exists) {
        groupVolumes.push({ group: groupId, totalVolume: 0, weeklyPoints: [] });
        continue;
      }
      
      const data = doc.data();
      const weeksData = data.weeks || {};
      
      const weeklyPoints = weekIds
        .filter(wk => weeksData[wk])
        .map(wk => transformWeeklyPoint({ week_start: wk, ...weeksData[wk] }));
      
      const totalVolume = weeklyPoints.reduce(
        (s, p) => s + (p.effective_volume || p.volume || 0), 0
      );
      
      groupVolumes.push({
        group: groupId,
        totalVolume,
        weeklyPoints,
      });
    }
    
    // Sort by volume and take top N
    groupVolumes.sort((a, b) => b.totalVolume - a.totalVolume);
    const topGroups = groupVolumes.slice(0, topN);
    
    // Get top 2-3 exercises per group
    const groupExercisePromises = topGroups.map(async (g) => {
      const exerciseQuery = db.collection('users').doc(userId)
        .collection('set_facts')
        .where('muscle_group_keys', 'array-contains', g.group)
        .where('workout_date', '>=', cutoffDate)
        .where('is_warmup', '==', false)
        .limit(300);
      
      const snap = await exerciseQuery.get();
      const exerciseVolumes = new Map();
      
      for (const doc of snap.docs) {
        const sf = doc.data();
        const exId = sf.exercise_id;
        const contrib = sf.muscle_group_contrib?.[g.group] || 0.5;
        const effVol = (sf.volume || 0) * contrib;
        
        if (!exerciseVolumes.has(exId)) {
          exerciseVolumes.set(exId, { exercise_id: exId, exercise_name: sf.exercise_name, volume: 0 });
        }
        exerciseVolumes.get(exId).volume += effVol;
      }
      
      return {
        group: g.group,
        exercises: Array.from(exerciseVolumes.values())
          .sort((a, b) => b.volume - a.volume)
          .slice(0, 3)
          .map(e => ({ exercise_id: e.exercise_id, exercise_name: e.exercise_name })),
      };
    });
    
    const groupExercises = await Promise.all(groupExercisePromises);
    const groupExerciseMap = new Map(groupExercises.map(ge => [ge.group, ge.exercises]));
    
    // Build target summaries
    const topTargets = topGroups.map(g => ({
      muscle_group: g.group,
      display_name: getMuscleGroupDisplay(g.group),
      weekly_effective_volume: g.weeklyPoints.map(p => ({
        week_start: p.week_start,
        effective_volume: p.effective_volume || p.volume || 0,
        hard_sets: p.hard_sets || 0,
        avg_rir: p.avg_rir,
      })),
      top_exercises: groupExerciseMap.get(g.group) || [],
      total_volume_in_window: Math.round(g.totalVolume * 10) / 10,
    }));
    
    // Adherence stats: sessions per week vs target
    // Query recent workouts
    const recentWorkoutsQuery = db.collection('users').doc(userId)
      .collection('workouts')
      .where('end_time', '>=', admin.firestore.Timestamp.fromDate(new Date(cutoffDate)))
      .orderBy('end_time', 'desc')
      .limit(50);
    
    const workoutsSnap = await recentWorkoutsQuery.get();
    
    // Group by week
    const sessionsPerWeek = new Map();
    for (const doc of workoutsSnap.docs) {
      const workout = doc.data();
      const endTime = workout.end_time?.toDate?.() || new Date(workout.end_time);
      const weekStart = getWeekStart(endTime);
      sessionsPerWeek.set(weekStart, (sessionsPerWeek.get(weekStart) || 0) + 1);
    }
    
    const weeksWithData = sessionsPerWeek.size;
    const totalSessions = Array.from(sessionsPerWeek.values()).reduce((s, c) => s + c, 0);
    const avgSessionsPerWeek = weeksWithData > 0 ? Math.round((totalSessions / weeksWithData) * 10) / 10 : 0;
    
    // Get user target sessions via shared user context
    let targetSessionsPerWeek = null;
    try {
      const userCtx = await fetchUserContext(db, userId);
      targetSessionsPerWeek = userCtx.profile?.target_sessions_per_week || null;
    } catch (e) {
      // Non-critical: adherence target is optional
    }
    
    const adherence = {
      avg_sessions_per_week: avgSessionsPerWeek,
      target_sessions_per_week: targetSessionsPerWeek,
      weeks_analyzed: weeksWithData,
    };
    
    // Change flags
    const changeFlags = [];
    
    // Check for sharp volume drop
    if (topGroups.length > 0) {
      for (const g of topGroups.slice(0, 3)) {
        if (g.weeklyPoints.length >= 2) {
          const recent = g.weeklyPoints.slice(-2);
          const prev = recent[0].effective_volume || recent[0].volume || 0;
          const curr = recent[1].effective_volume || recent[1].volume || 0;
          if (prev > 0 && (prev - curr) / prev > 0.4) {
            changeFlags.push({
              type: 'volume_drop',
              target: g.group,
              message: `${getMuscleGroupDisplay(g.group)} volume dropped >40% last week`,
            });
          }
        }
      }
    }
    
    // Check for high failure rate
    for (const g of topGroups.slice(0, 3)) {
      if (g.weeklyPoints.length > 0) {
        const lastWeek = g.weeklyPoints[g.weeklyPoints.length - 1];
        if ((lastWeek.failure_rate || 0) > 0.35) {
          changeFlags.push({
            type: 'high_failure_rate',
            target: g.group,
            message: `${getMuscleGroupDisplay(g.group)} has high failure rate (>35%)`,
          });
        }
      }
    }
    
    // Check for low training frequency
    if (avgSessionsPerWeek < 2 && weeksWithData >= 2) {
      changeFlags.push({
        type: 'low_frequency',
        message: `Training frequency low (${avgSessionsPerWeek} sessions/week)`,
      });
    }
    
    return res.json(buildResponse({
      top_targets: topTargets,
      adherence,
      change_flags: changeFlags.slice(0, 5), // Cap at 5 flags
      window_weeks: weeks,
      generated_at: new Date().toISOString(),
    }, { limit: topN }));
    
  } catch (error) {
    console.error('Error in getCoachingPack:', error);
    return res.status(500).json({ success: false, error: 'Internal error' });
  }
}));

/**
 * active.snapshotLite
 * Minimal active workout snapshot for agent context
 */
exports.getActiveSnapshotLite = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    // Get userId from auth or body
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return res.status(400).json({ success: false, error: 'userId is required' });
    }
    
    // Get active workout
    const activeRef = db.collection('users').doc(userId).collection('active_workouts').doc('current');
    const activeDoc = await activeRef.get();
    
    if (!activeDoc.exists) {
      return res.json(buildResponse({
        has_active_workout: false,
      }));
    }
    
    const workout = activeDoc.data();
    
    // Find current exercise
    const exercises = workout.exercises || [];
    let currentExercise = null;
    let nextSetIndex = 0;
    let totals = {
      completed_sets: 0,
      total_sets: 0,
      completed_exercises: 0,
      total_exercises: exercises.length,
    };
    
    for (const ex of exercises) {
      const sets = ex.sets || [];
      const completedSets = sets.filter(s => s.is_completed).length;
      totals.completed_sets += completedSets;
      totals.total_sets += sets.length;
      
      if (completedSets === sets.length) {
        totals.completed_exercises += 1;
      }
      
      if (!currentExercise && completedSets < sets.length) {
        currentExercise = {
          exercise_id: ex.exercise_id,
          exercise_name: ex.exercise_name || ex.name,
        };
        nextSetIndex = completedSets;
      }
    }
    
    return res.json(buildResponse({
      has_active_workout: true,
      workout_id: workout.workout_id || activeDoc.id,
      status: workout.status || 'in_progress',
      start_time: workout.start_time?.toDate?.()?.toISOString() || workout.start_time,
      current_exercise: currentExercise,
      next_set_index: nextSetIndex,
      totals,
    }));
    
  } catch (error) {
    console.error('Error in getActiveSnapshotLite:', error);
    return res.status(500).json({ success: false, error: 'Internal error' });
  }
}));
