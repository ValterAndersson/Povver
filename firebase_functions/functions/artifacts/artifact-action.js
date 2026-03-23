/**
 * artifact-action.js - HTTP wrapper for artifact lifecycle actions.
 *
 * Thin wrapper: auth + input extraction + delegation to shared/artifacts.js.
 * All business logic lives in the shared module for reuse by other callers.
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { executeArtifactAction } = require('../shared/artifacts');
const { writeLimiter } = require('../utils/rate-limiter');
const { fail } = require('../utils/response');

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();

async function artifactActionHandler(req, res) {
  // Secure userId derivation — prevents IDOR via auth-helpers
  const userId = getAuthenticatedUserId(req);

  if (!writeLimiter.check(userId)) {
    return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
  }

  const conversationId = req.body?.conversationId;
  const artifactId = req.body?.artifactId;
  const action = req.body?.action;
  const day = req.body?.day;

  try {
    const result = await executeArtifactAction(db, userId, conversationId, artifactId, action, { day });

    logger.info('[artifactAction] complete', { action, artifactId, userId });
    return res.status(200).json({ success: true, ...result });
  } catch (error) {
    const httpStatus = error.httpStatus || error.http || 500;
    if (httpStatus >= 500) {
      logger.error('[artifactAction] Error', { error: error.message, action, artifactId });
      return res.status(httpStatus).json({
        success: false,
        error: 'Internal error',
      });
    }
    // Keep error.message for 4xx errors (user-facing validation errors)
    return res.status(httpStatus).json({
      success: false,
      error: error.message || 'Internal error',
    });
  }
}

exports.artifactAction = onRequest({
  timeoutSeconds: 60,
  memory: '256MiB',
  maxInstances: 30,
}, requireFlexibleAuth(artifactActionHandler));
