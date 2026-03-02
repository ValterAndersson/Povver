/**
 * =============================================================================
 * apply-progression.js - Headless Progression Updates with Audit Logging
 * =============================================================================
 *
 * PURPOSE:
 * Apply progression changes to templates/routines WITHOUT canvas cards.
 * Used by background agents (post_workout_analyst) for automatic updates.
 *
 * KEY DESIGN:
 * - All changes are logged to agent_recommendations collection
 * - Supports two modes:
 *   1. Auto-pilot (autoApply=true): Applies changes immediately, logs with state='applied'
 *   2. Review mode (autoApply=false): Creates recommendation with state='pending_review'
 *
 * - Same code path for both modes ensures consistent audit trail
 *
 * FIRESTORE WRITES:
 * - Creates: users/{uid}/agent_recommendations/{id}
 * - Updates: users/{uid}/templates/{id} (if autoApply=true)
 * - Updates: users/{uid}/routines/{id} (if autoApply=true)
 *
 * CALLED BY:
 * - post_workout_analyst.py via apply_progression skill
 * - Potentially scheduled jobs
 *
 * =============================================================================
 */

const admin = require('firebase-admin');
const { onRequest } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const { validateRequired } = require('../utils/validators');
const { withApiKey } = require('../auth/middleware');

/**
 * Apply progression changes with full audit logging.
 * 
 * @param {Object} req.body
 * @param {string} userId - User ID
 * @param {string} targetType - "template" | "routine"
 * @param {string} targetId - Template or routine ID
 * @param {Array} changes - Array of change objects
 *   - path: Field path (e.g., "exercises[0].sets[0].weight")
 *   - from: Old value
 *   - to: New value
 *   - rationale: Why this change
 * @param {string} summary - Human-readable summary
 * @param {string} rationale - Full explanation
 * @param {string} trigger - "post_workout" | "scheduled" | "plateau_detected"
 * @param {Object} triggerContext - Context about what triggered this
 * @param {boolean} autoApply - If true, apply immediately; if false, queue for review
 */
async function applyProgressionHandler(req, res) {
  const startTime = Date.now();
  
  try {
    // Validate request
    const {
      userId,
      targetType,
      targetId,
      changes,
      summary,
      rationale,
      trigger,
      triggerContext,
      autoApply = true,
    } = req.body;
    
    const validation = validateRequired({ userId, targetType, targetId, changes, summary });
    if (!validation.valid) {
      logger.warn('[applyProgression] Validation failed', { missing: validation.missing });
      return res.status(400).json({ error: 'INVALID_ARGUMENT', missing: validation.missing });
    }
    
    if (!['template', 'routine'].includes(targetType)) {
      return res.status(400).json({ error: 'INVALID_ARGUMENT', message: 'targetType must be template or routine' });
    }
    
    if (!Array.isArray(changes) || changes.length === 0) {
      return res.status(400).json({ error: 'INVALID_ARGUMENT', message: 'changes must be a non-empty array' });
    }
    
    const db = admin.firestore();
    const { FieldValue } = admin.firestore;
    const now = FieldValue.serverTimestamp();
    
    // 1. Create recommendation document
    const recommendationRef = db.collection(`users/${userId}/agent_recommendations`).doc();
    
    const recommendationData = {
      id: recommendationRef.id,
      created_at: now,
      
      // Source context
      trigger: trigger || 'unknown',
      trigger_context: triggerContext || {},
      
      // Target
      scope: targetType,
      target: {
        [`${targetType}_id`]: targetId,
      },
      
      // The recommendation itself
      recommendation: {
        type: inferRecommendationType(changes),
        changes: changes.map(c => ({
          path: c.path,
          from: c.from,
          to: c.to,
          rationale: c.rationale || null,
        })),
        summary,
        rationale: rationale || null,
        confidence: 0.8,  // Default confidence
      },
      
      // State machine
      state: autoApply ? 'applied' : 'pending_review',
      state_history: [{
        from: null,
        to: autoApply ? 'applied' : 'pending_review',
        at: new Date().toISOString(),
        by: 'agent',
        note: autoApply ? 'Auto-applied by agent' : 'Queued for user review',
      }],
      
      applied_by: autoApply ? 'agent' : null,
    };
    
    // 2. If autoApply, apply the changes
    let applyResult = null;
    if (autoApply) {
      try {
        applyResult = await applyChangesToTarget(db, userId, targetType, targetId, changes);
        recommendationData.applied_at = now;
        recommendationData.result = applyResult;
        logger.info('[applyProgression] Changes applied', { 
          targetType, 
          targetId, 
          changeCount: changes.length 
        });
      } catch (applyError) {
        logger.error('[applyProgression] Apply failed', { error: applyError.message });
        
        // Still save the recommendation with error state
        recommendationData.state = 'failed';
        recommendationData.state_history.push({
          from: 'applied',
          to: 'failed',
          at: new Date().toISOString(),
          by: 'system',
          note: `Apply failed: ${applyError.message}`,
        });
      }
    }
    
    // 3. Save recommendation
    await recommendationRef.set(recommendationData);
    logger.info('[applyProgression] Recommendation saved', { 
      recommendationId: recommendationRef.id,
      state: recommendationData.state,
    });
    
    const elapsed = Date.now() - startTime;
    
    return res.json({
      success: true,
      recommendationId: recommendationRef.id,
      state: recommendationData.state,
      applied: autoApply && recommendationData.state === 'applied',
      result: applyResult,
      elapsedMs: elapsed,
    });
    
  } catch (error) {
    logger.error('[applyProgression] Unexpected error', { error: error.message, stack: error.stack });
    return res.status(500).json({ error: 'INTERNAL', message: 'Internal error' });
  }
}

/**
 * Infer recommendation type from changes.
 */
function inferRecommendationType(changes) {
  const changePaths = changes.map(c => c.path).join(' ');
  
  if (changePaths.includes('weight')) return 'progression';
  if (changePaths.includes('reps') && !changePaths.includes('weight')) return 'volume_adjustment';
  if (changePaths.includes('exercise')) return 'exercise_swap';
  if (changes.some(c => c.to < c.from)) return 'deload';
  
  return 'progression';
}

/**
 * Apply changes to the target document.
 *
 * @returns {Object} Result with applied changes
 */
async function applyChangesToTarget(db, userId, targetType, targetId, changes, metadata = {}) {
  const targetPath = targetType === 'template' 
    ? `users/${userId}/templates/${targetId}`
    : `users/${userId}/routines/${targetId}`;
  
  const targetRef = db.doc(targetPath);
  const targetSnap = await targetRef.get();
  
  if (!targetSnap.exists) {
    throw new Error(`${targetType} not found: ${targetId}`);
  }
  
  const targetData = targetSnap.data();
  const updates = {};
  
  // Apply each change
  for (const change of changes) {
    const value = resolvePathValue(targetData, change.path);
    if (value !== undefined) {
      // Build the update path
      // For nested paths like "exercises[0].sets[0].weight", 
      // we need to rebuild the full exercises array
      updates[change.path] = change.to;
    }
  }
  
  // For complex nested updates, we need to handle arrays specially
  // For now, do a full document read-modify-write
  const updatedData = applyChangesToObject(targetData, changes);

  const batch = db.batch();

  batch.update(targetRef, {
    ...updatedData,
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
    last_progression_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Write changelog entry for template mutations (audit trail)
  if (targetType === 'template') {
    const changelogRef = targetRef.collection('changelog').doc();
    batch.set(changelogRef, {
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      source: 'agent_auto_pilot',
      recommendation_id: metadata.recommendation_id || null,
      changes: changes.map(c => ({
        field: c.path,
        operation: c.from != null ? 'update' : 'add',
        summary: c.rationale || `${c.path}: ${c.from} → ${c.to}`,
      })),
      expires_at: new Date(Date.now() + 90 * 24 * 60 * 60 * 1000),
    });
  }

  await batch.commit();

  return {
    [`${targetType}_id`]: targetId,
    changes_applied: changes.length,
  };
}

/**
 * Resolve a path like "exercises[0].sets[0].weight" to get/set values.
 */
function resolvePathValue(obj, path) {
  const parts = path.split(/[.\[\]]/).filter(Boolean);
  let current = obj;
  
  for (const part of parts) {
    if (current === undefined || current === null) return undefined;
    current = current[part];
  }
  
  return current;
}

/**
 * Apply changes to a deep copy of the object.
 */
function applyChangesToObject(obj, changes) {
  const copy = JSON.parse(JSON.stringify(obj));
  
  for (const change of changes) {
    setNestedValue(copy, change.path, change.to);
  }
  
  return copy;
}

/**
 * Set a nested value using a path like "exercises[0].sets[0].weight".
 */
function setNestedValue(obj, path, value) {
  const parts = path.split(/[.\[\]]/).filter(Boolean);
  let current = obj;
  
  for (let i = 0; i < parts.length - 1; i++) {
    const part = parts[i];
    if (current[part] === undefined) {
      // Create intermediate objects/arrays as needed
      const nextPart = parts[i + 1];
      current[part] = /^\d+$/.test(nextPart) ? [] : {};
    }
    current = current[part];
  }
  
  const lastPart = parts[parts.length - 1];
  current[lastPart] = value;
}

// Export handler — API key required (called by agent system only)
const applyProgression = onRequest({
  cors: true,
  region: 'us-central1',
}, withApiKey(applyProgressionHandler));

module.exports = {
  applyProgression,
  applyProgressionHandler,
  applyChangesToTarget,
  setNestedValue,
  resolvePathValue,
  applyChangesToObject,
};
