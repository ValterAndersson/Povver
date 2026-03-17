/**
 * =============================================================================
 * process-recommendations.js - Recommendation Processing Triggers (v2: multi-lever)
 * =============================================================================
 *
 * PURPOSE:
 * Process training analysis insights and weekly reviews into actionable
 * recommendations, with optional auto-pilot execution.
 *
 * Two scopes:
 * - Template-scoped (user has activeRoutineId): matches exercises to template sets,
 *   supports auto-pilot auto-apply.
 * - Exercise-scoped (no routine): derives baseline from workout data, always pending_review.
 *
 * TRIGGERS:
 * 1. onAnalysisInsightCreated - Firestore trigger on users/{userId}/analysis_insights/{insightId}
 * 2. onWeeklyReviewCreated - Firestore trigger on users/{userId}/weekly_reviews/{reviewId}
 * 3. expireStaleRecommendations - Scheduled function (daily) to expire old pending recommendations
 *
 * DATA FLOW:
 * Analysis Insight/Weekly Review → Filter actionable recommendations →
 * Check premium → Branch on activeRoutineId →
 *   Template path: Match exercises to templates → Compute changes → Create rec → Auto-apply if enabled
 *   Exercise path: Load workout data → Compute progression from max weight → Create rec (pending_review)
 *
 * FIRESTORE WRITES:
 * - Creates: users/{uid}/agent_recommendations/{id}
 * - Updates: users/{uid}/templates/{id} (if auto-pilot enabled)
 *
 * =============================================================================
 */

const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const admin = require('firebase-admin');
const logger = require('firebase-functions/logger');
const { applyChangesToTarget } = require('../shared/progressions');

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

/**
 * Firestore trigger on analysis insights.
 * Fires when post-workout analysis creates a new insight document.
 */
const onAnalysisInsightCreated = onDocumentCreated(
  {
    document: 'users/{userId}/analysis_insights/{insightId}',
    region: 'us-central1',
  },
  async (event) => {
    const userId = event.params.userId;
    const insightId = event.params.insightId;
    const insight = event.data.data();

    logger.info('[onAnalysisInsightCreated] Processing insight', { userId, insightId });

    try {
      // Extract actionable recommendations from insight
      const recommendations = insight.recommendations || [];
      const actionable = recommendations
        .filter(rec => {
          if (rec.confidence < 0.7) return false;
          if (!['progression', 'deload', 'volume_adjust', 'rep_progression', 'swap'].includes(rec.type)) return false;
          // Input validation: clamp LLM-provided fields to valid ranges
          if (rec.target_reps != null && (rec.target_reps < 1 || rec.target_reps > 30)) return false;
          if (rec.target_rir != null && (rec.target_rir < 0 || rec.target_rir > 5)) return false;
          return true;
        })
        .map(rec => ({
          type: rec.type,
          target: rec.target,
          suggestedWeight: rec.suggested_weight ?? null,
          targetReps: rec.target_reps ?? null,
          targetRir: rec.target_rir ?? null,
          rationale: rec.action || 'Auto-generated from post-workout analysis',
          reasoning: rec.reasoning || '',
          signals: rec.signals || [],
          confidence: rec.confidence,
        }));

      if (actionable.length === 0) {
        logger.info('[onAnalysisInsightCreated] No actionable recommendations', { userId, insightId });
        return;
      }

      const exerciseScoped = actionable.filter(rec =>
        !isMuscleOrRoutineTarget(rec.target)
      );
      const nonExerciseScoped = actionable.filter(rec =>
        isMuscleOrRoutineTarget(rec.target)
      );

      if (exerciseScoped.length > 0) {
        await processActionableRecommendations(userId, 'post_workout', {
          insight_id: insightId,
          workout_id: insight.workout_id,
          workout_date: insight.workout_date,
        }, exerciseScoped);
      }

      if (nonExerciseScoped.length > 0) {
        await writeNonExerciseRecommendations(userId, 'post_workout', {
          insight_id: insightId,
          workout_id: insight.workout_id,
          workout_date: insight.workout_date,
        }, nonExerciseScoped);
      }
    } catch (error) {
      logger.error('[onAnalysisInsightCreated] Error processing insight', {
        userId,
        insightId,
        error: error.message,
        stack: error.stack,
      });
      // Don't throw - trigger should not retry on non-transient errors
    }
  }
);

/**
 * Firestore trigger on weekly reviews.
 * Fires when weekly review analysis creates a new review document.
 */
const onWeeklyReviewCreated = onDocumentCreated(
  {
    document: 'users/{userId}/weekly_reviews/{reviewId}',
    region: 'us-central1',
  },
  async (event) => {
    const userId = event.params.userId;
    const reviewId = event.params.reviewId;
    const review = event.data.data();

    logger.info('[onWeeklyReviewCreated] Processing review', { userId, reviewId });

    try {
      // Extract actionable items: progressions + all stalled exercise actions
      const progressionCandidates = review.progression_candidates || [];
      const stalledExercises = review.stalled_exercises || [];

      // Map stalled exercise actions to recommendation types
      const stalledActionMap = {
        increase_weight: 'progression',
        deload: 'deload',
        swap: 'exercise_swap',
        vary_rep_range: 'rep_progression',
      };

      const actionable = [
        ...progressionCandidates.map(pc => ({
          type: pc.target_reps ? 'rep_progression' : 'progression',
          target: pc.exercise_name,
          suggestedWeight: pc.suggested_weight ?? null,
          targetReps: pc.target_reps ?? null,
          targetRir: null,
          rationale: pc.rationale || 'Auto-generated from weekly review',
          reasoning: pc.reasoning || '',
          signals: pc.signals || [],
          confidence: pc.confidence || 0.8,
        })),
        ...stalledExercises.map(se => ({
          type: stalledActionMap[se.suggested_action] || se.suggested_action,
          target: se.exercise_name,
          suggestedWeight: se.suggested_weight ?? null,
          targetReps: se.target_reps ?? null,
          targetRir: null,
          rationale: se.rationale || `Stall detected — ${se.suggested_action} recommended`,
          reasoning: se.reasoning || '',
          signals: se.signals || [],
          confidence: 0.7,
        })),
      ];

      if (actionable.length === 0) {
        logger.info('[onWeeklyReviewCreated] No actionable recommendations', { userId, reviewId });
        return;
      }

      await processActionableRecommendations(userId, 'weekly_review', {
        review_id: reviewId,
        week_ending: review.week_ending || null,
      }, actionable);

      // Muscle balance recommendations — routine-scoped, written directly (bypass template/exercise matching)
      const muscleBalance = (review.muscle_balance || [])
        .filter(mb => mb.status === 'overtrained' || mb.status === 'undertrained');

      if (muscleBalance.length > 0) {
        const db = admin.firestore();
        const userDoc = await db.collection('users').doc(userId).get();
        const activeRoutineId = userDoc.exists ? (userDoc.data().activeRoutineId || null) : null;
        const isPremium = userDoc.exists && (
          userDoc.data().subscription_override === 'premium' || userDoc.data().subscription_tier === 'premium'
        );

        if (isPremium) {
          const { FieldValue } = admin.firestore;
          for (const mb of muscleBalance) {
            const recRef = db.collection(`users/${userId}/agent_recommendations`).doc();
            const now = FieldValue.serverTimestamp();

            const recData = {
              id: recRef.id,
              created_at: now,
              trigger: 'weekly_review',
              trigger_context: { review_id: reviewId, week_ending: review.week_ending || null },
              scope: 'routine',
              target: {
                routine_id: activeRoutineId,
                muscle_group: mb.muscle_group,
              },
              recommendation: {
                type: 'muscle_balance',
                changes: [],
                summary: `${mb.muscle_group}: ${mb.status} (${mb.weekly_sets ?? '?'} sets/week)`,
                rationale: `${mb.muscle_group} is ${mb.status} at ${mb.weekly_sets ?? '?'} sets/week (trend: ${mb.trend ?? 'unknown'}). ${mb.status === 'overtrained' ? 'Consider reducing volume to 10-20 sets/week.' : 'Consider increasing volume to at least 10 sets/week.'}`,
                confidence: 0.6,
                signals: [`${mb.weekly_sets} sets/week`, `trend: ${mb.trend}`, `status: ${mb.status}`],
              },
              state: 'pending_review',
              state_history: [{
                from: null,
                to: 'pending_review',
                at: new Date().toISOString(),
                by: 'agent',
                note: 'Muscle balance recommendation from weekly review',
              }],
              applied_by: null,
            };

            await recRef.set(recData);
            logger.info('[onWeeklyReviewCreated] Created muscle_balance recommendation', {
              userId,
              muscleGroup: mb.muscle_group,
              status: mb.status,
              recommendationId: recRef.id,
            });
          }
        }
      }
    } catch (error) {
      logger.error('[onWeeklyReviewCreated] Error processing review', {
        userId,
        reviewId,
        error: error.message,
        stack: error.stack,
      });
    }
  }
);

/**
 * Scheduled function to expire stale pending recommendations.
 * Runs daily to mark recommendations older than 7 days as expired.
 */
const expireStaleRecommendations = onSchedule(
  {
    schedule: 'every day 00:00',
    timeZone: 'UTC',
    region: 'us-central1',
  },
  async () => {
    logger.info('[expireStaleRecommendations] Starting sweep');

    try {
      const db = admin.firestore();
      const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

      const querySnapshot = await db.collectionGroup('agent_recommendations')
        .where('state', '==', 'pending_review')
        .where('created_at', '<', admin.firestore.Timestamp.fromDate(sevenDaysAgo))
        .get();

      if (querySnapshot.empty) {
        logger.info('[expireStaleRecommendations] No stale recommendations found');
        return;
      }

      // Firestore batch limit is 500 — chunk if needed
      const docs = querySnapshot.docs;
      const BATCH_LIMIT = 500;
      let expiredCount = 0;

      for (let i = 0; i < docs.length; i += BATCH_LIMIT) {
        const chunk = docs.slice(i, i + BATCH_LIMIT);
        const batch = db.batch();

        for (const doc of chunk) {
          batch.update(doc.ref, {
            state: 'expired',
            state_history: admin.firestore.FieldValue.arrayUnion({
              from: 'pending_review',
              to: 'expired',
              at: new Date().toISOString(),
              by: 'system',
              note: 'TTL expired (7 days)',
            }),
          });
          expiredCount++;
        }

        await batch.commit();
      }

      logger.info('[expireStaleRecommendations] Sweep complete', { expiredCount });
    } catch (error) {
      logger.error('[expireStaleRecommendations] Error during sweep', {
        error: error.message,
        stack: error.stack,
      });
    }
  }
);

// ---------------------------------------------------------------------------
// Shared processing logic
// ---------------------------------------------------------------------------

/**
 * Core recommendation processing shared by both triggers.
 * Reads user prefs, resolves exercises against active routine templates,
 * deduplicates against existing pending recs, and creates new recommendations.
 *
 * @param {string} userId
 * @param {string} triggerType - 'post_workout' | 'weekly_review'
 * @param {Object} triggerContext - Trigger-specific context (insight_id, review_id, etc.)
 * @param {Array} actionable - Normalized actionable items: [{ type, target, suggestedWeight, rationale, confidence }]
 */
async function processActionableRecommendations(userId, triggerType, triggerContext, actionable) {
  const db = admin.firestore();

  // 1. Read user doc once — premium gate + auto_pilot + activeRoutineId
  const userDoc = await db.collection('users').doc(userId).get();
  if (!userDoc.exists) {
    logger.warn(`[processRecommendations] User not found`, { userId });
    return;
  }

  const userData = userDoc.data();

  // Premium gate: check override first, then tier (mirrors isPremiumUser logic)
  const isPremium = userData.subscription_override === 'premium' || userData.subscription_tier === 'premium';
  if (!isPremium) {
    logger.info(`[processRecommendations] Skipping — not premium`, { userId });
    return;
  }

  const autoPilotEnabled = userData.auto_pilot_enabled || false;
  const activeRoutineId = userData.activeRoutineId;

  if (activeRoutineId) {
    await processTemplateScopedRecommendations(db, userId, triggerType, triggerContext, actionable, autoPilotEnabled, activeRoutineId);
  } else {
    await processExerciseScopedRecommendations(db, userId, triggerType, triggerContext, actionable);
  }
}

/**
 * Template-scoped recommendations: user has an active routine with templates.
 * Matches exercises against template sets and creates template-targeted changes.
 * Supports auto-pilot (auto-apply to templates).
 */
async function processTemplateScopedRecommendations(db, userId, triggerType, triggerContext, actionable, autoPilotEnabled, activeRoutineId) {
  // 1. Get routine and templates
  const routineDoc = await db.doc(`users/${userId}/routines/${activeRoutineId}`).get();
  if (!routineDoc.exists) {
    logger.warn(`[processRecommendations] Active routine not found`, { userId, activeRoutineId });
    return;
  }

  const templateIds = routineDoc.data().template_ids || [];
  if (templateIds.length === 0) {
    logger.info(`[processRecommendations] Routine has no templates`, { userId, activeRoutineId });
    return;
  }

  // 2. Load all templates in parallel and build exercise index
  const templateSnaps = await Promise.all(
    templateIds.map(tid => db.doc(`users/${userId}/templates/${tid}`).get())
  );

  // Template exercises store exercise_id (reference) but not name.
  // Resolve exercise_id → name via series_exercises (1 doc per exercise,
  // doc ID = exercise_id), with set_facts fallback for any gaps.
  const allExerciseIds = new Set();
  for (const snap of templateSnaps) {
    if (!snap.exists) continue;
    for (const ex of (snap.data().exercises || [])) {
      if (ex.exercise_id) allExerciseIds.add(ex.exercise_id);
    }
  }

  const exerciseNameMap = {}; // { exercise_id: name }
  if (allExerciseIds.size > 0) {
    try {
      // Primary: series_exercises (1 doc per exercise_id, fast batch read)
      const seriesRefs = [...allExerciseIds].map(id =>
        db.doc(`users/${userId}/series_exercises/${id}`)
      );
      const seriesDocs = await db.getAll(...seriesRefs);
      for (const doc of seriesDocs) {
        if (doc.exists) {
          const name = (doc.data().exercise_name || '').trim();
          // Skip if exercise_name is the ID itself (stale entry)
          if (name && name !== doc.id) {
            exerciseNameMap[doc.id] = name;
          }
        }
      }

      // Fallback: set_facts for any unresolved exercise_ids
      const unresolved = [...allExerciseIds].filter(id => !exerciseNameMap[id]);
      if (unresolved.length > 0) {
        for (let i = 0; i < unresolved.length; i += 30) {
          const chunk = unresolved.slice(i, i + 30);
          const sfSnap = await db.collection(`users/${userId}/set_facts`)
            .where('exercise_id', 'in', chunk)
            .limit(chunk.length * 10)
            .get();
          sfSnap.forEach(doc => {
            const d = doc.data();
            if (d.exercise_id && d.exercise_name && !exerciseNameMap[d.exercise_id]) {
              exerciseNameMap[d.exercise_id] = d.exercise_name.trim();
            }
          });
        }
      }

      logger.info('[processRecommendations] Resolved exercise names', {
        userId, resolved: Object.keys(exerciseNameMap).length, total: allExerciseIds.size,
      });
    } catch (err) {
      logger.warn('[processRecommendations] Failed to resolve exercise names', { error: err.message });
    }
  }

  // { exercise_name_lower: { templateId, exerciseIndex, exerciseName, sets } }
  const exerciseIndex = {};
  for (const snap of templateSnaps) {
    if (!snap.exists) continue;
    const exercises = snap.data().exercises || [];
    exercises.forEach((ex, idx) => {
      const name = exerciseNameMap[ex.exercise_id] || '';
      const key = name.toLowerCase();
      if (key) {
        exerciseIndex[key] = {
          templateId: snap.id,
          exerciseIndex: idx,
          exerciseName: name,
          sets: ex.sets || [],
        };
      }
    });
  }

  // 3. Get existing pending recommendations for deduplication
  const pendingSnap = await db.collection(`users/${userId}/agent_recommendations`)
    .where('state', '==', 'pending_review')
    .get();

  const pendingExercises = new Set();
  pendingSnap.forEach(doc => {
    const rec = doc.data();
    const changes = rec.recommendation?.changes || [];
    for (const change of changes) {
      const match = change.path.match(/exercises\[(\d+)\]/);
      if (match && rec.target?.template_id) {
        pendingExercises.add(`${rec.target.template_id}:${match[1]}`);
      }
    }
  });

  // 4. Process each actionable recommendation
  const { FieldValue } = admin.firestore;
  let processedCount = 0;

  for (const rec of actionable) {
    const exerciseName = rec.target || '';
    const key = exerciseName.trim().toLowerCase();

    const exerciseData = exerciseIndex[key];
    if (!exerciseData) {
      logger.info(`[processRecommendations] Exercise not found in templates`, { exerciseName, userId });
      continue;
    }

    // Look up template name
    const templateSnap = templateSnaps.find(s => s.exists && s.id === exerciseData.templateId);
    const templateName = templateSnap ? (templateSnap.data().name || null) : null;

    // Deduplication check
    const pendingKey = `${exerciseData.templateId}:${exerciseData.exerciseIndex}`;
    if (pendingExercises.has(pendingKey)) {
      logger.info(`[processRecommendations] Skipping duplicate`, { exerciseName, templateId: exerciseData.templateId });
      continue;
    }

    // Swap recommendations: always pending_review (no auto-apply)
    if (rec.type === 'swap') {
      const recRef = db.collection(`users/${userId}/agent_recommendations`).doc();
      const now = FieldValue.serverTimestamp();

      const swapData = {
        id: recRef.id,
        created_at: now,
        trigger: triggerType,
        trigger_context: triggerContext,
        scope: 'template',
        target: {
          template_id: exerciseData.templateId,
          template_name: templateName || null,
          routine_id: activeRoutineId,
          exercise_index: exerciseData.exerciseIndex,
          exercise_name: exerciseData.exerciseName || exerciseName,
          current_exercise: exerciseName,
        },
        recommendation: {
          type: 'swap',
          changes: [],
          summary: `Consider swapping ${exerciseName} for a different exercise`,
          rationale: rec.reasoning || rec.rationale || '',
          confidence: rec.confidence,
          signals: rec.signals || [],
        },
        state: 'pending_review',
        state_history: [{
          from: null,
          to: 'pending_review',
          at: new Date().toISOString(),
          by: 'agent',
          note: 'Swap recommendation — requires user review',
        }],
        applied_by: null,
      };

      await recRef.set(swapData);
      pendingExercises.add(pendingKey);
      processedCount++;
      logger.info('[processRecommendations] Created swap recommendation', {
        recommendationId: recRef.id,
        exerciseName,
        templateId: exerciseData.templateId,
      });
      continue;
    }

    // Compute changes
    const changes = computeProgressionChanges(exerciseData, rec.type, rec);
    if (changes.length === 0) {
      logger.info(`[processRecommendations] No valid changes`, { exerciseName });
      continue;
    }

    // Create recommendation document
    const recRef = db.collection(`users/${userId}/agent_recommendations`).doc();
    const state = autoPilotEnabled ? 'applied' : 'pending_review';
    const now = FieldValue.serverTimestamp();

    // When auto-pilot applies, include a user-facing notification
    const notificationText = autoPilotEnabled
      ? `Auto-applied: ${buildSummary(rec, 'template', 'applied', changes, templateName)}`
      : null;

    const recommendationData = {
      id: recRef.id,
      created_at: now,
      trigger: triggerType,
      trigger_context: triggerContext,
      scope: 'template',
      target: {
        template_id: exerciseData.templateId,
        template_name: templateName || null,
        routine_id: activeRoutineId,
        exercise_name: exerciseData.exerciseName || exerciseName,
      },
      recommendation: {
        type: rec.type,
        changes,
        summary: buildSummary(rec, 'template', state, changes, templateName),
        rationale: buildRationale(rec, 'template', state, templateName),
        confidence: rec.confidence,
        signals: rec.signals || [],
      },
      state,
      state_history: [{
        from: null,
        to: state,
        at: new Date().toISOString(),
        by: 'agent',
        note: autoPilotEnabled ? 'Auto-applied' : 'Queued for review',
      }],
      applied_by: autoPilotEnabled ? 'agent' : null,
      user_notification: notificationText,
      notification_read: notificationText ? false : null,
    };

    // If auto-pilot, apply changes to template
    if (autoPilotEnabled) {
      try {
        const result = await applyChangesToTarget(db, userId, 'template', exerciseData.templateId, changes, { recommendation_id: recRef.id });
        recommendationData.applied_at = now;
        recommendationData.result = result;
        logger.info(`[processRecommendations] Auto-applied`, {
          templateId: exerciseData.templateId,
          exerciseName,
          changeCount: changes.length,
        });
      } catch (applyError) {
        logger.error(`[processRecommendations] Apply failed`, {
          error: applyError.message,
          templateId: exerciseData.templateId,
          exerciseName,
        });
        recommendationData.state = 'failed';
        recommendationData.state_history.push({
          from: 'applied',
          to: 'failed',
          at: new Date().toISOString(),
          by: 'system',
          note: `Apply failed: ${applyError.message}`,
        });
      }
    }

    await recRef.set(recommendationData);
    // Mark as pending so later iterations in this batch don't duplicate
    pendingExercises.add(pendingKey);
    processedCount++;

    logger.info(`[processRecommendations] Created`, {
      recommendationId: recRef.id,
      exerciseName,
      state: recommendationData.state,
    });
  }

  logger.info(`[processRecommendations] Complete`, {
    userId,
    trigger: triggerType,
    actionableCount: actionable.length,
    processedCount,
  });
}

/**
 * Exercise-scoped recommendations: user has no active routine.
 * Derives baseline weight from workout data instead of templates.
 * Always pending_review (can't auto-apply without a template target).
 */
async function processExerciseScopedRecommendations(db, userId, triggerType, triggerContext, actionable) {
  logger.info(`[processRecommendations] No active routine — using exercise-scoped path`, { userId });

  // 1. Build exercise index from workout data
  // For post_workout: use the triggering workout
  // For weekly_review: load recent workouts
  const exerciseIndex = {}; // { exercise_name_lower: { exerciseName, exerciseId, maxWeight } }

  if (triggerType === 'post_workout' && triggerContext.workout_id) {
    const workoutDoc = await db.doc(`users/${userId}/workouts/${triggerContext.workout_id}`).get();
    if (workoutDoc.exists) {
      buildExerciseIndexFromWorkout(workoutDoc.data(), exerciseIndex);
    }
  } else {
    // Weekly review or missing workout_id — load recent workouts (last 14 days)
    const twoWeeksAgo = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000);
    const recentSnap = await db.collection(`users/${userId}/workouts`)
      .where('end_time', '>=', admin.firestore.Timestamp.fromDate(twoWeeksAgo))
      .orderBy('end_time', 'desc')
      .limit(20)
      .get();

    recentSnap.forEach(doc => {
      buildExerciseIndexFromWorkout(doc.data(), exerciseIndex);
    });
  }

  if (Object.keys(exerciseIndex).length === 0) {
    logger.info(`[processRecommendations] No workout exercise data found`, { userId });
    return;
  }

  // 2. Get existing pending exercise-scoped recs for deduplication
  const pendingSnap = await db.collection(`users/${userId}/agent_recommendations`)
    .where('state', '==', 'pending_review')
    .where('scope', '==', 'exercise')
    .get();

  const pendingExercises = new Set();
  pendingSnap.forEach(doc => {
    const rec = doc.data();
    const name = (rec.target?.exercise_name || '').trim().toLowerCase();
    if (name) pendingExercises.add(name);
  });

  // 3. Process each actionable recommendation
  const { FieldValue } = admin.firestore;
  let processedCount = 0;

  for (const rec of actionable) {
    const exerciseName = rec.target || '';
    const key = exerciseName.trim().toLowerCase();

    const exerciseData = exerciseIndex[key];
    if (!exerciseData) {
      logger.info(`[processRecommendations] Exercise not found in workout data`, { exerciseName, userId });
      continue;
    }

    // Deduplication
    if (pendingExercises.has(key)) {
      logger.info(`[processRecommendations] Skipping duplicate exercise-scoped`, { exerciseName });
      continue;
    }

    // Compute changes based on recommendation type
    const changes = [];

    if (rec.type === 'progression' || rec.type === 'deload' || rec.type === 'volume_adjust') {
      // Weight changes from max working set weight
      const currentWeight = exerciseData.maxWeight;
      const newWeight = computeProgressionWeight(currentWeight, rec.type, rec.suggestedWeight);
      if (newWeight !== currentWeight && newWeight > 0) {
        changes.push({
          path: 'weight_kg',
          from: currentWeight,
          to: newWeight,
          rationale: `${rec.type}: ${currentWeight}kg → ${newWeight}kg`,
        });
      }
    } else if (rec.type === 'rep_progression' && rec.targetReps) {
      changes.push({
        path: 'target_reps',
        from: null,
        to: rec.targetReps,
        rationale: `rep_progression: → ${rec.targetReps} reps`,
      });
    }
    // intensity_adjust: removed — RIR is diagnostic, not prescriptive.
    // High RIR triggers weight progression in the LLM prompt instead.
    // muscle_balance: skip entirely (handled in onWeeklyReviewCreated)

    if (changes.length === 0) {
      logger.info(`[processRecommendations] No changes for exercise-scoped`, { exerciseName, type: rec.type });
      continue;
    }

    // Exercise-scoped recs are always pending_review (no template to auto-apply to)
    const recRef = db.collection(`users/${userId}/agent_recommendations`).doc();
    const now = FieldValue.serverTimestamp();

    const recommendationData = {
      id: recRef.id,
      created_at: now,
      trigger: triggerType,
      trigger_context: triggerContext,
      scope: 'exercise',
      target: {
        exercise_name: exerciseData.exerciseName,
        exercise_id: exerciseData.exerciseId || null,
      },
      recommendation: {
        type: rec.type,
        changes,
        summary: buildSummary(rec, 'exercise', 'pending_review', changes, null),
        rationale: buildRationale(rec, 'exercise', 'pending_review', null),
        confidence: rec.confidence,
        signals: rec.signals || [],
      },
      state: 'pending_review',
      state_history: [{
        from: null,
        to: 'pending_review',
        at: new Date().toISOString(),
        by: 'agent',
        note: 'Queued for review (exercise-scoped)',
      }],
      applied_by: null,
    };

    await recRef.set(recommendationData);
    pendingExercises.add(key);
    processedCount++;

    logger.info(`[processRecommendations] Created exercise-scoped`, {
      recommendationId: recRef.id,
      exerciseName: exerciseData.exerciseName,
    });
  }

  logger.info(`[processRecommendations] Complete (exercise-scoped)`, {
    userId,
    trigger: triggerType,
    actionableCount: actionable.length,
    processedCount,
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Build exercise index from a single workout document.
 * Extracts exercise names and max working set weight for exercise-scoped recommendations.
 *
 * @param {Object} workoutData - Workout document data
 * @param {Object} index - Mutable index to populate: { exercise_name_lower: { exerciseName, exerciseId, maxWeight } }
 */
function buildExerciseIndexFromWorkout(workoutData, index) {
  const exercises = workoutData.exercises || [];
  for (const ex of exercises) {
    const name = (ex.name || '').trim();
    const key = name.toLowerCase();
    if (!key) continue;

    // Find max working set weight from completed sets
    const sets = ex.sets || [];
    let maxWeight = 0;
    for (const set of sets) {
      const w = set.weight_kg || set.weight || 0;
      if (w > maxWeight) maxWeight = w;
    }

    // Keep the highest weight seen across workouts
    if (!index[key] || maxWeight > index[key].maxWeight) {
      index[key] = {
        exerciseName: name,
        exerciseId: ex.exercise_id || ex.id || null,
        maxWeight,
      };
    }
  }
}

/**
 * Compute a single progression weight value.
 * Shared rules for both template-scoped and exercise-scoped paths.
 *
 * @param {number} currentWeight - Current weight in kg
 * @param {string} recommendationType - 'progression' | 'deload' | 'volume_adjust'
 * @param {number|null} suggestedWeight - Explicit suggestion (optional)
 * @returns {number} New weight in kg
 */
function computeProgressionWeight(currentWeight, recommendationType, suggestedWeight) {
  if (suggestedWeight !== null && suggestedWeight !== undefined) {
    return suggestedWeight;
  }
  if (recommendationType === 'deload') {
    return roundToNearest(currentWeight * 0.9, currentWeight > 40 ? 2.5 : 1.25);
  }
  const increment = currentWeight > 40 ? 0.025 : 0.05;
  const step = currentWeight > 40 ? 2.5 : 1.25;
  let newWeight = roundToNearest(currentWeight * (1 + increment), step);
  // If rounding killed the increment, bump by one step
  if (newWeight <= currentWeight) newWeight = currentWeight + step;
  newWeight = Math.min(newWeight, currentWeight + 5);
  return newWeight > 0 ? newWeight : 0;
}

/**
 * Build contextual summary based on scope, state, and change data.
 * Classifies changes by path suffix and builds multi-type summaries.
 *
 * @param {Object} rec - The recommendation { type, target, ... }
 * @param {string} scope - 'template' | 'exercise' | 'routine'
 * @param {string} state - 'applied' | 'pending_review'
 * @param {Array|null} changes - Array of change objects (or null for muscle_balance)
 * @param {string|null} templateName - Human-readable template name
 * @returns {string} Contextual summary
 */
function buildSummary(rec, scope, state, changes, templateName) {
  const name = rec.target || '';

  // Guard for empty/null changes — use type-specific fallback summaries
  if (!changes || changes.length === 0) {
    if (rec.type === 'rep_progression' && rec.targetReps) {
      return `Build ${name} to ${rec.targetReps} reps before adding weight`;
    }
    if (rec.type === 'deload' && rec.suggestedWeight) {
      return `Consider reducing ${name} to ${rec.suggestedWeight}kg`;
    }
    if (rec.type === 'muscle_balance') {
      return `${name}: ${rec.type}`;
    }
    return `${rec.type} for ${name}`;
  }

  // Classify changes by path suffix and build summary parts
  const parts = [];
  let firstWeight = null;
  let firstReps = null;
  let firstRir = null;

  for (const change of changes) {
    if (change.path.includes('weight_kg') && !firstWeight) {
      firstWeight = change;
    } else if ((change.path.includes('target_reps') || change.path.endsWith('.reps')) && !firstReps) {
      firstReps = change;
    } else if ((change.path.includes('target_rir') || change.path.endsWith('.rir')) && !firstRir) {
      firstRir = change;
    }
  }

  if (firstReps) {
    const fromStr = firstReps.from != null ? `${firstReps.from}` : '';
    parts.push(fromStr ? `${fromStr} → ${firstReps.to} reps` : `→ ${firstReps.to} reps`);
  }
  if (firstWeight) {
    parts.push(`${firstWeight.from}kg → ${firstWeight.to}kg`);
  }
  if (firstRir) {
    const fromStr = firstRir.from != null ? `${firstRir.from}` : '';
    parts.push(fromStr ? `RIR ${fromStr} → ${firstRir.to}` : `RIR → ${firstRir.to}`);
  }

  const changeSummary = parts.join(', ');

  if (scope === 'template' && state === 'applied') {
    return changeSummary ? `Applied: ${name} ${changeSummary}` : `Applied ${rec.type} for ${name}`;
  }
  if (scope === 'template' && state === 'pending_review') {
    if (rec.type === 'rep_progression' && firstReps) {
      return `Build ${name} to ${firstReps.to} reps`;
    }
    return changeSummary ? `${name}: ${changeSummary}` : `${rec.type} for ${name}`;
  }
  if (scope === 'exercise') {
    if (rec.type === 'rep_progression' && firstReps) {
      return `Build ${name} to ${firstReps.to} reps`;
    }
    if (firstWeight) {
      return `Ready to progress ${name} to ${firstWeight.to}kg`;
    }
    return changeSummary ? `${name}: ${changeSummary}` : `${rec.type} for ${name}`;
  }
  return changeSummary ? `${name}: ${changeSummary}` : `${rec.type} for ${name}`;
}

/**
 * Build contextual rationale from analyzer reasoning and signals.
 *
 * @param {Object} rec - The recommendation { reasoning, signals, rationale, ... }
 * @param {string} scope - 'template' | 'exercise' | 'routine'
 * @param {string} state - 'applied' | 'pending_review'
 * @param {string|null} templateName - Human-readable template name
 * @returns {string} Contextual rationale
 */
function buildRationale(rec, scope, state, templateName) {
  const reasoning = rec.reasoning || rec.rationale || '';
  const signals = (rec.signals || []).join('. ');

  if (!reasoning && !signals) return '';

  if (scope === 'template' && state === 'applied') {
    return `${reasoning}${templateName ? ` Updated in ${templateName}.` : ''}`;
  }
  if (scope === 'template' && state === 'pending_review') {
    const prefix = signals ? `${signals}. ` : '';
    const suffix = templateName ? ` Accepting updates ${templateName}.` : '';
    return `${prefix}${reasoning}${suffix}`;
  }
  if (scope === 'exercise') {
    const prefix = signals ? `${signals}. ` : '';
    return `${prefix}${reasoning} Use this in your next workout or add it to a template.`;
  }
  if (scope === 'routine') {
    return reasoning;
  }
  return reasoning;
}

/**
 * Compute progression changes for an exercise — supports weight, reps, and RIR mutations.
 *
 * Change types by path:
 * - weight_kg: Weight progression/deload (existing logic via computeProgressionWeight)
 * - target_reps: Rep progression (double progression model — increase reps before weight)
 *
 * @param {Object} exerciseData - { templateId, exerciseIndex, sets }
 * @param {string} recommendationType - 'progression' | 'deload' | 'volume_adjust' | 'rep_progression'
 * @param {Object} recommendation - Full recommendation object { suggestedWeight, targetReps, targetRir, ... }
 * @returns {Array} Array of change objects { path, from, to, rationale }
 */
function computeProgressionChanges(exerciseData, recommendationType, recommendation) {
  const changes = [];
  const sets = exerciseData.sets || [];

  // Extract fields from recommendation — support both object and legacy scalar forms
  const suggestedWeight = (typeof recommendation === 'object' && recommendation !== null)
    ? (recommendation.suggestedWeight ?? null)
    : (recommendation ?? null);  // Legacy: recommendation was suggestedWeight directly
  const targetReps = (typeof recommendation === 'object' && recommendation !== null)
    ? (recommendation.targetReps ?? null)
    : null;
  const targetRir = (typeof recommendation === 'object' && recommendation !== null)
    ? (recommendation.targetRir ?? null)
    : null;

  for (let setIdx = 0; setIdx < sets.length; setIdx++) {
    const set = sets[setIdx];

    // Skip warmup sets — only modify working sets
    if (set.type === 'warmup') continue;

    // Weight changes (progression, deload, volume_adjust)
    // Templates use `weight` (not `weight_kg`) as the prescription field
    if (recommendationType === 'progression' || recommendationType === 'deload' || recommendationType === 'volume_adjust' || suggestedWeight !== null) {
      const currentWeight = set.weight || set.weight_kg || 0;
      let newWeight;

      if (suggestedWeight !== null && suggestedWeight !== undefined) {
        newWeight = suggestedWeight;
      } else if (recommendationType === 'deload') {
        newWeight = roundToNearest(currentWeight * 0.9, currentWeight > 40 ? 2.5 : 1.25);
      } else if (recommendationType === 'progression' || recommendationType === 'volume_adjust') {
        const increment = currentWeight > 40 ? 0.025 : 0.05;
        const step = currentWeight > 40 ? 2.5 : 1.25;
        newWeight = roundToNearest(currentWeight * (1 + increment), step);
        if (newWeight <= currentWeight) newWeight = currentWeight + step;
        newWeight = Math.min(newWeight, currentWeight + 5);
      }

      if (newWeight !== undefined && newWeight !== currentWeight && newWeight > 0) {
        changes.push({
          path: `exercises[${exerciseData.exerciseIndex}].sets[${setIdx}].weight`,
          from: currentWeight,
          to: newWeight,
          rationale: `${recommendationType}: ${currentWeight}kg → ${newWeight}kg`,
        });
      }
    }

    // Rep changes (rep_progression)
    // Templates use `reps` (not `target_reps`) as the prescription field
    if (targetReps !== null && targetReps > 0) {
      const currentReps = set.reps ?? set.target_reps ?? null;
      if (currentReps !== targetReps) {
        changes.push({
          path: `exercises[${exerciseData.exerciseIndex}].sets[${setIdx}].reps`,
          from: currentReps,
          to: targetReps,
          rationale: `rep_progression: ${currentReps ?? '?'} → ${targetReps} reps`,
        });
      }
    }

    // RIR is diagnostic, not prescriptive — no template mutations for RIR.
    // High RIR triggers weight progression instead (handled by LLM prompt).
  }

  return changes;
}

/**
 * Round value to nearest step.
 */
function roundToNearest(value, step) {
  return Math.round(value / step) * step;
}

/**
 * Detect if a recommendation target is a muscle group or routine-level name.
 */
const MUSCLE_GROUP_NAMES = new Set([
  'chest', 'back', 'shoulders', 'legs', 'arms', 'core', 'glutes',
  'biceps', 'triceps', 'quads', 'hamstrings', 'calves', 'abs',
  'forearms', 'traps', 'lats', 'rear delts', 'front delts', 'side delts',
]);

function isMuscleOrRoutineTarget(target) {
  if (!target) return false;
  const lower = target.trim().toLowerCase();
  if (MUSCLE_GROUP_NAMES.has(lower)) return true;
  if (lower.includes('weekly') || lower.includes('routine') || lower.includes('training')) return true;
  return false;
}

/**
 * Write muscle-group or routine-level recommendations directly.
 * These bypass exercise-template matching (no specific exercise to match).
 * Always pending_review — informational only.
 */
async function writeNonExerciseRecommendations(userId, triggerType, triggerContext, recommendations) {
  const db = admin.firestore();
  const { FieldValue } = admin.firestore;

  const userDoc = await db.collection('users').doc(userId).get();
  if (!userDoc.exists) return;
  const userData = userDoc.data();
  const isPremium = userData.subscription_override === 'premium' || userData.subscription_tier === 'premium';
  if (!isPremium) return;

  const activeRoutineId = userData.activeRoutineId || null;

  // Deduplication: query existing pending non-exercise recs
  const pendingSnap = await db.collection(`users/${userId}/agent_recommendations`)
    .where('state', '==', 'pending_review')
    .get();

  // Build dedup set: "scope:type:target_key"
  const pendingKeys = new Set();
  pendingSnap.forEach(doc => {
    const d = doc.data();
    const scope = d.scope || '';
    const type = d.recommendation?.type || '';
    const targetKey = scope === 'muscle_group'
      ? (d.target?.muscle_group || '').trim().toLowerCase()
      : (d.target?.description || '').trim().toLowerCase();
    if (scope && type) {
      pendingKeys.add(`${scope}:${type}:${targetKey}`);
    }
  });

  let createdCount = 0;

  for (const rec of recommendations) {
    const isMuscle = MUSCLE_GROUP_NAMES.has((rec.target || '').trim().toLowerCase());
    const scope = isMuscle ? 'muscle_group' : 'routine';
    const targetKey = (rec.target || '').trim().toLowerCase();
    const dedupKey = `${scope}:${rec.type}:${targetKey}`;

    if (pendingKeys.has(dedupKey)) {
      logger.info('[processRecommendations] Skipping duplicate non-exercise', {
        userId, target: rec.target, type: rec.type, scope,
      });
      continue;
    }

    const recRef = db.collection(`users/${userId}/agent_recommendations`).doc();
    const now = FieldValue.serverTimestamp();

    const recData = {
      id: recRef.id,
      created_at: now,
      trigger: triggerType,
      trigger_context: triggerContext,
      scope,
      target: {
        routine_id: activeRoutineId,
        ...(isMuscle ? { muscle_group: rec.target } : { description: rec.target }),
      },
      recommendation: {
        type: rec.type,
        changes: [],
        summary: rec.rationale || `${rec.type} for ${rec.target}`,
        rationale: rec.reasoning || '',
        confidence: rec.confidence,
        signals: rec.signals || [],
      },
      state: 'pending_review',
      state_history: [{
        from: null,
        to: 'pending_review',
        at: new Date().toISOString(),
        by: 'agent',
        note: `${isMuscle ? 'Muscle-group' : 'Routine-level'} recommendation from ${triggerType}`,
      }],
      applied_by: null,
    };

    await recRef.set(recData);
    pendingKeys.add(dedupKey);
    createdCount++;
    logger.info('[processRecommendations] Created non-exercise recommendation', {
      userId,
      target: rec.target,
      scope,
      recommendationId: recRef.id,
    });
  }

  if (createdCount < recommendations.length) {
    logger.info('[processRecommendations] Non-exercise dedup summary', {
      userId, total: recommendations.length, created: createdCount,
      skipped: recommendations.length - createdCount,
    });
  }
}

module.exports = {
  onAnalysisInsightCreated,
  onWeeklyReviewCreated,
  expireStaleRecommendations,
  // Exported for testing
  buildSummary,
  buildRationale,
  computeProgressionChanges,
  computeProgressionWeight,
  roundToNearest,
  isMuscleOrRoutineTarget,
  writeNonExerciseRecommendations,
};
