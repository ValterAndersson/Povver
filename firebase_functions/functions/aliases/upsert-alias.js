const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

async function upsertAliasHandler(req, res) {
  try {
    if (req.method !== 'POST') return fail(res, 'METHOD_NOT_ALLOWED', 'Method Not Allowed', null, 405);
    const userId = req.user?.uid || req.auth?.uid || 'service';

    const { alias_slug, exercise_id, family_slug } = req.body || {};
    if (!alias_slug || !exercise_id) return fail(res, 'INVALID_ARGUMENT', 'alias_slug and exercise_id required');
    const db = admin.firestore();
    const ref = db.collection('exercise_aliases').doc(String(alias_slug));
    const snap = await ref.get();
    const now = admin.firestore.FieldValue.serverTimestamp();
    const payload = {
      alias_slug: String(alias_slug),
      exercise_id: String(exercise_id),
      family_slug: family_slug || null,
      updated_at: now,
    };
    if (!snap.exists) payload.created_at = now;
    await ref.set(payload, { merge: true });
    return ok(res, { alias_slug, exercise_id });
  } catch (error) {
    logger.error('[upsertAlias] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to upsert alias', null, 500);
  }
}

exports.upsertAlias = onRequest(requireFlexibleAuth(upsertAliasHandler));


