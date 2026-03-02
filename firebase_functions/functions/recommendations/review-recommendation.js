/**
 * =============================================================================
 * review-recommendation.js - Review Agent Recommendations Endpoint
 * =============================================================================
 *
 * PURPOSE:
 * Allow users to accept or reject pending agent recommendations.
 *
 * AUTH:
 * v2 onRequest with requireFlexibleAuth (Bearer lane).
 * userId derived from req.auth.uid only (never trust client-provided userId).
 *
 * ACTIONS:
 * - accept (template-scoped): Apply changes to template with freshness check, state → 'applied'
 * - accept (exercise-scoped): Acknowledge only (no template mutation), state → 'acknowledged'
 * - reject: Update state to 'rejected'
 *
 * PREMIUM GATE:
 * All operations require premium subscription via isPremiumUser().
 *
 * FIRESTORE WRITES:
 * - Updates: users/{uid}/agent_recommendations/{id}
 * - Updates: users/{uid}/templates/{id} (if accept action, template-scoped only)
 *
 * ERROR CODES:
 * - PREMIUM_REQUIRED (403) - User does not have premium access
 * - INVALID_STATE (409) - Recommendation not in 'pending_review' state
 * - STALE_RECOMMENDATION (409) - Target template has changed since recommendation
 * - INTERNAL_ERROR (500) - Apply failed
 *
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const logger = require('firebase-functions/logger');
const { ok, fail } = require('../utils/response');
const { isPremiumUser } = require('../utils/subscription-gate');
const {
  applyChangesToTarget,
  resolvePathValue,
} = require('../agents/apply-progression');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * reviewRecommendation
 *
 * Accept or reject a pending agent recommendation.
 *
 * Request:
 * {
 *   recommendationId: string,
 *   action: "accept" | "reject"
 * }
 *
 * Response (accept):
 * {
 *   success: true,
 *   data: {
 *     status: "applied",
 *     result: { template_id, changes_applied }
 *   }
 * }
 *
 * Response (reject):
 * {
 *   success: true,
 *   data: {
 *     status: "rejected"
 *   }
 * }
 */
const reviewRecommendation = onRequest(
  { cors: true, region: 'us-central1' },
  requireFlexibleAuth(async (req, res) => {
    const startTime = Date.now();

    try {
      // 1. Extract userId from auth token (NEVER trust client-provided userId)
      const userId = req.auth.uid;
      if (!userId) {
        logger.warn('[reviewRecommendation] Missing userId from auth');
        return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
      }

      // 2. Parse request
      const { recommendationId, action } = req.body;

      if (!recommendationId || typeof recommendationId !== 'string') {
        return fail(res, 'INVALID_ARGUMENT', 'recommendationId is required', null, 400);
      }

      if (!action || !['accept', 'reject'].includes(action)) {
        return fail(res, 'INVALID_ARGUMENT', 'action must be "accept" or "reject"', null, 400);
      }

      logger.info('[reviewRecommendation] Processing', { userId, recommendationId, action });

      // 3. Premium gate
      const isPremium = await isPremiumUser(userId);
      if (!isPremium) {
        logger.warn('[reviewRecommendation] Premium required', { userId });
        return fail(res, 'PREMIUM_REQUIRED', 'Premium subscription required', null, 403);
      }

      // 4. Read recommendation
      const recRef = db.doc(`users/${userId}/agent_recommendations/${recommendationId}`);
      const recSnap = await recRef.get();

      if (!recSnap.exists) {
        logger.warn('[reviewRecommendation] Recommendation not found', { userId, recommendationId });
        return fail(res, 'NOT_FOUND', 'Recommendation not found', null, 404);
      }

      const recommendation = recSnap.data();

      // 5. Validate state
      if (recommendation.state !== 'pending_review') {
        logger.warn('[reviewRecommendation] Invalid state', {
          userId,
          recommendationId,
          currentState: recommendation.state,
        });
        return fail(
          res,
          'INVALID_STATE',
          `Recommendation is not pending review (current state: ${recommendation.state})`,
          { currentState: recommendation.state },
          409
        );
      }

      // 6. Handle action
      if (action === 'reject') {
        return await handleReject(res, userId, recRef, recommendation);
      } else {
        return await handleAccept(res, userId, recRef, recommendation, startTime);
      }

    } catch (error) {
      logger.error('[reviewRecommendation] Unexpected error', {
        error: error.message,
        stack: error.stack,
      });
      return fail(res, 'INTERNAL_ERROR', error.message, null, 500);
    }
  })
);

/**
 * Handle reject action
 */
async function handleReject(res, userId, recRef, recommendation) {
  const { FieldValue } = admin.firestore;

  await recRef.update({
    state: 'rejected',
    state_history: FieldValue.arrayUnion({
      from: 'pending_review',
      to: 'rejected',
      at: new Date().toISOString(),
      by: 'user',
      note: 'User rejected recommendation',
    }),
  });

  logger.info('[reviewRecommendation] Recommendation rejected', {
    userId,
    recommendationId: recRef.id,
  });

  return ok(res, { status: 'rejected' });
}

/**
 * Handle accept action
 */
async function handleAccept(res, userId, recRef, recommendation, startTime) {
  const { FieldValue } = admin.firestore;

  // 1. Extract target info
  const scope = recommendation.scope;
  const target = recommendation.target || {};
  const changes = recommendation.recommendation?.changes || [];

  // Exercise-scoped recommendations: acknowledge only (no template to mutate)
  if (scope === 'exercise') {
    await recRef.update({
      state: 'acknowledged',
      applied_by: 'user',
      applied_at: FieldValue.serverTimestamp(),
      state_history: FieldValue.arrayUnion({
        from: 'pending_review',
        to: 'acknowledged',
        at: new Date().toISOString(),
        by: 'user',
        note: 'User acknowledged exercise-scoped recommendation',
      }),
    });

    const elapsed = Date.now() - startTime;
    logger.info('[reviewRecommendation] Exercise-scoped recommendation acknowledged', {
      userId,
      recommendationId: recRef.id,
      exerciseName: target.exercise_name,
      elapsedMs: elapsed,
    });

    return ok(res, { status: 'acknowledged' });
  }

  // Routine-scoped recommendations (e.g., muscle_balance): acknowledge only, no template mutation
  if (scope === 'routine') {
    await recRef.update({
      state: 'acknowledged',
      applied_by: 'user',
      applied_at: FieldValue.serverTimestamp(),
      state_history: FieldValue.arrayUnion({
        from: 'pending_review',
        to: 'acknowledged',
        at: new Date().toISOString(),
        by: 'user',
        note: 'User acknowledged routine-scoped recommendation',
      }),
    });

    const elapsed = Date.now() - startTime;
    logger.info('[reviewRecommendation] Routine-scoped recommendation acknowledged', {
      userId,
      recommendationId: recRef.id,
      muscleGroup: target.muscle_group,
      elapsedMs: elapsed,
    });

    return ok(res, { status: 'acknowledged' });
  }

  if (scope !== 'template' || !target.template_id) {
    logger.error('[reviewRecommendation] Invalid recommendation scope', {
      userId,
      scope,
      target,
    });
    return fail(
      res,
      'INVALID_RECOMMENDATION',
      'Unsupported recommendation scope',
      null,
      400
    );
  }

  const templateId = target.template_id;

  // 2. Freshness check: read current template and verify 'from' values
  const templateRef = db.doc(`users/${userId}/templates/${templateId}`);
  const templateSnap = await templateRef.get();

  if (!templateSnap.exists) {
    logger.warn('[reviewRecommendation] Template not found', { userId, templateId });
    return fail(res, 'NOT_FOUND', 'Target template not found', null, 404);
  }

  const currentTemplate = templateSnap.data();
  const staleness = checkStaleness(currentTemplate, changes);

  if (staleness.isStale) {
    logger.warn('[reviewRecommendation] Stale recommendation detected', {
      userId,
      recommendationId: recRef.id,
      staleness: staleness.details,
    });
    return fail(
      res,
      'STALE_RECOMMENDATION',
      'Recommendation is stale - template has changed since recommendation was created',
      staleness.details,
      409
    );
  }

  // 3. Apply changes
  let result;
  try {
    result = await applyChangesToTarget(db, userId, 'template', templateId, changes, { recommendation_id: recRef.id });

    logger.info('[reviewRecommendation] Changes applied', {
      userId,
      templateId,
      changeCount: changes.length,
    });
  } catch (applyError) {
    logger.error('[reviewRecommendation] Apply failed', {
      userId,
      templateId,
      error: applyError.message,
    });

    // Update recommendation to 'failed' state
    await recRef.update({
      state: 'failed',
      state_history: FieldValue.arrayUnion({
        from: 'pending_review',
        to: 'failed',
        at: new Date().toISOString(),
        by: 'system',
        note: `Apply failed: ${applyError.message}`,
      }),
    });

    return fail(res, 'INTERNAL_ERROR', `Failed to apply changes: ${applyError.message}`, null, 500);
  }

  // 4. Update recommendation to 'applied'
  await recRef.update({
    state: 'applied',
    applied_by: 'user',
    applied_at: FieldValue.serverTimestamp(),
    result,
    state_history: FieldValue.arrayUnion({
      from: 'pending_review',
      to: 'applied',
      at: new Date().toISOString(),
      by: 'user',
      note: 'User accepted recommendation',
    }),
  });

  const elapsed = Date.now() - startTime;

  logger.info('[reviewRecommendation] Recommendation accepted and applied', {
    userId,
    recommendationId: recRef.id,
    templateId,
    elapsedMs: elapsed,
  });

  return ok(res, {
    status: 'applied',
    result,
  });
}

/**
 * Check if recommendation is stale by comparing 'from' values with current template
 */
function checkStaleness(currentTemplate, changes) {
  const mismatches = [];

  for (const change of changes) {
    // New field being added — no baseline to check against
    if (change.from === null) continue;

    const currentValue = resolvePathValue(currentTemplate, change.path);

    // Compare current value with expected 'from' value
    if (currentValue !== change.from) {
      mismatches.push({
        path: change.path,
        expected: change.from,
        actual: currentValue,
      });
    }
  }

  return {
    isStale: mismatches.length > 0,
    details: mismatches.length > 0 ? { mismatches } : null,
  };
}

module.exports = { reviewRecommendation };
