/**
 * shared/planning-context.js - Core planning context assembly
 *
 * Pure business logic for assembling agent planning context.
 * No req/res — accepts a Firestore db instance and userId.
 *
 * FIELD NAME CONTRACT (per FIRESTORE_SCHEMA.md):
 * - User name: `name` (NOT `display_name`)
 * - User attributes: `users/{uid}/user_attributes/{uid}` subcollection
 * - Training level: `fitness_level` from user_attributes (NOT `training_level`)
 * - Goals: `fitness_goal` from user_attributes (singular, NOT `goals` array)
 * - Recent workouts: ordered by `end_time` desc
 * - Weekly stats: `weekly_stats/{week_start_date}` (NOT `weekly_stats/current`)
 *
 * CALLED BY:
 * - agents/get-planning-context.js (HTTP handler wrapper)
 * - training/context-pack.js (user profile reuse)
 */

/**
 * Sensitive fields stripped from user profile before inclusion in agent context.
 * These contain subscription internals and auth tokens that agents must not see.
 */
const SENSITIVE_USER_FIELDS = [
  'subscription_original_transaction_id',
  'subscription_app_account_token',
  'apple_authorization_code',
  'subscription_environment',
];

/**
 * Strip sensitive fields from a user profile object.
 * @param {Object} userData - Raw user document data
 * @returns {Object} Sanitized user data
 */
function sanitizeUserProfile(userData) {
  const result = { ...userData };
  for (const field of SENSITIVE_USER_FIELDS) {
    delete result[field];
  }
  return result;
}

/**
 * Fetch user profile and attributes, sanitized for agent consumption.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @returns {Promise<{profile: Object, attributes: Object|null, weight_unit: string}>}
 */
async function fetchUserContext(db, userId) {
  const [userDoc, attrsDoc] = await Promise.all([
    db.collection('users').doc(userId).get(),
    db.collection('users').doc(userId)
      .collection('user_attributes').doc(userId).get(),
  ]);

  const rawUser = userDoc.exists ? userDoc.data() : {};
  const safeUser = sanitizeUserProfile(rawUser);
  const attributes = attrsDoc.exists ? attrsDoc.data() : null;

  // Derive weight_unit from user_attributes.weight_format
  const weightUnit = attributes?.weight_format === 'pounds' ? 'lbs' : 'kg';

  return {
    profile: { id: userId, ...safeUser, attributes },
    attributes,
    weight_unit: weightUnit,
    // Expose activeRoutineId for downstream callers
    activeRoutineId: rawUser.activeRoutineId || null,
  };
}

/**
 * Fetch recent workouts ordered by end_time desc with exercise detail.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {number} limit - Max workouts to return (default 20)
 * @returns {Promise<Array>} Workout summaries with per-exercise set data
 */
async function fetchRecentWorkouts(db, userId, limit = 20) {
  const workoutsSnapshot = await db.collection('users').doc(userId)
    .collection('workouts')
    .orderBy('end_time', 'desc')
    .limit(limit)
    .get();

  return workoutsSnapshot.docs.map(doc => {
    const w = doc.data();
    return {
      id: doc.id,
      source_template_id: w.source_template_id,
      source_routine_id: w.source_routine_id,
      end_time: w.end_time,
      total_sets: w.analytics?.total_sets,
      total_volume: w.analytics?.total_weight,
      exercises: (w.exercises || []).slice(0, 15).map(ex => {
        const allSets = ex.sets || [];
        const workingSets = allSets.filter(s => s.type !== 'warmup' && s.is_completed !== false);
        return {
          name: ex.name || ex.exercise_name,
          exercise_id: ex.exercise_id || null,
          working_sets: workingSets.length,
          sets: workingSets.map(s => ({
            reps: s.reps || 0,
            weight_kg: s.weight_kg || 0,
            rir: s.rir ?? null,
          })),
        };
      }),
    };
  });
}

/**
 * Compute strength summary from workout data (no extra Firestore reads).
 * Extracts per-exercise max performance (best e1RM) from workout data already fetched.
 * Returns top 15 exercises sorted by e1RM descending.
 *
 * @param {Array} workouts - Workout summaries with exercises[].sets[]
 * @returns {Array<{id: string, name: string, weight: number, reps: number, e1rm: number}>}
 */
function buildStrengthSummary(workouts) {
  const exercises = new Map();

  for (const w of workouts) {
    for (const ex of (w.exercises || [])) {
      const id = ex.exercise_id;
      if (!id) continue;

      let bestE1rm = 0, maxWeight = 0, bestReps = 0;
      for (const s of (ex.sets || [])) {
        const wt = s.weight_kg || 0;
        const reps = s.reps || 0;
        if (wt <= 0) continue;
        if (wt > maxWeight) { maxWeight = wt; bestReps = reps; }
        if (reps > 0 && reps <= 12) {
          bestE1rm = Math.max(bestE1rm, wt * (1 + reps / 30));
        }
      }

      if (maxWeight <= 0) continue;
      const prev = exercises.get(id);
      if (!prev || bestE1rm > (prev.e1rm || 0)) {
        exercises.set(id, {
          name: ex.name,
          weight: maxWeight,
          reps: bestReps,
          e1rm: Math.round(bestE1rm * 10) / 10 || null,
        });
      }
    }
  }

  return Array.from(exercises.entries())
    .map(([id, d]) => ({ id, ...d }))
    .filter(e => e.e1rm > 0)
    .sort((a, b) => b.e1rm - a.e1rm)
    .slice(0, 15);
}

/**
 * Determine next workout from routine cursor or history scan.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {Object} routine - Routine document data (must include template_ids)
 * @returns {Promise<{templateId, templateIndex, templateCount, selectionMethod}|null>}
 */
async function resolveNextWorkout(db, userId, routine) {
  const templateIds = routine.template_ids || routine.templateIds || [];
  if (templateIds.length === 0) return null;

  // Primary: use cursor from last_completed_template_id
  if (routine.last_completed_template_id && templateIds.includes(routine.last_completed_template_id)) {
    const lastIndex = templateIds.indexOf(routine.last_completed_template_id);
    const nextIndex = (lastIndex + 1) % templateIds.length;
    return {
      templateId: templateIds[nextIndex],
      templateIndex: nextIndex,
      templateCount: templateIds.length,
      selectionMethod: 'cursor',
    };
  }

  // Fallback: scan recent workouts for last template match
  const workoutsSnapshot = await db.collection('users').doc(userId)
    .collection('workouts')
    .orderBy('end_time', 'desc')
    .limit(50)
    .get();

  const workouts = workoutsSnapshot.docs.map(d => ({ id: d.id, ...d.data() }));
  const templateSet = new Set(templateIds);
  const lastMatch = workouts.find(w => w.source_template_id && templateSet.has(w.source_template_id));

  if (lastMatch) {
    const lastIndex = templateIds.indexOf(lastMatch.source_template_id);
    if (lastIndex >= 0) {
      const nextIndex = (lastIndex + 1) % templateIds.length;
      return {
        templateId: templateIds[nextIndex],
        templateIndex: nextIndex,
        templateCount: templateIds.length,
        selectionMethod: 'history_scan',
      };
    }
  }

  // Default: first template
  return {
    templateId: templateIds[0],
    templateIndex: 0,
    templateCount: templateIds.length,
    selectionMethod: 'default_first',
  };
}

/**
 * Fetch routine templates with optional exercise detail.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {string[]} templateIds
 * @param {boolean} includeExercises - Include full exercise arrays (default false)
 * @returns {Promise<Array>}
 */
async function fetchTemplates(db, userId, templateIds, includeExercises = false) {
  if (!templateIds || templateIds.length === 0) return [];

  const templateDocs = await Promise.all(
    templateIds.map(tid =>
      db.collection('users').doc(userId).collection('templates').doc(tid).get()
    )
  );

  return templateDocs
    .filter(doc => doc.exists)
    .map(doc => {
      const template = { id: doc.id, ...doc.data() };
      if (!includeExercises) {
        return {
          id: template.id,
          name: template.name,
          description: template.description,
          analytics: template.analytics,
          created_at: template.created_at,
          updated_at: template.updated_at,
          exerciseCount: template.exercises?.length || 0,
        };
      }
      return template;
    });
}

/**
 * Assemble full planning context for an agent.
 * Single function that gathers user profile, active routine, templates,
 * recent workouts, and strength summary.
 *
 * @param {FirebaseFirestore.Firestore} db - Firestore instance
 * @param {string} userId - Authenticated user ID
 * @param {Object} [options={}]
 * @param {boolean} [options.includeTemplates=true] - Include routine template metadata
 * @param {boolean} [options.includeTemplateExercises=false] - Include full exercise arrays
 * @param {boolean} [options.includeRecentWorkouts=true] - Include workout summary
 * @param {number} [options.workoutLimit=20] - Max workouts to return
 * @returns {Promise<Object>} Planning context object
 */
async function getPlanningContext(db, userId, options = {}) {
  const {
    includeTemplates = true,
    includeTemplateExercises = false,
    includeRecentWorkouts = true,
    workoutLimit = 20,
  } = options;

  const result = {
    user: null,
    activeRoutine: null,
    nextWorkout: null,
    templates: [],
    recentWorkoutsSummary: null,
    weight_unit: 'kg',
    strengthSummary: [],
  };

  // 1. User profile + attributes
  const userCtx = await fetchUserContext(db, userId);
  result.user = userCtx.profile;
  result.weight_unit = userCtx.weight_unit;

  // 2. Active routine
  if (userCtx.activeRoutineId) {
    const routineDoc = await db.collection('users').doc(userId)
      .collection('routines').doc(userCtx.activeRoutineId).get();

    if (routineDoc.exists) {
      const routine = { id: routineDoc.id, ...routineDoc.data() };
      // Normalize to template_ids (handle legacy templateIds field)
      routine.template_ids = routine.template_ids || routine.templateIds || [];
      result.activeRoutine = routine;

      // 3. Next workout
      result.nextWorkout = await resolveNextWorkout(db, userId, routine);

      // 4. Templates
      const templateIds = routine.template_ids;
      if (includeTemplates && templateIds.length > 0) {
        result.templates = await fetchTemplates(db, userId, templateIds, includeTemplateExercises);

        // Fetch full template for next workout when exercises aren't included globally
        if (!includeTemplateExercises && result.nextWorkout?.templateId) {
          const nextTemplateDoc = await db.collection('users').doc(userId)
            .collection('templates').doc(result.nextWorkout.templateId).get();
          if (nextTemplateDoc.exists) {
            result.nextWorkout.template = { id: nextTemplateDoc.id, ...nextTemplateDoc.data() };
          }
        }
      }
    }
  }

  // 5. Recent workouts
  if (includeRecentWorkouts) {
    result.recentWorkoutsSummary = await fetchRecentWorkouts(db, userId, workoutLimit);
  }

  // 6. Strength summary (derived from workout data, no extra reads)
  result.strengthSummary = buildStrengthSummary(result.recentWorkoutsSummary || []);

  return result;
}

module.exports = {
  getPlanningContext,
  fetchUserContext,
  fetchRecentWorkouts,
  fetchTemplates,
  resolveNextWorkout,
  buildStrengthSummary,
  sanitizeUserProfile,
  SENSITIVE_USER_FIELDS,
};
