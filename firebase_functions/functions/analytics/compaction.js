const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { ok, fail } = require('../utils/response');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

function getWeekStartMonday(dateStr) {
  const d = new Date(dateStr);
  const day = d.getUTCDay();
  const diff = day === 0 ? 6 : day - 1;
  d.setUTCDate(d.getUTCDate() - diff);
  d.setUTCHours(0, 0, 0, 0);
  return d.toISOString().split('T')[0];
}

async function compactExerciseSeriesDoc(docRef, thresholdIso) {
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(docRef);
    if (!snap.exists) return { skipped: true };
    const data = snap.data() || {};
    const points = data.points_by_day || {};
    const weeks = data.weeks_by_start || {};

    const threshold = new Date(thresholdIso);
    const toDelete = [];
    const accum = {};

    for (const [dayKey, val] of Object.entries(points)) {
      const d = new Date(dayKey + 'T00:00:00.000Z');
      if (isNaN(d.getTime())) continue;
      if (d >= threshold) continue; // keep recent days
      const wk = getWeekStartMonday(dayKey);
      const curr = accum[wk] || { e1rm_max: 0, vol_sum: 0 };
      const e1 = typeof val.e1rm === 'number' ? val.e1rm : 0;
      const vol = typeof val.vol === 'number' ? val.vol : 0;
      curr.e1rm_max = Math.max(curr.e1rm_max, e1);
      curr.vol_sum += vol;
      accum[wk] = curr;
      toDelete.push(dayKey);
    }

    if (toDelete.length === 0) return { changed: false };

    // Apply merged weeks and delete day keys
    for (const [wk, agg] of Object.entries(accum)) {
      const cur = weeks[wk] || { e1rm_max: 0, vol_sum: 0 };
      weeks[wk] = {
        e1rm_max: Math.max(cur.e1rm_max || 0, agg.e1rm_max || 0),
        vol_sum: (cur.vol_sum || 0) + (agg.vol_sum || 0),
      };
    }
    for (const day of toDelete) {
      delete points[day];
    }

    tx.set(docRef, {
      points_by_day: points,
      weeks_by_start: weeks,
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
      schema_version: data.schema_version || 1,
      compacted_at: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    return { changed: true, deleted: toDelete.length, weeks: Object.keys(accum).length };
  });
}

async function compactUserSeries(userId, days = 90) {
  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - days);
  const thresholdIso = cutoff.toISOString().split('T')[0];

  const seriesCol = db.collection('users').doc(userId).collection('analytics_series_exercise');
  const seriesSnap = await seriesCol.limit(10000).get();
  let docsChanged = 0;

  // Process in parallel with concurrency limit of 5
  const chunks = [];
  for (let i = 0; i < seriesSnap.docs.length; i += 5) {
    chunks.push(seriesSnap.docs.slice(i, i + 5));
  }
  for (const chunk of chunks) {
    const results = await Promise.all(chunk.map(doc => compactExerciseSeriesDoc(doc.ref, thresholdIso)));
    docsChanged += results.filter(r => r && r.changed).length;
  }

  return { success: true, docsChanged };
}

async function compactionControllerHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }
    const userId = getAuthenticatedUserId(req);
    const days = typeof req.body?.days === 'number' ? req.body.days : 90;
    if (!userId) return fail(res, 'INVALID_ARGUMENT', 'Missing userId', null, 400);
    const result = await compactUserSeries(userId, days);
    return ok(res, result);
  } catch (e) {
    console.error('analytics compaction error', e);
    return fail(res, 'INTERNAL', 'Failed analytics compaction', { message: e.message }, 500);
  }
}

// Scheduled compaction for recently active users (last 30 days)
const analyticsCompactionScheduled = onSchedule({
  schedule: '0 3 * * *',
  timeZone: 'UTC',
  retryConfig: { retryCount: 3, maxRetryDuration: '600s' },
}, async (event) => {
  try {
    const now = new Date();
    const thirtyDaysAgo = new Date(now);
    thirtyDaysAgo.setUTCDate(thirtyDaysAgo.getUTCDate() - 30);
    const ts = admin.firestore.Timestamp.fromDate(thirtyDaysAgo);

    const cg = await db.collectionGroup('workouts')
      .where('end_time', '>=', ts)
      .select('end_time')
      .get();
    const userIds = [...new Set(cg.docs.map(d => d.ref.parent.parent.id))];
    const batchSize = 10;
    let changed = 0;
    for (let i = 0; i < userIds.length; i += batchSize) {
      const chunk = userIds.slice(i, i + batchSize);
      const promises = chunk.map(uid => compactUserSeries(uid, 90).then(r => { changed += r.docsChanged || 0; }));
      await Promise.allSettled(promises);
      if (i + batchSize < userIds.length) await new Promise(r => setTimeout(r, 1000));
    }
    return { success: true, users: userIds.length, docsChanged: changed };
  } catch (e) {
    console.error('analyticsCompactionScheduled error', e);
    return { success: false, error: e.message };
  }
});

exports.analyticsCompactionScheduled = analyticsCompactionScheduled;
exports.compactAnalyticsForUser = onRequest(requireFlexibleAuth(compactionControllerHandler));


