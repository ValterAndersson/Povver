const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { deleteTemplate } = require('../shared/templates');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Delete Template
 *
 * Thin HTTP wrapper — business logic lives in shared/templates.js
 */
async function deleteTemplateHandler(req, res) {
  const { userId, templateId } = req.body || {};

  try {
    const result = await deleteTemplate(db, userId, templateId);
    return ok(res, result);
  } catch (err) {
    return mapErrorToResponse(res, err);
  }
}

exports.deleteTemplate = onRequest(requireFlexibleAuth(deleteTemplateHandler));
