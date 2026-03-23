const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');

/**
 * Propose a session plan based on constraints.
 * This is a stub that returns a minimal valid shape; logic will be expanded.
 */
async function proposeSessionHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    const userId = getAuthenticatedUserId(req);

    const constraints = req.body?.constraints || {};

    const plan = {
      blocks: [
        {
          exercise_id: 'bench_press_machine',
          sets: [
            { target: { reps: 10, rir: 2, weight: null, tempo: '3-1-1', rest_sec: 120 } },
            { target: { reps: 8, rir: 2, weight: null, tempo: '3-1-1', rest_sec: 120 } }
          ],
          alts: [ { exercise_id: 'incline_dumbbell_press', reason: 'angle rotation' } ]
        }
      ]
    };

    return res.status(200).json({
      success: true,
      data: {
        plan_id: null,
        plan,
        rationale: 'Initial stub plan based on default push emphasis.'
      }
    });
  } catch (error) {
    console.error('propose-session error:', error);
    return res.status(500).json({ success: false, error: 'Failed to propose session' });
  }
}

exports.proposeSession = onRequest(requireFlexibleAuth(proposeSessionHandler));


