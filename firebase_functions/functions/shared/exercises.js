/**
 * shared/exercises.js — Pure business logic for exercise operations.
 *
 * All functions accept a Firestore `db` instance (admin.firestore()) as the
 * first argument. They never touch HTTP req/res — callers handle that.
 *
 * Exercises are TOP-LEVEL documents (`exercises/{id}`), not user-scoped.
 */

const { toSlug } = require('../utils/strings');
const { ValidationError } = require('./errors');

// ---------------------------------------------------------------------------
// getExercise
// ---------------------------------------------------------------------------

/**
 * Retrieve a single exercise by id, slug, or name.
 * Follows merged_into redirects automatically.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {Object} opts
 * @param {string} [opts.exerciseId]
 * @param {string} [opts.name]
 * @param {string} [opts.slug]
 * @returns {Promise<Object|null>} exercise doc (with `redirected_from` if followed) or null
 */
async function getExercise(db, { exerciseId, name, slug } = {}) {
  if (!exerciseId && !name && !slug) {
    throw new ValidationError('Provide exerciseId or name or slug');
  }

  let exercise = null;
  const coll = db.collection('exercises');
  const aliasColl = db.collection('exercise_aliases');

  if (exerciseId) {
    const snap = await coll.doc(exerciseId).get();
    exercise = snap.exists ? { id: snap.id, ...snap.data() } : null;
  } else if (slug || name) {
    const s = slug ? String(slug) : toSlug(String(name));

    // 1. name_slug exact match
    const bySlug = await coll.where('name_slug', '==', s).limit(1).get();
    if (!bySlug.empty) {
      const doc = bySlug.docs[0];
      exercise = { id: doc.id, ...doc.data() };
    }

    // 2. alias_slugs array-contains
    if (!exercise) {
      const byAlias = await coll.where('alias_slugs', 'array-contains', s).limit(1).get();
      if (!byAlias.empty) {
        const doc = byAlias.docs[0];
        exercise = { id: doc.id, ...doc.data() };
      }
    }

    // 3. exercise_aliases registry fallback
    if (!exercise) {
      const aliasDoc = await aliasColl.doc(s).get();
      const mapped = aliasDoc.exists ? aliasDoc.data() : null;
      if (mapped?.exercise_id) {
        const snap = await coll.doc(mapped.exercise_id).get();
        if (snap.exists) exercise = { id: snap.id, ...snap.data() };
      }
    }
  }

  // Follow merged_into redirect
  if (exercise && exercise.merged_into) {
    const redirectedFrom = exercise.id;
    const snap = await coll.doc(exercise.merged_into).get();
    if (snap.exists) {
      return { id: snap.id, ...snap.data(), redirected_from: redirectedFrom };
    }
  }

  return exercise;
}

// ---------------------------------------------------------------------------
// listExercises
// ---------------------------------------------------------------------------

/**
 * List exercises with optional canonical-only filtering.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {Object} opts
 * @param {number} [opts.limit=200]
 * @param {boolean} [opts.canonicalOnly=true]
 * @param {boolean} [opts.includeMerged=false]
 * @returns {Promise<{items: Object[], count: number}>}
 */
async function listExercises(db, { limit = 200, canonicalOnly, includeMerged = false } = {}) {
  const resolvedCanonical = includeMerged ? false : (canonicalOnly !== false);

  const snap = await db.collection('exercises')
    .orderBy('name', 'asc')
    .limit(limit)
    .get();

  let items = snap.docs.map(d => ({ id: d.id, ...d.data() }));

  if (resolvedCanonical) {
    items = items.filter(ex => !ex?.merged_into && (ex?.status || '').toLowerCase() !== 'merged');
  }

  return { items, count: items.length };
}

// ---------------------------------------------------------------------------
// searchExercises
// ---------------------------------------------------------------------------

/**
 * Build Firestore where-clauses and in-memory filters from search params.
 * Firestore only allows ONE array-contains/array-contains-any per query,
 * so extra array filters are pushed to memoryFilters.
 *
 * @returns {{ where: Array, memoryFilters: Array }}
 */
function buildFilters({
  muscleGroup, equipment, difficulty, category, movementType,
  split, planeOfMotion, unilateral, primaryMuscle, secondaryMuscle,
  stimulusTag, programmingUseCase,
}) {
  const where = [];
  const memoryFilters = [];
  let hasArrayFilter = false;

  function addArrayFilter(field, value, isArray = false) {
    if (!hasArrayFilter) {
      hasArrayFilter = true;
      where.push({
        field,
        operator: isArray ? 'array-contains-any' : 'array-contains',
        value,
      });
    } else {
      memoryFilters.push({ field, value, isArray });
    }
  }

  if (muscleGroup) {
    const arr = String(muscleGroup).split(',').map(s => s.trim()).filter(Boolean).slice(0, 10);
    if (arr.length > 1) addArrayFilter('muscles.category', arr, true);
    else if (arr.length === 1) addArrayFilter('muscles.category', arr[0], false);
  }
  if (equipment) {
    const arr = String(equipment).split(',').map(s => s.trim()).filter(Boolean).slice(0, 10);
    if (arr.length > 1) addArrayFilter('equipment', arr, true);
    else if (arr.length === 1) addArrayFilter('equipment', arr[0], false);
  }
  if (difficulty) {
    where.push({ field: 'metadata.level', operator: '==', value: difficulty });
  }
  if (category) {
    where.push({ field: 'category', operator: '==', value: String(category) });
  }
  if (movementType) {
    where.push({ field: 'movement.type', operator: '==', value: String(movementType) });
  }
  if (split) {
    where.push({ field: 'movement.split', operator: '==', value: String(split) });
  }
  if (planeOfMotion) {
    where.push({ field: 'metadata.plane_of_motion', operator: '==', value: String(planeOfMotion) });
  }
  if (unilateral !== undefined) {
    const parsed = String(unilateral).toLowerCase();
    if (parsed === 'true' || parsed === 'false') {
      where.push({ field: 'metadata.unilateral', operator: '==', value: parsed === 'true' });
    }
  }
  if (primaryMuscle) {
    const arr = String(primaryMuscle).split(',').map(s => s.trim()).filter(Boolean).slice(0, 10);
    if (arr.length > 1) addArrayFilter('muscles.primary', arr, true);
    else if (arr.length === 1) addArrayFilter('muscles.primary', arr[0], false);
  }
  if (secondaryMuscle) {
    const arr = String(secondaryMuscle).split(',').map(s => s.trim()).filter(Boolean).slice(0, 10);
    if (arr.length > 1) addArrayFilter('muscles.secondary', arr, true);
    else if (arr.length === 1) addArrayFilter('muscles.secondary', arr[0], false);
  }
  if (stimulusTag) {
    const arr = String(stimulusTag).split(',').map(s => s.trim()).filter(Boolean).slice(0, 10);
    if (arr.length > 1) addArrayFilter('stimulus_tags', arr, true);
    else if (arr.length === 1) addArrayFilter('stimulus_tags', arr[0], false);
  }
  if (programmingUseCase) {
    const arr = String(programmingUseCase).split(',').map(s => s.trim()).filter(Boolean).slice(0, 10);
    if (arr.length > 1) addArrayFilter('programming_use_cases', arr, true);
    else if (arr.length === 1) addArrayFilter('programming_use_cases', arr[0], false);
  }

  return { where, memoryFilters };
}

/**
 * Apply text search filtering on an array of exercises.
 *
 * @param {Object[]} exercises
 * @param {string} query - raw search string
 * @returns {Object[]} filtered exercises
 */
function applyTextSearch(exercises, query) {
  if (!query) return exercises;

  const searchTerm = query.toLowerCase();

  // Strip common equipment prefixes for fuzzy matching.
  // Catalog uses "Name (Equipment)" but queries often use "Equipment Name".
  const equipmentPrefixes = /^(barbell|dumbbell|cable|machine|ez[- ]?bar|trap[- ]?bar|band|bodyweight|smith[- ]?machine|kettlebell)\s+/i;
  const strippedTerm = searchTerm.replace(equipmentPrefixes, '').trim();

  const queryWords = searchTerm.split(/\s+/).filter(w => w.length > 1);

  return exercises.filter(ex => {
    const name = (ex.name || '').toLowerCase();
    const cat = (ex.category || '').toLowerCase();
    const mt = (ex.movement?.type || '').toLowerCase();
    const eqText = Array.isArray(ex.equipment) ? ex.equipment.join(' ').toLowerCase() : '';
    const primary = Array.isArray(ex.muscles?.primary) ? ex.muscles.primary.map(m => m.toLowerCase()) : [];
    const secondary = Array.isArray(ex.muscles?.secondary) ? ex.muscles.secondary.map(m => m.toLowerCase()) : [];
    const groups = Array.isArray(ex.muscles?.category) ? ex.muscles.category.map(g => g.toLowerCase()) : [];
    const notes = Array.isArray(ex.execution_notes) ? ex.execution_notes.join(' ').toLowerCase() : '';
    const mistakes = Array.isArray(ex.common_mistakes) ? ex.common_mistakes.join(' ').toLowerCase() : '';
    const programming = Array.isArray(ex.programming_use_cases) ? ex.programming_use_cases.join(' ').toLowerCase() : '';
    const tags = Array.isArray(ex.stimulus_tags) ? ex.stimulus_tags.map(t => t.toLowerCase()) : [];
    const nameAndEquipment = name + ' ' + eqText;

    return (
      name.includes(searchTerm) ||
      (strippedTerm !== searchTerm && name.includes(strippedTerm)) ||
      (queryWords.length > 1 && queryWords.every(w => nameAndEquipment.includes(w))) ||
      cat.includes(searchTerm) ||
      mt.includes(searchTerm) ||
      eqText.includes(searchTerm) ||
      primary.some(m => m.includes(searchTerm)) ||
      secondary.some(m => m.includes(searchTerm)) ||
      groups.some(g => g.includes(searchTerm)) ||
      notes.includes(searchTerm) ||
      mistakes.includes(searchTerm) ||
      programming.includes(searchTerm) ||
      tags.some(t => t.includes(searchTerm))
    );
  });
}

/**
 * Apply in-memory array filters that couldn't be included in the Firestore query
 * (because Firestore allows only one array-contains/array-contains-any per query).
 *
 * @param {Object[]} exercises
 * @param {Array} memoryFilters - from buildFilters()
 * @returns {Object[]}
 */
function applyMemoryFilters(exercises, memoryFilters) {
  if (!memoryFilters || memoryFilters.length === 0) return exercises;

  return exercises.filter(ex => {
    return memoryFilters.every(filter => {
      const fieldParts = filter.field.split('.');
      let fieldValue = ex;
      for (const part of fieldParts) {
        fieldValue = fieldValue?.[part];
      }
      if (!Array.isArray(fieldValue)) return false;

      if (filter.isArray) {
        return filter.value.some(v => fieldValue.includes(v));
      } else {
        return fieldValue.includes(filter.value);
      }
    });
  });
}

/**
 * Filter out merged/source exercises.
 */
function filterCanonical(exercises) {
  return exercises.filter(ex => !ex?.merged_into && (ex?.status || '').toLowerCase() !== 'merged');
}

/**
 * Project exercise fields for output.
 *
 * @param {Object[]} exercises
 * @param {string} fieldsMode - "minimal", "lean", or "full"
 * @returns {Object[]}
 */
function projectFields(exercises, fieldsMode) {
  if (fieldsMode === 'minimal') {
    return exercises.map(ex => ({ id: ex.id, name: ex.name }));
  }
  if (fieldsMode === 'lean') {
    return exercises.map(ex => ({
      id: ex.id,
      name: ex.name,
      category: ex.category,
      equipment: Array.isArray(ex.equipment) ? ex.equipment.slice(0, 1) : [],
    }));
  }
  return exercises; // "full"
}

/**
 * Search exercises with structured filters, text search, and canonical filtering.
 * Does NOT handle caching — callers manage that.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {Object} params - all search/filter parameters
 * @returns {Promise<{items: Object[], count: number}>}
 */
async function searchExercises(db, params = {}) {
  const {
    query,
    category, movementType, split, equipment,
    muscleGroup, primaryMuscle, secondaryMuscle,
    difficulty, planeOfMotion, unilateral,
    stimulusTag, programmingUseCase,
    limit: rawLimit,
    includeMerged, canonicalOnly,
    fields,
  } = params;

  const { where, memoryFilters } = buildFilters({
    muscleGroup, equipment, difficulty, category, movementType,
    split, planeOfMotion, unilateral, primaryMuscle, secondaryMuscle,
    stimulusTag, programmingUseCase,
  });

  const parsedLimit = parseInt(rawLimit) || 50;
  const mergedFlag = String(includeMerged || '').toLowerCase() === 'true';
  const canonicalFlag = mergedFlag ? false : (String(canonicalOnly || 'true').toLowerCase() !== 'false');

  // Build Firestore query
  let ref = db.collection('exercises');
  for (const w of where) {
    ref = ref.where(w.field, w.operator, w.value);
  }

  let exercises;
  if (query) {
    // Text search needs full catalog scan (filtered or not)
    const fetchLimit = 2000;
    if (!where.length) {
      exercises = (await ref.orderBy('name', 'asc').limit(fetchLimit).get())
        .docs.map(d => ({ id: d.id, ...d.data() }));
    } else {
      exercises = (await ref.limit(fetchLimit).get())
        .docs.map(d => ({ id: d.id, ...d.data() }));
    }
  } else {
    exercises = (await ref.limit(parsedLimit).get())
      .docs.map(d => ({ id: d.id, ...d.data() }));
  }

  // Text search
  if (query) {
    exercises = applyTextSearch(exercises, query);
  }

  // In-memory array filters
  exercises = applyMemoryFilters(exercises, memoryFilters);

  // Canonical filtering
  if (canonicalFlag) {
    exercises = filterCanonical(exercises);
  }

  // Field projection
  const fieldsMode = String(fields || 'full').toLowerCase();
  const outputExercises = projectFields(exercises, fieldsMode);

  return {
    items: outputExercises,
    count: outputExercises.length,
    fieldsMode,
    canonicalOnly: canonicalFlag,
    includeMerged: mergedFlag,
    parsedLimit,
  };
}

// ---------------------------------------------------------------------------
// resolveExercise
// ---------------------------------------------------------------------------

/**
 * Score an exercise candidate for resolution ranking.
 */
function scoreCandidate(ex, context) {
  let score = 0;
  const eq = Array.isArray(ex.equipment) ? ex.equipment : [];
  const want = new Set((context?.available_equipment || []).map(String));
  if (eq.length === 0) score += 1; // bodyweight friendly
  if ([...want].some(w => eq.includes(w))) score += 2;
  if (ex.status === 'approved') score += 1;
  return score;
}

/**
 * Resolve a free-text exercise query to the best-matching exercise.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {Object} opts
 * @param {string} opts.q - search query
 * @param {Object} [opts.context] - e.g. { available_equipment: ['barbell'] }
 * @returns {Promise<{best: {id,name}|null, alternatives: {id,name}[]}>}
 */
async function resolveExercise(db, { q, context = {} } = {}) {
  if (!q) {
    throw new ValidationError('Missing q');
  }

  const slug = toSlug(String(q));
  const coll = db.collection('exercises');
  let candidates = [];

  const bySlug = await coll.where('name_slug', '==', slug).limit(5).get();
  for (const doc of bySlug.docs) {
    candidates.push({ id: doc.id, ...doc.data() });
  }

  const byAlias = await coll.where('alias_slugs', 'array-contains', slug).limit(5).get();
  for (const doc of byAlias.docs) {
    candidates.push({ id: doc.id, ...doc.data() });
  }

  // Deduplicate
  const map = new Map();
  for (const c of candidates) map.set(c.id, c);
  candidates = [...map.values()];

  // Rank
  const ranked = candidates
    .map(ex => ({ ex, s: scoreCandidate(ex, context) }))
    .sort((a, b) => b.s - a.s)
    .map(x => x.ex);

  const best = ranked[0] || null;
  return {
    best: best ? { id: best.id, name: best.name } : null,
    alternatives: ranked.slice(1).map(e => ({ id: e.id, name: e.name })),
  };
}

module.exports = {
  getExercise,
  listExercises,
  searchExercises,
  resolveExercise,
  // Exported for testing
  buildFilters,
  applyTextSearch,
  applyMemoryFilters,
  filterCanonical,
  projectFields,
  scoreCandidate,
};
