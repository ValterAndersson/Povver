/**
 * =============================================================================
 * get-planning-context.js - Agent Context Aggregation (HTTP handler)
 * =============================================================================
 *
 * PURPOSE:
 * Thin HTTP wrapper around shared/planning-context.js.
 * Handles auth, request parsing, and response formatting.
 * All business logic lives in the shared module.
 *
 * PAYLOAD CONTROL FLAGS:
 * - includeTemplates: boolean (default true) - include routine template metadata
 * - includeTemplateExercises: boolean (default false) - include full exercise arrays
 * - includeRecentWorkouts: boolean (default true) - include workout summary
 * - workoutLimit: number (default 20) - max workouts to return
 *
 * CALLED BY:
 * - Agent: tool_get_planning_context() in planner_agent.py
 * - Agent: tool_get_training_context() in coach_agent.py
 *   -> adk_agent/canvas_orchestrator/app/libs/tools_canvas/client.py
 *
 * =============================================================================
 */

const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getPlanningContext } = require('../shared/planning-context');

const firestore = admin.firestore();

async function getPlanningContextHandler(req, res) {
  const callerUid = getAuthenticatedUserId(req);
  if (!callerUid) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  const body = req.body || {};
  const query = req.query || {};
  const options = {
    includeTemplates: body.includeTemplates !== false,
    includeTemplateExercises: body.includeTemplateExercises === true,
    includeRecentWorkouts: body.includeRecentWorkouts !== false,
    workoutLimit: parseInt(body.workoutLimit) || 20,
    view: body.view || query.view, // 'compact' for agent responses
  };

  try {
    const result = await getPlanningContext(firestore, callerUid, options);
    return ok(res, result);
  } catch (error) {
    console.error('get-planning-context function error:', error);
    return fail(res, 'INTERNAL', 'Failed to get planning context', { message: error.message }, 500);
  }
}

exports.getPlanningContext = requireFlexibleAuth(getPlanningContextHandler);
