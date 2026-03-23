const { onRequest } = require('firebase-functions/v2/https');
const { logger } = require('firebase-functions');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const { getAuthenticatedUserId } = require('../utils/auth-helpers');
const FirestoreHelper = require('../utils/firestore-helper');
const { invalidateProfileCache } = require('./get-user');

const db = new FirestoreHelper();

/**
 * Firebase Function: Update User
 * 
 * Description: Updates user preferences, goals, and settings.
 * AI can use this to update user preferences based on workout analysis.
 */
async function updateUserHandler(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) return fail(res, 'UNAUTHORIZED', 'Authentication required', null, 401);
  const { userData } = req.body || {};

  if (!userData || Object.keys(userData).length === 0) {
    return fail(res, 'INVALID_ARGUMENT', 'Missing userData', null, 400);
  }

  try {
    // Check if user exists
    const existingUser = await db.getDocument('users', userId);
    if (!existingUser) {
      return fail(res, 'NOT_FOUND', 'User not found', null, 404);
    }

    // Validate and sanitize user data
    const allowedFields = [
      'displayName', 'preferences', 'goals', 'fitnessLevel', 
      'equipment', 'activeRoutineId', 'notifications', 'aiSettings'
    ];
    
    const sanitizedData = {};
    Object.keys(userData).forEach(key => {
      if (allowedFields.includes(key)) {
        sanitizedData[key] = userData[key];
      }
    });

    if (Object.keys(sanitizedData).length === 0) {
      return fail(res, 'INVALID_ARGUMENT', 'No valid fields to update', { allowedFields }, 400);
    }

    // Update user
    await db.updateDocument('users', userId, sanitizedData);
    
    // Invalidate the profile cache so next read gets fresh data
    await invalidateProfileCache(userId);
    
    // Get updated user data
    const updatedUser = await db.getDocument('users', userId);

    return ok(res, {
      user: updatedUser,
      updatedFields: Object.keys(sanitizedData),
    });

  } catch (error) {
    logger.error('[updateUser] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to update user', null, 500);
  }
}

// Export Firebase Function
exports.updateUser = onRequest(requireFlexibleAuth(updateUserHandler));
