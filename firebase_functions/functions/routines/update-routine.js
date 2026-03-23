const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const FirestoreHelper = require('../utils/firestore-helper');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const { RoutineSchema } = require('../utils/validators');
const { formatValidationResponse } = require('../utils/validation-response');
const admin = require('firebase-admin');

const db = new FirestoreHelper();
const firestore = admin.firestore();

/**
 * Firebase Function: Update Routine
 * 
 * IMPORTANT: Validates that all template_ids reference existing templates.
 */
async function updateRoutineHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { routineId, routine } = req.body || {};
  if (!routineId || !routine) return fail(res, 'INVALID_ARGUMENT', 'Missing required parameters', ['routineId','routine'], 400);
  const parsed = RoutineSchema.safeParse(routine);
  if (!parsed.success) {
    const details = formatValidationResponse(routine, parsed.error.errors, null);
    return fail(res, 'INVALID_ARGUMENT', 'Invalid routine data', details, 400);
  }

  try {
    const existingRoutine = await db.getDocumentFromSubcollection('users', userId, 'routines', routineId);
    if (!existingRoutine) return fail(res, 'NOT_FOUND', 'Routine not found', null, 404);

    // Collect template IDs from either format
    const templateIds = routine.template_ids || routine.templateIds || [];
    
    // =========================================================================
    // CRITICAL: Validate all template_ids exist before updating routine
    // =========================================================================
    if (templateIds.length > 0) {
      const templatesCol = firestore.collection('users').doc(userId).collection('templates');
      const missingIds = [];
      
      const templateRefs = templateIds.map(tid => templatesCol.doc(tid));
      const templateDocs = await firestore.getAll(...templateRefs);
      
      templateDocs.forEach((doc, idx) => {
        if (!doc.exists) {
          missingIds.push(templateIds[idx]);
        }
      });
      
      if (missingIds.length > 0) {
        return fail(res, 'INVALID_ARGUMENT', 'Templates not found', {
          missing_template_ids: missingIds,
          hint: `Templates [${missingIds.join(', ')}] do not exist.`,
          retryable: true,
          recovery_options: [
            'Create the missing templates first',
            'Remove the invalid template_ids from the request',
          ],
        }, 400);
      }
    }

    const updatedRoutine = {
      ...routine,
      // Normalize to snake_case
      template_ids: templateIds,
      // Guarantee an `id` field inside the document
      id: routine.id || routineId
    };
    
    // Remove camelCase version if it exists
    delete updatedRoutine.templateIds;

    await db.updateDocumentInSubcollection('users', userId, 'routines', routineId, {
      ...updatedRoutine,
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    const result = await db.getDocumentFromSubcollection('users', userId, 'routines', routineId);

    return ok(res, { routine: result });

  } catch (error) {
    console.error('update-routine function error:', error);
    return fail(res, 'INTERNAL', 'Failed to update routine', { message: error.message }, 500);
  }
}

exports.updateRoutine = onRequest(requireFlexibleAuth(updateRoutineHandler));
