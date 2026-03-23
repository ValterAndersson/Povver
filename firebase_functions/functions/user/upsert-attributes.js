const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const FirestoreHelper = require('../utils/firestore-helper');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { logger } = require('firebase-functions');

const db = new FirestoreHelper();

/**
 * Upsert user_attributes/{uid} with an allowed set of fields.
 * Canonical store for preferences and profile.
 */
async function upsertUserAttributesHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }
    const userId = getAuthenticatedUserId(req);
    if (!userId) return fail(res, 'INVALID_ARGUMENT', 'Missing userId', null, 400);

    const attrs = req.body?.attributes || {};
    if (!attrs || typeof attrs !== 'object') return fail(res, 'INVALID_ARGUMENT', 'attributes object required', null, 400);

    // Whitelist fields we accept (snake_case per schema)
    const allowed = [
      'timezone',
      'weight_format',
      'height_format',
      'week_starts_on_monday',
      'locale',
      'fitness_goal',
      'fitness_level',
      'equipment_preference',
      'height',
      'weight',
      'workouts_per_week_goal',
    ];

    const updates = {};
    for (const key of allowed) {
      if (attrs[key] !== undefined) updates[key] = attrs[key];
    }
    if (Object.keys(updates).length === 0) return fail(res, 'INVALID_ARGUMENT', 'No allowed attributes provided', null, 400);

    await db.upsertDocumentInSubcollection('users', userId, 'user_attributes', userId, updates);
    return ok(res, { updated: Object.keys(updates) });
  } catch (error) {
    logger.error('[upsertUserAttributes] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to upsert user attributes', null, 500);
  }
}

exports.upsertUserAttributes = onRequest(requireFlexibleAuth(upsertUserAttributesHandler));


