const { onSchedule } = require('firebase-functions/v2/scheduler');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

const db = admin.firestore();

const cleanupMcpTokens = onSchedule({
  schedule: 'every 24 hours',
  region: 'us-central1',
  timeoutSeconds: 120,
}, async () => {
  const now = admin.firestore.Timestamp.now();
  let totalDeleted = 0;

  for (const collection of ['mcp_oauth_nonces', 'mcp_oauth_codes', 'mcp_tokens']) {
    let hasMore = true;
    while (hasMore) {
      const snap = await db.collection(collection)
        .where('expires_at', '<', now)
        .limit(500)
        .get();

      if (snap.empty) {
        hasMore = false;
        break;
      }

      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
      totalDeleted += snap.docs.length;

      if (snap.docs.length < 500) hasMore = false;
    }
  }

  logger.info(`MCP token cleanup: deleted ${totalDeleted} expired documents`);
});

module.exports = { cleanupMcpTokens };
