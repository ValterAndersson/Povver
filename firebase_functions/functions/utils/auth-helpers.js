const { logger } = require('firebase-functions');

/**
 * Safely extract userId from request based on auth lane.
 *
 * Bearer lane (Firebase ID token):
 *   userId comes from the verified token ONLY. Client-provided userId
 *   in body/query is IGNORED to prevent IDOR attacks.
 *
 * API key lane (service-to-service):
 *   userId comes from X-User-Id header (via req.auth.uid) or
 *   req.body.userId. The caller is a trusted service (agent system)
 *   that has been authenticated by API key.
 *
 * @param {Object} req - Express request with auth middleware applied
 * @returns {string|null} - Authenticated userId or null
 */
function getAuthenticatedUserId(req) {
  // 1. Check for decoded Firebase token (set by requireAuth or requireFlexibleAuth Bearer path)
  if (req.user?.uid) {
    // Log IDOR attempts — client passed a different userId than their token
    const clientUserId = req.body?.userId || req.query?.userId;
    if (clientUserId && clientUserId !== req.user.uid) {
      logger.warn('[auth] idor_attempt_blocked', {
        token_uid: req.user.uid,
        requested_uid: clientUserId,
        path: req.path,
        ip: req.ip,
      });
    }
    return req.user.uid;
  }

  // 2. Check req.auth (set by requireFlexibleAuth or withApiKey)
  if (req.auth) {
    // API key lane: trusted service caller provides userId
    if (req.auth.type === 'api_key') {
      const candidate = req.auth.uid || req.body?.userId || null;
      // Validate non-empty string to prevent null/empty bypass
      if (candidate && typeof candidate === 'string' && candidate.trim()) {
        return candidate.trim();
      }
      return null;
    }
    // Bearer lane: uid from verified token ONLY
    if (req.auth.uid) {
      const clientUserId = req.body?.userId || req.query?.userId;
      if (clientUserId && clientUserId !== req.auth.uid) {
        logger.warn('[auth] idor_attempt_blocked', {
          token_uid: req.auth.uid,
          requested_uid: clientUserId,
          path: req.path,
          ip: req.ip,
        });
      }
      return req.auth.uid;
    }
  }

  return null;
}

module.exports = { getAuthenticatedUserId };
