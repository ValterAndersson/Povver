/**
 * delete-account.js - Server-side account deletion (App Store Guideline 5.1.1(v))
 *
 * Deletes ALL user data from Firestore using Admin SDK, including collections
 * that Firestore security rules block client writes to (conversations, canvases,
 * agent_sessions, agent_recommendations, subscription_events, exercise_usage_stats).
 *
 * Also deletes the Firebase Auth account so the user doesn't need client-side delete.
 *
 * Security:
 * - Bearer lane only (userId from verified Firebase token)
 * - Rejects API key auth
 * - User can only delete their own account
 *
 * Called by: iOS AuthService.deleteAccount()
 */
'use strict';

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');

const db = admin.firestore();

// All known subcollections under users/{uid}
// Must include every collection, especially those with allow write: if false in Firestore rules
const USER_SUBCOLLECTIONS = [
  'user_attributes',
  'linked_devices',
  'workouts',
  'templates',
  'routines',
  'active_workouts',
  'canvases',
  'progress_reports',
  'weekly_stats',
  'analytics_series_exercise',
  'analytics_series_muscle',
  'analytics_rollups',
  'analytics_state',
  'conversations',
  'agent_sessions',
  'agent_recommendations',
  'subscription_events',
  'exercise_usage_stats',
  'set_facts',
  'meta',
  'mcp_change_log',
  'agent_memory',
  'analysis_insights',
  'weekly_reviews',
];

// Subcollections that themselves have sub-subcollections
const NESTED_SUBCOLLECTIONS = {
  conversations: ['messages', 'artifacts'],
  canvases: ['cards'],
};

/**
 * Delete all documents in a collection (batch delete, max 500 per batch).
 */
async function deleteCollection(collectionRef) {
  let deleted = 0;
  const batchSize = 500;
  const maxBatches = 200; // Safety limit: 200 × 500 = 100,000 docs max

  for (let i = 0; i < maxBatches; i++) {
    const snapshot = await collectionRef.limit(batchSize).get();
    if (snapshot.empty) break;

    const batch = db.batch();
    snapshot.docs.forEach(doc => batch.delete(doc.ref));
    await batch.commit();
    deleted += snapshot.size;
  }

  return deleted;
}

async function deleteAccountHandler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ success: false, error: 'Method Not Allowed' });
  }

  // Bearer lane only — userId from verified token
  const userId = req.auth?.uid;
  if (!userId || req.auth?.type === 'api_key') {
    return fail(res, 'UNAUTHENTICATED', 'Bearer token required', null, 401);
  }

  logger.info('[deleteAccount] starting', { userId });

  try {
    const userRef = db.collection('users').doc(userId);

    // Verify user exists
    const userDoc = await userRef.get();
    if (!userDoc.exists) {
      return fail(res, 'NOT_FOUND', 'User not found', null, 404);
    }

    let totalDeleted = 0;

    // Delete nested sub-subcollections first (e.g., conversations/*/messages)
    for (const [parent, children] of Object.entries(NESTED_SUBCOLLECTIONS)) {
      const parentSnap = await userRef.collection(parent).get();
      for (const parentDoc of parentSnap.docs) {
        for (const child of children) {
          const childDeleted = await deleteCollection(parentDoc.ref.collection(child));
          totalDeleted += childDeleted;
        }
      }
    }

    // Delete all top-level subcollections
    for (const subcollection of USER_SUBCOLLECTIONS) {
      const deleted = await deleteCollection(userRef.collection(subcollection));
      totalDeleted += deleted;
      if (deleted > 0) {
        logger.info('[deleteAccount] deleted subcollection', {
          userId,
          subcollection,
          count: deleted,
        });
      }
    }

    // Delete cache entries (predictable key pattern)
    const cacheRef = db.collection('cache').doc(`profile_${userId}`);
    const cacheDoc = await cacheRef.get();
    if (cacheDoc.exists) {
      await cacheRef.delete();
      totalDeleted += 1;
    }

    // Clean up MCP root collections (keyed by user_id)
    for (const collection of ['mcp_tokens', 'mcp_oauth_codes', 'mcp_oauth_nonces', 'mcp_api_keys']) {
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
        if (snap.docs.length < 500) hasMore = false;
      }
    }

    // Delete the user document itself
    await userRef.delete();
    totalDeleted += 1;

    // Delete Firebase Auth account
    try {
      await admin.auth().deleteUser(userId);
      logger.info('[deleteAccount] auth_account_deleted', { userId });
    } catch (authErr) {
      // Log but don't fail — Firestore data is already gone
      logger.error('[deleteAccount] auth_delete_failed', {
        userId,
        error: String(authErr?.message || authErr),
      });
    }

    logger.info('[deleteAccount] complete', { userId, totalDeleted });
    return ok(res, { deleted: true, totalDeleted });
  } catch (error) {
    logger.error('[deleteAccount] failed', {
      userId,
      error: String(error?.message || error),
    });
    return fail(res, 'INTERNAL', 'Account deletion failed', null, 500);
  }
}

const fn = onRequest(
  { timeoutSeconds: 120, memory: '512MiB' },
  requireFlexibleAuth(deleteAccountHandler)
);

module.exports = { deleteAccount: fn };
