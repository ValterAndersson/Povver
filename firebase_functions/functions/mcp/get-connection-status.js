/**
 * get-connection-status.js - Check MCP OAuth connection status
 *
 * Queries mcp_tokens for any non-expired token (access or refresh).
 * A user with an expired access token but valid refresh token is still
 * connected (Claude Desktop will refresh automatically).
 *
 * Security:
 * - Bearer lane only (userId from verified Firebase token)
 *
 * Called by: iOS ConnectedAppsView
 */
'use strict';

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');

const db = admin.firestore();

async function getMcpConnectionStatusHandler(req, res) {
  if (req.method !== 'GET' && req.method !== 'POST') {
    return fail(res, 'METHOD_NOT_ALLOWED', 'GET or POST required', null, 405);
  }

  const userId = getAuthenticatedUserId(req);
  if (!userId) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  // Check for any non-expired token (access OR refresh).
  // A user with an expired access token but valid refresh token is still connected
  // (Claude Desktop will refresh automatically).
  const snap = await db.collection('mcp_tokens')
    .where('user_id', '==', userId)
    .limit(10)
    .get();

  if (snap.empty) {
    return ok(res, { connected: false, last_used_at: null });
  }

  const now = Date.now();
  let connected = false;
  let lastUsedAt = null;

  for (const doc of snap.docs) {
    const data = doc.data();
    const isExpired = data.expires_at && data.expires_at.toMillis() < now;
    if (!isExpired) connected = true;
    // Track most recent last_used_at across all tokens
    if (data.last_used_at) {
      const ts = data.last_used_at.toDate().toISOString();
      if (!lastUsedAt || ts > lastUsedAt) lastUsedAt = ts;
    }
  }

  return ok(res, { connected, last_used_at: lastUsedAt });
}

const fn = onRequest({ invoker: 'public' }, requireFlexibleAuth(getMcpConnectionStatusHandler));

module.exports = { getMcpConnectionStatus: fn };
