/**
 * revoke-tokens.js - Revoke all MCP OAuth tokens for the authenticated user
 *
 * Deletes all documents in mcp_tokens and mcp_oauth_codes for the user.
 * Paginates at 500 (Firestore batch limit) to handle users with many tokens.
 *
 * Security:
 * - Bearer lane only (userId from verified Firebase token)
 *
 * Called by: iOS ConnectedAppsView (disconnect action)
 */
'use strict';

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ok, fail } = require('../utils/response');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');

const db = admin.firestore();

async function revokeMcpTokensHandler(req, res) {
  if (req.method !== 'POST') {
    return fail(res, 'METHOD_NOT_ALLOWED', 'POST required', null, 405);
  }

  const userId = getAuthenticatedUserId(req);
  if (!userId) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  let deleted = 0;

  // Only query collections that have user_id field (nonces are keyed by nonce value, no user_id)
  // Paginate at 500 (Firestore batch limit)
  for (const collection of ['mcp_tokens', 'mcp_oauth_codes']) {
    let hasMore = true;
    while (hasMore) {
      const snap = await db.collection(collection)
        .where('user_id', '==', userId)
        .limit(500)
        .get();

      if (snap.empty) { hasMore = false; break; }

      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
      deleted += snap.docs.length;

      if (snap.docs.length < 500) hasMore = false;
    }
  }

  logger.info('MCP tokens revoked', { userId, deleted });
  return ok(res, { revoked: true, deleted });
}

const fn = onRequest({ invoker: 'public' }, requireFlexibleAuth(revokeMcpTokensHandler));

module.exports = { revokeMcpTokens: fn };
