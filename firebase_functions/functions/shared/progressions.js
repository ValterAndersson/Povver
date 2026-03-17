/**
 * =============================================================================
 * shared/progressions.js - Progression Business Logic (shared module)
 * =============================================================================
 *
 * Extracted from agents/apply-progression.js so the same logic can be
 * invoked from HTTP handlers, background jobs, or tests without coupling
 * to req/res.
 *
 * FIRESTORE WRITES:
 * - Creates: users/{uid}/agent_recommendations/{id}
 * - Updates: users/{uid}/templates/{id} (if autoApply=true)
 * - Updates: users/{uid}/routines/{id} (if autoApply=true)
 * - Creates: users/{uid}/templates/{id}/changelog/{id} (if template + autoApply)
 */

const admin = require('firebase-admin');
const { ValidationError, NotFoundError } = require('./errors');

// ── Pure helpers (no Firestore) ──────────────────────────────────────────────

/**
 * Resolve a dotted/bracket path like "exercises[0].sets[0].weight" to its
 * current value inside `obj`. Returns `undefined` when any segment is missing.
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
 * Set a deeply nested value using a bracket/dot path.
 * Creates intermediate objects or arrays as needed.
 *
 * Example: setNestedValue(obj, "exercises[0].sets[1].weight", 100)
 */
function setNestedValue(obj, path, value) {
  const parts = path.split(/[.\[\]]/).filter(Boolean);
  let current = obj;

  for (let i = 0; i < parts.length - 1; i++) {
    const part = parts[i];
    if (current[part] === undefined) {
      const nextPart = parts[i + 1];
      current[part] = /^\d+$/.test(nextPart) ? [] : {};
    }
    current = current[part];
  }

  const lastPart = parts[parts.length - 1];
  current[lastPart] = value;
}

/**
 * Apply an array of changes to a deep copy of `obj`.
 * Each change must have `{ path, to }`.
 */
function applyChangesToObject(obj, changes) {
  const copy = JSON.parse(JSON.stringify(obj));
  for (const change of changes) {
    setNestedValue(copy, change.path, change.to);
  }
  return copy;
}

/**
 * Infer recommendation type from the change paths / values.
 */
function inferRecommendationType(changes) {
  const changePaths = changes.map(c => c.path).join(' ');

  if (changePaths.includes('weight')) return 'progression';
  if (changePaths.includes('reps') && !changePaths.includes('weight')) return 'volume_adjustment';
  if (changePaths.includes('exercise')) return 'exercise_swap';
  if (changes.some(c => c.to < c.from)) return 'deload';

  return 'progression';
}

// ── Core Firestore logic ─────────────────────────────────────────────────────

/**
 * Apply changes to a template or routine document and write a changelog entry
 * (for templates).
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {'template'|'routine'} targetType
 * @param {string} targetId
 * @param {Array<{path:string, from:*, to:*, rationale?:string}>} changes
 * @param {Object} [metadata]  Extra fields forwarded to the changelog entry
 * @returns {{ [key: string]: * }} Result summary
 * @throws {NotFoundError} when the target document does not exist
 */
async function applyChangesToTarget(db, userId, targetType, targetId, changes, metadata = {}) {
  const targetPath = targetType === 'template'
    ? `users/${userId}/templates/${targetId}`
    : `users/${userId}/routines/${targetId}`;

  const targetRef = db.doc(targetPath);
  const targetSnap = await targetRef.get();

  if (!targetSnap.exists) {
    throw new NotFoundError(`${targetType} not found: ${targetId}`);
  }

  const targetData = targetSnap.data();
  const updatedData = applyChangesToObject(targetData, changes);

  const batch = db.batch();

  batch.update(targetRef, {
    ...updatedData,
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
    last_progression_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Audit trail: changelog sub-collection for templates
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
 * Main entry point: validate inputs, create an agent_recommendation document,
 * optionally auto-apply changes, and return a result summary.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId
 * @param {Object} options
 * @param {'template'|'routine'} options.targetType
 * @param {string} options.targetId
 * @param {Array<{path:string, from:*, to:*, rationale?:string}>} options.changes
 * @param {string} options.summary       Human-readable summary
 * @param {string} [options.rationale]   Full explanation
 * @param {string} [options.trigger]     e.g. "post_workout", "scheduled"
 * @param {Object} [options.triggerContext]
 * @param {boolean} [options.autoApply=true]
 * @returns {Promise<Object>} Result with recommendationId, state, applied flag
 * @throws {ValidationError} on bad inputs
 */
async function applyProgression(db, userId, options) {
  const {
    targetType,
    targetId,
    changes,
    summary,
    rationale,
    trigger,
    triggerContext,
    autoApply = true,
  } = options;

  // ── Validation ──
  const missing = [];
  if (!userId) missing.push('userId');
  if (!targetType) missing.push('targetType');
  if (!targetId) missing.push('targetId');
  if (!changes) missing.push('changes');
  if (!summary) missing.push('summary');
  if (missing.length > 0) {
    throw new ValidationError('Missing required fields', { missing });
  }

  if (!['template', 'routine'].includes(targetType)) {
    throw new ValidationError('targetType must be template or routine');
  }

  if (!Array.isArray(changes) || changes.length === 0) {
    throw new ValidationError('changes must be a non-empty array');
  }

  // ── Build recommendation document ──
  const { FieldValue } = admin.firestore;
  const now = FieldValue.serverTimestamp();

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
      confidence: 0.8, // Default confidence
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

  // ── Auto-apply if requested ──
  let applyResult = null;
  if (autoApply) {
    try {
      applyResult = await applyChangesToTarget(db, userId, targetType, targetId, changes, {
        recommendation_id: recommendationRef.id,
      });
      recommendationData.applied_at = now;
      recommendationData.result = applyResult;
    } catch (applyError) {
      // Still save the recommendation, but mark it failed
      recommendationData.state = 'failed';
      recommendationData.state_history.push({
        from: 'applied',
        to: 'failed',
        at: new Date().toISOString(),
        by: 'system',
        note: `Apply failed: ${applyError.message}`,
      });
      // Re-throw NotFoundError so the caller can map to 404;
      // other errors are captured in the recommendation state.
      if (applyError instanceof NotFoundError) {
        await recommendationRef.set(recommendationData);
        throw applyError;
      }
    }
  }

  // ── Persist recommendation ──
  await recommendationRef.set(recommendationData);

  return {
    recommendationId: recommendationRef.id,
    state: recommendationData.state,
    applied: autoApply && recommendationData.state === 'applied',
    result: applyResult,
  };
}

module.exports = {
  applyProgression,
  applyChangesToTarget,
  applyChangesToObject,
  setNestedValue,
  resolvePathValue,
  inferRecommendationType,
};
