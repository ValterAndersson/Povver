const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const FirestoreHelper = require('../utils/firestore-helper');
const { ok, fail } = require('../utils/response');
const { ExerciseUpsertSchema } = require('../utils/validators');
const { toSlug, buildAliasSlugs, uniqueArray } = require('../utils/strings');
const { computeFamilySlug, computeVariantKey, reserveAliasesTransaction } = require('../utils/aliases');
const admin = require('firebase-admin');
const { logger } = require('firebase-functions');

const db = new FirestoreHelper();

// --- Lightweight normalizers (low-risk) ---
function _kebabToken(s) {
  return String(s || '').trim().toLowerCase().replace(/[_\s]+/g, '-');
}

function _uniqueArray(arr) {
  return Array.from(new Set((arr || []).filter(Boolean)));
}

function normalizeMovement(mv) {
  if (!mv || typeof mv !== 'object') return mv;
  const typeMap = {
    'hip hinge': 'hinge',
    hinge: 'hinge',
    push: 'push',
    pull: 'pull',
    squat: 'squat',
    carry: 'carry',
    rotate: 'rotate',
    rotation: 'rotate',
    power: 'power',
    explosive: 'power',
    accessory: 'accessory',
    other: 'other',
  };
  const splitMap = {
    upper: 'upper',
    lower: 'lower',
    'lower-body': 'lower',
    lower_body: 'lower',
    full: 'full',
    'full-body': 'full',
    full_body: 'full',
  };
  const out = { ...mv };
  if (mv.type) {
    const key = String(mv.type).trim().toLowerCase();
    out.type = typeMap[key] || key;
  }
  if (mv.split) {
    const key = String(mv.split).trim().toLowerCase();
    out.split = splitMap[key] || key;
  }
  return out;
}

function normalizeMetadata(md) {
  if (!md || typeof md !== 'object') return md;
  const levelMap = { beginner: 'beginner', intermediate: 'intermediate', advanced: 'advanced' };
  const planeMap = { sagittal: 'sagittal', frontal: 'frontal', transverse: 'transverse' };
  const out = { ...md };
  if (md.level) {
    const k = String(md.level).trim().toLowerCase();
    out.level = levelMap[k] || k;
  }
  if (md.plane_of_motion) {
    const p = String(md.plane_of_motion).trim().toLowerCase();
    out.plane_of_motion = planeMap[p] || p;
  }
  if (typeof md.unilateral !== 'undefined') {
    out.unilateral = Boolean(md.unilateral);
  }
  return out;
}

function normalizeEquipment(eq) {
  if (!Array.isArray(eq)) return eq;
  return _uniqueArray(eq.map(_kebabToken));
}

function normalizeStimulusTags(tags) {
  if (!Array.isArray(tags)) return tags;
  return _uniqueArray(tags.map(t => String(t || '').trim().toLowerCase()).filter(Boolean));
}

function normalizeMuscles(muscles) {
  if (!muscles || typeof muscles !== 'object') return muscles;
  const out = { ...muscles };
  // category: array of strings only
  if (typeof muscles.category === 'string') {
    out.category = [muscles.category];
  } else if (muscles.category && !Array.isArray(muscles.category) && typeof muscles.category === 'object') {
    const vals = [];
    for (const k of Object.keys(muscles.category || {})) {
      const v = muscles.category[k];
      if (Array.isArray(v)) vals.push(...v);
      else if (typeof v === 'string') vals.push(v);
    }
    out.category = _uniqueArray(vals);
  }
  if (Array.isArray(muscles.category)) {
    out.category = _uniqueArray(muscles.category);
  }
  // contribution: map of muscle -> number in [0,1], sum to 1.0
  if (muscles.contribution && typeof muscles.contribution === 'object') {
    const raw = muscles.contribution;
    const keys = Object.keys(raw);
    let values = keys.map(k => Number(raw[k]));
    const anyGtOne = values.some(v => v > 1);
    if (anyGtOne) values = values.map(v => v / 100);
    let sum = values.reduce((a, b) => a + (isFinite(b) ? b : 0), 0);
    if (sum > 0) {
      const normalized = {};
      keys.forEach((k, i) => {
        const val = values[i] / sum;
        normalized[k] = Math.round(val * 1000) / 1000; // 3 decimals
      });
      out.contribution = normalized;
    }
  }
  return out;
}

function normalizeDoc(doc) {
  const d = { ...doc };
  if (d.movement) d.movement = normalizeMovement(d.movement);
  if (d.metadata) d.metadata = normalizeMetadata(d.metadata);
  if (d.equipment) d.equipment = normalizeEquipment(d.equipment);
  if (d.stimulus_tags) d.stimulus_tags = normalizeStimulusTags(d.stimulus_tags);
  if (d.muscles) d.muscles = normalizeMuscles(d.muscles);
  if (d.category && typeof d.category === 'string') d.category = String(d.category).trim().toLowerCase();
  return d;
}

async function findExistingBySlugOrAliases(canonicalSlug, aliasSlugs) {
  // Try name_slug exact
  const byName = await db.getDocuments('exercises', { where: [{ field: 'name_slug', operator: '==', value: canonicalSlug }], limit: 1 });
  if (byName && byName.length) return byName[0];
  // Try alias_slugs contains any
  const arr = uniqueArray([canonicalSlug, ...(aliasSlugs || [])]).slice(0, 10);
  if (!arr.length) return null;
  const byAlias = await db.getDocuments('exercises', { where: [{ field: 'alias_slugs', operator: 'array-contains-any', value: arr }], limit: 1 });
  if (byAlias && byAlias.length) return byAlias[0];
  return null;
}

async function upsertExerciseHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return fail(res, 'METHOD_NOT_ALLOWED', 'Method Not Allowed', null, 405);
    }
    const userId = req.user?.uid || req.auth?.uid || 'service';

    const { exercise, mode } = req.body || {};
    const parsed = ExerciseUpsertSchema.safeParse({ ...exercise });
    if (!parsed.success) {
      return fail(res, 'INVALID_ARGUMENT', 'Invalid exercise payload', null, 400);
    }
    const ex = parsed.data;

    const canonicalSlug = toSlug(ex.name);
    const aliasSlugs = buildAliasSlugs(ex.name, ex.aliases) || [];

    // Determine if this is an update vs create
    let id = ex.id || null;
    let existing = null;
    if (!id) {
      existing = await findExistingBySlugOrAliases(canonicalSlug, aliasSlugs);
      if (existing) id = existing.id;
    }
    const isUpdate = Boolean(id);

    // Build data: include only provided fields on update; set defaults on create
    const data = {
      name: ex.name,
      name_slug: canonicalSlug,
      created_by: userId,
      _debug_project_id: process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'unknown',
    };

    if (Array.isArray(ex.aliases)) {
      data.aliases = uniqueArray(ex.aliases);
      data.alias_slugs = aliasSlugs;
    }

    if (isUpdate) {
      if (typeof ex.family_slug !== 'undefined') data.family_slug = ex.family_slug;
      if (typeof ex.variant_key !== 'undefined') data.variant_key = ex.variant_key;
      if (typeof ex.category !== 'undefined') data.category = ex.category;
      if (typeof ex.description === 'string') data.description = ex.description;
      if (typeof ex.metadata !== 'undefined') data.metadata = ex.metadata;
      if (typeof ex.movement !== 'undefined') data.movement = ex.movement;
      if (Array.isArray(ex.equipment)) data.equipment = ex.equipment;
      if (typeof ex.muscles !== 'undefined') data.muscles = ex.muscles;
      if (Array.isArray(ex.execution_notes)) data.execution_notes = ex.execution_notes;
      if (Array.isArray(ex.common_mistakes)) data.common_mistakes = ex.common_mistakes;
      if (Array.isArray(ex.programming_use_cases)) data.programming_use_cases = ex.programming_use_cases;
      if (Array.isArray(ex.stimulus_tags)) data.stimulus_tags = ex.stimulus_tags;
      if (Array.isArray(ex.suitability_notes)) data.suitability_notes = ex.suitability_notes;
      if (Array.isArray(ex.coaching_cues)) data.coaching_cues = ex.coaching_cues;
      if (typeof ex.status !== 'undefined') data.status = ex.status;
      if (typeof ex.version !== 'undefined') data.version = ex.version;
    } else {
      // Create: compute family/variant and set safe defaults
      const familySlug = ex.family_slug || computeFamilySlug(ex.name);
      const variantKey = ex.variant_key || computeVariantKey(ex);
      data.family_slug = familySlug;
      data.variant_key = variantKey;
      data.category = ex.category || 'general';
      data.description = typeof ex.description === 'string' ? ex.description : undefined;
      data.metadata = ex.metadata || { level: 'beginner' };
      data.movement = ex.movement || { type: 'other' };
      data.equipment = Array.isArray(ex.equipment) ? ex.equipment : [];
      data.muscles = ex.muscles || { primary: [], secondary: [] };
      data.execution_notes = ex.execution_notes || [];
      data.common_mistakes = ex.common_mistakes || [];
      data.programming_use_cases = ex.programming_use_cases || [];
      data.stimulus_tags = ex.stimulus_tags || [];
      data.suitability_notes = ex.suitability_notes || [];
      data.coaching_cues = Array.isArray(ex.coaching_cues) ? ex.coaching_cues : undefined;
      data.status = ex.status || 'draft';
      data.version = Number.isInteger(ex.version) ? ex.version : 1;
    }

    // Optional content fields (only include if provided to avoid undefined writes)
    if (typeof ex.description === 'string' && ex.description.length) {
      data.description = ex.description;
    }
    if (Array.isArray(ex.coaching_cues)) {
      data.coaching_cues = ex.coaching_cues;
    }

    if ((mode === 'update' && id) || id) {
      // Resolve canonical target if this id has been merged into another
      const current = await db.getDocument('exercises', id);
      const targetId = current?.merged_into || id;
      // Upsert semantics: create if missing, merge if exists
      const normalized = normalizeDoc({ ...data, id: targetId });
      await db.upsertDocument('exercises', targetId, normalized);
      id = targetId;
    } else {
      const normalized = normalizeDoc(data);
      id = await db.addDocument('exercises', normalized);
    }

    // Reserve aliases atomically (id already mirrored above for upsert path)
    try {
      const toReserve = uniqueArray([canonicalSlug, ...aliasSlugs]);
      await reserveAliasesTransaction(db.db, toReserve, id, data.family_slug || familySlug);
    } catch (e) {
      if (String(e.message || '').startsWith('ALIAS_CONFLICT:')) {
        console.warn('Alias conflict during upsert; proceeding without alias reservation:', e.message);
        return ok(res, { exercise_id: id, version: data.version, status: data.status || 'draft', name_slug: canonicalSlug, family_slug: data.family_slug || familySlug, variant_key: data.variant_key || variantKey, alias_conflict: true });
      }
      throw e;
    }

    return ok(res, { exercise_id: id, version: data.version, status: data.status || 'draft', name_slug: canonicalSlug, family_slug: data.family_slug || familySlug, variant_key: data.variant_key || variantKey });
  } catch (error) {
    logger.error('[upsertExercise] Failed', { error: error.message });
    return fail(res, 'INTERNAL', 'Failed to upsert exercise', null, 500);
  }
}

exports.upsertExercise = onRequest(requireFlexibleAuth(upsertExerciseHandler));


