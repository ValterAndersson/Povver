/**
 * revoke-api-key.js - Revoke (delete) an MCP API key
 *
 * Finds the key by prefix match on key_id (first 8 chars of the hash),
 * verifies ownership, then deletes it.
 *
 * Security:
 * - Bearer lane only (userId from verified Firebase token)
 * - Only the key owner can revoke their own keys
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

async function revokeMcpApiKeyHandler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ success: false, error: 'Method Not Allowed' });
  }

  const userId = getAuthenticatedUserId(req);
  if (!userId) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  const { key_id } = req.body || {};

  if (!key_id || typeof key_id !== 'string' || key_id.length < 4 || key_id.length > 64) {
    return fail(res, 'INVALID_INPUT', 'key_id is required (4-64 chars)', null, 400);
  }

  // Find key by prefix match among user's keys
  const snap = await db.collection('mcp_api_keys')
    .where('user_id', '==', userId)
    .get();

  const keyDoc = snap.docs.find(doc => doc.id.startsWith(key_id));
  if (!keyDoc) {
    return fail(res, 'NOT_FOUND', 'API key not found', null, 404);
  }

  await keyDoc.ref.delete();
  return ok(res, { revoked: true, key_id });
}

const fn = onRequest(requireFlexibleAuth(revokeMcpApiKeyHandler));

module.exports = { revokeMcpApiKey: fn };
