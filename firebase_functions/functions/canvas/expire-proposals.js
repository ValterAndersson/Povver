const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { logger } = require('firebase-functions');

async function expireProposals(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const { userId, canvasId } = req.body || {};
    if (!userId) {
      return fail(res, 'INVALID_ARGUMENT', 'Missing userId', null, 400);
    }

    const db = admin.firestore();
    const nowTs = Date.now();
    let expired = 0;

    const processCanvas = async (cPath) => {
      const cardsRef = db.collection(`${cPath}/cards`);
      const snap = await cardsRef.where('status', '==', 'proposed').get();
      const batch = db.batch();
      let batchOps = 0;
      for (const doc of snap.docs) {
        const data = doc.data();
        if (data?.ttl?.minutes && data.created_at?.toMillis) {
          const createdMs = data.created_at.toMillis();
          if (createdMs + data.ttl.minutes * 60 * 1000 < nowTs) {
            batch.update(doc.ref, { status: 'expired', updated_at: admin.firestore.FieldValue.serverTimestamp() });
            batchOps += 1;
            expired += 1;
            // Remove from up_next if present
            const upNextRef = db.collection(`${cPath}/up_next`).where('card_id', '==', doc.id).limit(5);
            const upSnap = await upNextRef.get();
            upSnap.forEach(u => {
              batch.delete(u.ref);
              batchOps += 1;
            });
            if (batchOps >= 400) { // avoid hitting 500 limit
              await batch.commit();
              batchOps = 0;
            }
          }
        }
      }
      if (batchOps > 0) await batch.commit();
    };

    if (canvasId) {
      await processCanvas(`users/${userId}/canvases/${canvasId}`);
    } else {
      // Process all canvases for user
      const canvasesSnap = await db.collection(`users/${userId}/canvases`).limit(500).get();
      for (const c of canvasesSnap.docs) {
        await processCanvas(`users/${userId}/canvases/${c.id}`);
      }
    }

    return ok(res, { expired, scope: canvasId ? 'single_canvas' : 'all_canvases' });
  } catch (error) {
    logger.error('[expireProposals] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to expire proposals', null, 500);
  }
}

module.exports = { expireProposals };


