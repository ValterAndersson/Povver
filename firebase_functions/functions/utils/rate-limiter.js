/**
 * Lightweight in-memory rate limiter for Firebase Functions.
 *
 * Per-instance sliding window — doesn't persist across cold starts,
 * but prevents single-source floods within a running instance.
 * Pair with maxInstances on v2 functions for global cost control.
 *
 * Usage:
 *   const limiter = createRateLimiter({ windowMs: 60000, max: 10 });
 *   // In handler:
 *   if (!limiter.check(userId)) {
 *     return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
 *   }
 */

const { logger } = require('firebase-functions');

/**
 * @param {Object} opts
 * @param {number} opts.windowMs - Sliding window size in ms
 * @param {number} opts.max      - Max requests per window per key
 * @returns {{ check: (key: string) => boolean }}
 */
function createRateLimiter({ windowMs, max }) {
  const hits = new Map(); // key → [timestamps]

  // Periodic cleanup to prevent memory leak (every 5 minutes)
  setInterval(() => {
    const cutoff = Date.now() - windowMs;
    for (const [key, timestamps] of hits) {
      const valid = timestamps.filter((t) => t > cutoff);
      if (valid.length === 0) {
        hits.delete(key);
      } else {
        hits.set(key, valid);
      }
    }
  }, 5 * 60 * 1000).unref(); // unref so it doesn't keep the process alive

  return {
    /**
     * Check if the key is within rate limit. Records the hit if allowed.
     * @param {string} key - Usually userId or IP
     * @returns {boolean} true if allowed, false if rate limited
     */
    check(key) {
      if (!key) {
        logger.warn('[rate_limit] check called with empty key — denying');
        return false;
      }
      const now = Date.now();
      const cutoff = now - windowMs;
      const timestamps = (hits.get(key) || []).filter((t) => t > cutoff);

      if (timestamps.length >= max) {
        logger.warn('[rate_limit] exceeded', { key, limit: max, window_ms: windowMs });
        return false;
      }

      timestamps.push(now);
      hits.set(key, timestamps);
      return true;
    },
  };
}

// Pre-configured limiters for different endpoint tiers
// Tier 1: Auth/financial — tight limits
const authLimiter = createRateLimiter({ windowMs: 60 * 1000, max: 10 });

// Tier 2: Agent streaming — expensive, per-hour
const agentLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 120 });

// Tier 3: Write-heavy — per-minute
const writeLimiter = createRateLimiter({ windowMs: 60 * 1000, max: 300 });

module.exports = { createRateLimiter, authLimiter, agentLimiter, writeLimiter };
