/**
 * generate-api-key.js - Generate MCP API key for external AI clients
 *
 * Premium-gated. Generates a random 32-byte API key, SHA-256 hashes it,
 * writes to mcp_api_keys/{hash}, returns raw key once.
 *
 * The raw key is shown exactly once — we only store the hash.
 * Clients present the raw key; we hash it on lookup to find the owner.
 *
 * Security:
 * - Bearer lane only (userId from verified Firebase token)
 * - Premium subscription required
 *
 * Called by: iOS ConnectedAppsView
 */
'use strict';

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { isPremiumUser } = require('../utils/subscription-gate');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');
const crypto = require('crypto');

const db = admin.firestore();

async function generateMcpApiKeyHandler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ success: false, error: 'Method Not Allowed' });
  }

  const userId = getAuthenticatedUserId(req);
  if (!userId) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  if (!(await isPremiumUser(userId))) {
    return fail(res, 'PREMIUM_REQUIRED', 'Premium subscription required', null, 403);
  }

  const { name = 'Default' } = req.body || {};

  if (typeof name !== 'string' || name.length > 100) {
    return fail(res, 'INVALID_INPUT', 'Key name must be a string under 100 characters', null, 400);
  }

  // Limit keys per user to prevent abuse
  const existingKeys = await db.collection('mcp_api_keys')
    .where('user_id', '==', userId)
    .get();

  if (existingKeys.size >= 5) {
    return fail(res, 'LIMIT_EXCEEDED', 'Maximum 5 API keys per user', null, 400);
  }

  // Generate random key, store only the hash
  const rawKey = 'pvk_' + crypto.randomBytes(32).toString('hex');
  const keyHash = crypto.createHash('sha256').update(rawKey).digest('hex');

  await db.doc(`mcp_api_keys/${keyHash}`).set({
    user_id: userId,
    name: name.trim(),
    created_at: admin.firestore.FieldValue.serverTimestamp(),
    last_used_at: null,
  });

  return ok(res, {
    key: rawKey,
    name: name.trim(),
    key_id: keyHash.slice(0, 8),
  });
}

const fn = onRequest({ invoker: 'public' }, requireFlexibleAuth(generateMcpApiKeyHandler));

module.exports = { generateMcpApiKey: fn };
