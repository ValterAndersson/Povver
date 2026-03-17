const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { createTemplateFromPlan } = require('../shared/templates');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Create Template From Plan
 *
 * Thin HTTP wrapper — business logic lives in shared/templates.js
 */
async function createTemplateFromPlanHandler(req, res) {
  const callerUid = getAuthenticatedUserId(req);
  if (!callerUid) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  const { canvasId, cardId, name, mode, existingTemplateId } = req.body;

  try {
    const result = await createTemplateFromPlan(db, callerUid, {
      canvasId,
      cardId,
      name,
      mode,
      existingTemplateId,
    });
    return ok(res, result);
  } catch (err) {
    return mapErrorToResponse(res, err);
  }
}

exports.createTemplateFromPlan = requireFlexibleAuth(createTemplateFromPlanHandler);
