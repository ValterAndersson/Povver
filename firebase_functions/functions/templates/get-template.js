const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { getTemplate } = require('../shared/templates');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Get Specific Template
 *
 * Thin HTTP wrapper — business logic lives in shared/templates.js
 */
async function getTemplateHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHENTICATED', 'Authentication required', null, 401);

  const templateId = req.query.templateId || req.body?.templateId || req.body?.template_id;

  try {
    const template = await getTemplate(db, userId, templateId);
    return ok(res, template);
  } catch (err) {
    return fail(res, ...mapErrorToResponse(err));
  }
}

exports.getTemplate = onRequest(requireFlexibleAuth(getTemplateHandler));
