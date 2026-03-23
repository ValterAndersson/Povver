const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

async function deleteAliasHandler(req, res) {
  try {
    if (req.method !== 'POST') return fail(res, 'METHOD_NOT_ALLOWED', 'Method Not Allowed', null, 405);
    const userId = req.user?.uid || req.auth?.uid || 'service';

    const { alias_slug } = req.body || {};
    if (!alias_slug) return fail(res, 'INVALID_ARGUMENT', 'alias_slug required');
    const db = admin.firestore();
    await db.collection('exercise_aliases').doc(String(alias_slug)).delete();
    return ok(res, { alias_slug, deleted: true });
  } catch (error) {
    logger.error('[deleteAlias] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to delete alias', null, 500);
  }
}

exports.deleteAlias = onRequest(requireFlexibleAuth(deleteAliasHandler));


