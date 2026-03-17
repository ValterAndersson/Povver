/**
 * =============================================================================
 * get-next-workout.js - Routine Cursor Resolution
 * =============================================================================
 *
 * PURPOSE:
 * Determines which template to use for the next workout based on routine rotation.
 * This is the READ endpoint that agents and iOS use to get the next scheduled workout.
 *
 * ARCHITECTURE CONTEXT:
 * Business logic lives in shared/routines.js (getNextWorkout).
 * This file is a thin HTTP wrapper.
 *
 * SELECTION METHODS:
 * - cursor: O(1) lookup using routine.last_completed_template_id
 * - history_scan: O(N) fallback scanning last 50 workouts
 * - default_first: No history, start with first template
 * - fallback_first_available: Referenced template missing, use first valid
 *
 * CALLED BY:
 * - iOS: RoutinesViewModel.fetchNextWorkout()
 * - iOS: CanvasService.getNextWorkout()
 * - Agent: planner_tools.py -> tool_get_next_workout()
 *
 * RELATED FILES:
 * - create-routine-from-draft.js: Creates routines with template_ids
 * - ../triggers/workout-routine-cursor.js: Updates cursor on completion
 * - ../active_workout/complete-active-workout.js: Triggers cursor update
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getNextWorkout } = require('../shared/routines');
const { AuthenticationError, mapErrorToResponse } = require('../shared/errors');
const admin = require('firebase-admin');

async function getNextWorkoutHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return mapErrorToResponse(res, new AuthenticationError());

  try {
    const result = await getNextWorkout(admin.firestore(), userId);
    return ok(res, result);
  } catch (e) {
    console.error('get-next-workout function error:', e);
    return mapErrorToResponse(res, e);
  }
}

exports.getNextWorkout = onRequest(requireFlexibleAuth(getNextWorkoutHandler));
