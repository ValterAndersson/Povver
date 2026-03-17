const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { requireFlexibleAuth } = require('../auth/middleware');
const { calculateTemplateAnalytics } = require('../utils/analytics-calculator');
const { ok, fail } = require('../utils/response');
const { createTemplate } = require('../shared/templates');
const { mapErrorToResponse } = require('../shared/errors');

const db = admin.firestore();

/**
 * Firebase Function: Create Workout Template
 *
 * Thin HTTP wrapper — business logic lives in shared/templates.js
 */
async function createTemplateHandler(req, res) {
  const { userId, template } = req.body;
  if (!userId) return fail(res, 'INVALID_ARGUMENT', 'Missing userId', null, 400);

  try {
    const result = await createTemplate(db, userId, template, {
      calculateAnalytics: calculateTemplateAnalytics,
      isAgentSource: req.auth?.source === 'third_party_agent',
    });
    return ok(res, result);
  } catch (err) {
    return mapErrorToResponse(res, err);
  }
}

exports.createTemplate = onRequest(requireFlexibleAuth(createTemplateHandler));
