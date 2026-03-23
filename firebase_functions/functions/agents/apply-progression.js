/**
 * =============================================================================
 * apply-progression.js - HTTP handler (thin wrapper)
 * =============================================================================
 *
 * Business logic lives in ../shared/progressions.js.
 * This file is responsible only for HTTP concerns: auth, request parsing,
 * status code mapping, and response formatting.
 *
 * CALLED BY:
 * - post_workout_analyst.py via apply_progression skill
 * - Potentially scheduled jobs
 */

const admin = require('firebase-admin');
const { onRequest } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const { withApiKey } = require('../auth/middleware');
const { applyProgression: applyProgressionCore } = require('../shared/progressions');
const { ValidationError, NotFoundError } = require('../shared/errors');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

async function applyProgressionHandler(req, res) {
  const startTime = Date.now();

  try {
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return res.status(401).json({ error: 'UNAUTHORIZED', message: 'Authentication required' });
    }

    const {
      targetType,
      targetId,
      changes,
      summary,
      rationale,
      trigger,
      triggerContext,
      autoApply = true,
    } = req.body;

    const db = admin.firestore();

    const result = await applyProgressionCore(db, userId, {
      targetType,
      targetId,
      changes,
      summary,
      rationale,
      trigger,
      triggerContext,
      autoApply,
    });

    logger.info('[applyProgression] Done', {
      recommendationId: result.recommendationId,
      state: result.state,
    });

    const elapsed = Date.now() - startTime;

    return res.json({
      success: true,
      ...result,
      elapsedMs: elapsed,
    });

  } catch (error) {
    if (error instanceof ValidationError) {
      logger.warn('[applyProgression] Validation failed', { message: error.message, details: error.details });
      return res.status(400).json({ error: 'INVALID_ARGUMENT', message: error.message, ...error.details });
    }
    if (error instanceof NotFoundError) {
      logger.warn('[applyProgression] Not found', { message: error.message });
      return res.status(404).json({ error: 'NOT_FOUND', message: error.message });
    }
    logger.error('[applyProgression] Unexpected error', { error: error.message, stack: error.stack });
    return res.status(500).json({ error: 'INTERNAL', message: 'Internal error' });
  }
}

// Export handler — API key required (called by agent system only)
const applyProgression = onRequest({
  region: 'us-central1',
}, withApiKey(applyProgressionHandler));

module.exports = {
  applyProgression,
  applyProgressionHandler,
};
