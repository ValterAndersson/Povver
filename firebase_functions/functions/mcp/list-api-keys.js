/**
 * list-api-keys.js - List MCP API keys for the authenticated user
 *
 * Returns key metadata only (name, created_at, last_used_at, key_id prefix).
 * Never returns the raw key — that is shown only at generation time.
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

async function listMcpApiKeysHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  const snap = await db.collection('mcp_api_keys')
    .where('user_id', '==', userId)
    .get();

  const keys = snap.docs.map(doc => ({
    key_id: doc.id.slice(0, 8),
    name: doc.data().name,
    created_at: doc.data().created_at,
    last_used_at: doc.data().last_used_at,
  }));

  return ok(res, { keys });
}

const fn = onRequest({ invoker: 'public' }, requireFlexibleAuth(listMcpApiKeysHandler));

module.exports = { listMcpApiKeys: fn };
