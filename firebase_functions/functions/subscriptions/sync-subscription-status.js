/**
 * sync-subscription-status.js - Route iOS subscription sync through Cloud Function
 *
 * Why: Firestore rules block client writes to subscription fields.
 * iOS SubscriptionService.syncToFirestore() calls this after StoreKit entitlement check.
 *
 * Security:
 * - Bearer lane only (userId from verified Firebase token)
 * - Rejects API key auth (only iOS app should call this)
 * - REQUIRES signedTransactionInfo (Apple JWS) — verifies against Apple root certs
 * - Only accepts positive entitlements (tier=premium, status in active/trial/grace_period)
 * - Webhook remains authoritative for downgrades (client never writes tier=free)
 *
 * Called by: iOS SubscriptionService after StoreKit entitlement check
 */
const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { verifySignedTransaction } = require('./apple-verifier');
const { authLimiter } = require('../utils/rate-limiter');

const db = admin.firestore();

async function syncSubscriptionStatusHandler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ success: false, error: 'Method Not Allowed' });
  }

  // Bearer lane only — userId from verified token
  const userId = req.auth?.uid;
  if (!userId || req.auth?.type === 'api_key') {
    return fail(res, 'UNAUTHENTICATED', 'Bearer token required', null, 401);
  }

  if (!authLimiter.check(userId)) {
    return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
  }

  const { status, tier, autoRenewEnabled, inGracePeriod, productId, signedTransactionInfo } = req.body;

  // CRITICAL: Require signed transaction proof from Apple
  if (!signedTransactionInfo) {
    logger.warn('[syncSubscriptionStatus] missing_signed_transaction', { userId });
    return fail(res, 'INVALID_ARGUMENT',
      'signedTransactionInfo is required', null, 400);
  }

  // Verify the transaction JWS against Apple root certificates
  const decodedTransaction = await verifySignedTransaction(signedTransactionInfo);
  if (!decodedTransaction) {
    logger.error('[syncSubscriptionStatus] transaction_verification_failed', { userId });
    return fail(res, 'PERMISSION_DENIED',
      'Transaction verification failed', null, 403);
  }

  // Verify the transaction belongs to our app's bundle ID
  if (!decodedTransaction.bundleId || decodedTransaction.bundleId !== 'com.povver.Povver') {
    logger.warn('[syncSubscriptionStatus] bundle_id_mismatch', {
      userId,
      expected: 'com.povver.Povver',
      got: decodedTransaction.bundleId,
    });
    return fail(res, 'PERMISSION_DENIED',
      'Transaction bundle ID mismatch', null, 403);
  }

  // Only allow syncing POSITIVE entitlements from client
  // (webhook is authoritative for downgrades; client sync is a courtesy for faster UI)
  if (tier !== 'premium') {
    return fail(res, 'INVALID_ARGUMENT',
      'Client sync only allowed for positive entitlements', null, 400);
  }

  const allowedStatuses = ['active', 'trial', 'grace_period'];
  if (!allowedStatuses.includes(status)) {
    return fail(res, 'INVALID_ARGUMENT',
      'Client sync only allowed for active statuses', null, 400);
  }

  try {
    const userRef = db.collection('users').doc(userId);
    await db.runTransaction(async (t) => {
      const userDoc = await t.get(userRef);
      const currentData = userDoc.data() || {};

      // Timestamp-based conflict resolution:
      // If subscription was updated more recently than this sync's source data,
      // the webhook has already set authoritative state — don't overwrite.
      const currentUpdatedAt = currentData.subscription_updated_at?.toMillis?.() || 0;
      const transactionTimestamp = decodedTransaction.signedDate || 0;

      if (currentUpdatedAt > transactionTimestamp) {
        logger.info('[syncSubscriptionStatus] skipping_stale_sync', {
          userId, currentUpdatedAt, transactionTimestamp,
        });
        return;
      }

      t.update(userRef, {
        subscription_status: status,
        subscription_tier: tier,
        subscription_auto_renew_enabled: autoRenewEnabled || false,
        subscription_in_grace_period: inGracePeriod || false,
        subscription_product_id: productId || null,
        subscription_updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    logger.info('[syncSubscriptionStatus] synced', {
      userId,
      tier,
      status,
      transactionId: decodedTransaction.originalTransactionId,
    });
    return ok(res, { synced: true });
  } catch (error) {
    logger.error('[syncSubscriptionStatus] error', { userId, error: error.message });
    return fail(res, 'INTERNAL', 'Failed to sync subscription', null, 500);
  }
}

const fn = onRequest(
  { timeoutSeconds: 10, memory: '256MiB' },
  requireFlexibleAuth(syncSubscriptionStatusHandler)
);

module.exports = { syncSubscriptionStatus: fn };
