const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { logger } = require('firebase-functions');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { patchTemplate } = require('../shared/templates');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Patch Template
 *
 * Thin HTTP wrapper — business logic lives in shared/templates.js
 */
async function patchTemplateHandler(req, res) {
  const callerUid = getAuthenticatedUserId(req);
  if (!callerUid) {
    return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);
  }

  const { templateId, patch, change_source, recommendation_id, workout_id } = req.body;

  try {
    const result = await patchTemplate(db, callerUid, templateId, patch, {
      change_source,
      recommendation_id,
      workout_id,
    });

    logger.info('[patchTemplate] Template updated with changelog', {
      userId: callerUid, templateId, patchedFields: result.patchedFields, source: change_source || 'user_edit',
    });

    return ok(res, result);
  } catch (err) {
    return mapErrorToResponse(res, err);
  }
}

exports.patchTemplate = requireFlexibleAuth(patchTemplateHandler);
