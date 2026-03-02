/**
 * Analysis Summary Endpoint
 * Returns pre-computed analysis insights for coaching
 *
 * Uses onRequest (not onCall) for compatibility with HTTP clients.
 * Bearer auth (iOS + agent)
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * Get today's date in YYYY-MM-DD format (UTC)
 */
function getTodayDateKey() {
  const now = new Date();
  return now.toISOString().split('T')[0];
}

/**
 * getAnalysisSummary
 * Returns pre-computed analysis data from multiple collections
 */
exports.getAnalysisSummary = onRequest(requireFlexibleAuth(async (req, res) => {
  try {
    // Get userId from auth or body (dual-auth: Bearer lane or API key + userId in body)
    const userId = getAuthenticatedUserId(req);
    if (!userId) {
      return fail(res, 'MISSING_USER_ID', 'userId is required', null, 400);
    }

    // Parse optional params
    const sections = req.body.sections || null; // e.g. ["insights", "weekly_review"]
    const insightsLimit = req.body.limit || 5;
    const dateKey = req.body.date || getTodayDateKey();

    const validSections = ['insights', 'weekly_review', 'recommendation_history'];
    const requestedSections = sections
      ? sections.filter(s => validSections.includes(s))
      : validSections;

    const now = admin.firestore.Timestamp.now();

    // Build parallel reads for only requested sections
    const reads = {};

    if (requestedSections.includes('insights')) {
      // Over-fetch non-expired insights, then sort by workout_date in memory.
      // Firestore requires orderBy on the inequality field (expires_at), but we
      // want results sorted by workout recency, not analysis creation order.
      reads.insights = db.collection('users').doc(userId)
        .collection('analysis_insights')
        .where('expires_at', '>', now)
        .orderBy('expires_at')
        .limit(50)
        .get();
    }


    if (requestedSections.includes('weekly_review')) {
      reads.weekly_review = db.collection('users').doc(userId)
        .collection('weekly_reviews')
        .orderBy('created_at', 'desc')
        .limit(1)
        .get();
    }

    if (requestedSections.includes('recommendation_history')) {
      const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
      reads.recommendation_history = db.collection('users').doc(userId)
        .collection('agent_recommendations')
        .where('created_at', '>', admin.firestore.Timestamp.fromDate(thirtyDaysAgo))
        .orderBy('created_at', 'desc')
        .limit(20)
        .get();
    }

    // Execute all reads in parallel
    const keys = Object.keys(reads);
    const snapshots = await Promise.all(keys.map(k => reads[k]));
    const results = {};
    keys.forEach((k, i) => { results[k] = snapshots[i]; });

    // Build response payload — only include requested sections
    const response = { generated_at: new Date().toISOString() };

    if (results.insights) {
      const insights = [];
      for (const doc of results.insights.docs) {
        const data = doc.data();
        const insight = {
          id: doc.id,
          type: data.type,
          workout_id: data.workout_id || null,
          workout_date: data.workout_date || null,
          summary: data.summary || '',
          highlights: data.highlights || [],
          flags: data.flags || [],
          recommendations: data.recommendations || [],
          created_at: data.created_at?.toDate?.()?.toISOString() || data.created_at,
          expires_at: data.expires_at?.toDate?.()?.toISOString() || data.expires_at,
        };
        // Include template diff summary if the user deviated from template
        if (data.template_diff_summary) {
          insight.template_diff_summary = data.template_diff_summary;
        }
        insights.push(insight);
      }
      // Sort by workout_date descending so most recent workouts come first
      insights.sort((a, b) => (b.workout_date || '').localeCompare(a.workout_date || ''));
      response.insights = insights.slice(0, insightsLimit);
    }


    if (results.weekly_review) {
      let weeklyReview = null;
      if (!results.weekly_review.empty) {
        const doc = results.weekly_review.docs[0];
        const data = doc.data();
        weeklyReview = {
          id: doc.id,
          week_ending: data.week_ending || null,
          summary: data.summary || '',
          training_load: {
            ...(data.training_load || {}),
            acwr: data.training_load?.acwr || null,
          },
          muscle_balance: data.muscle_balance || [],
          exercise_trends: data.exercise_trends || [],
          progression_candidates: data.progression_candidates || [],
          stalled_exercises: data.stalled_exercises || [],
          periodization: data.periodization || null,
          routine_recommendations: data.routine_recommendations || [],
          fatigue_status: data.fatigue_status || null,
          created_at: data.created_at?.toDate?.()?.toISOString() || data.created_at,
        };
      }
      response.weekly_review = weeklyReview;
    }

    if (results.recommendation_history) {
      const recommendations = [];
      for (const doc of results.recommendation_history.docs) {
        const data = doc.data();
        const rec = data.recommendation || {};
        const target = data.target || {};
        recommendations.push({
          id: doc.id,
          created_at: data.created_at?.toDate?.()?.toISOString() || data.created_at,
          state: data.state || 'unknown',
          scope: data.scope || null,
          trigger: data.trigger || null,
          target: {
            exercise_name: target.exercise_name || null,
            template_name: target.template_name || null,
            muscle_group: target.muscle_group || null,
          },
          recommendation: {
            type: rec.type || null,
            summary: rec.summary || '',
            rationale: rec.rationale || null,
            confidence: rec.confidence || null,
            change_count: (rec.changes || []).length,
          },
          applied_at: data.applied_at?.toDate?.()?.toISOString() || data.applied_at || null,
          applied_by: data.applied_by || null,
        });
      }
      response.recommendation_history = recommendations;
    }

    return ok(res, response);

  } catch (error) {
    logger.error('[getAnalysisSummary] Error', { error: error.message });
    return fail(res, 'INTERNAL_ERROR', error.message, null, 500);
  }
}));
