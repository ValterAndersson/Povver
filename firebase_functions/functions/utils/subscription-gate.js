const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

/**
 * Check if a user has premium access.
 *
 * Checks in this order:
 * 1. subscription_override === 'premium' (admin override)
 * 2. subscription_tier === 'premium' (active subscription)
 *    - Also validates subscription_expires_at if present (24h grace period)
 *
 * @param {string} userId - The user ID to check
 * @returns {Promise<boolean>} - True if user has premium access
 */
async function isPremiumUser(userId) {
  if (!userId) {
    return false;
  }

  try {
    const db = admin.firestore();
    const userDoc = await db.collection('users').doc(userId).get();

    if (!userDoc.exists) {
      return false;
    }

    const userData = userDoc.data();

    // Check override first (admin grants)
    if (userData.subscription_override === 'premium') {
      return true;
    }

    // Check subscription tier
    if (userData.subscription_tier === 'premium') {
      // Check expiration if the field exists
      if (userData.subscription_expires_at) {
        const expiresAt = userData.subscription_expires_at.toDate
          ? userData.subscription_expires_at.toDate()
          : new Date(userData.subscription_expires_at);
        const graceMs = 24 * 60 * 60 * 1000; // 24h for webhook delivery delays
        if (expiresAt.getTime() + graceMs < Date.now()) {
          logger.warn('[subscriptionGate] tier_premium_but_expired', {
            userId, expires_at: expiresAt.toISOString(),
          });
          return false;
        }
      }
      // If subscription_expires_at is not set, trust subscription_tier (backwards compatible)
      return true;
    }

    return false;
  } catch (error) {
    logger.error(`Error checking premium status for user ${userId}:`, error);
    return false;
  }
}

module.exports = { isPremiumUser };
