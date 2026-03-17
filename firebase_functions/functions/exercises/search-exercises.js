const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const admin = require('firebase-admin');
const crypto = require('crypto');
const { ok, fail } = require('../utils/response');
const { searchExercises } = require('../shared/exercises');

if (!admin.apps.length) {
  admin.initializeApp();
}

const firestore = admin.firestore();

// ============================================================================
// EXERCISE CACHE (3-day TTL)
// Memory cache for hot path, Firestore cache for persistence.
// Caching is a handler-level concern — shared/exercises.js is cache-unaware.
// ============================================================================
const EXERCISE_CACHE_TTL_MS = 3 * 24 * 60 * 60 * 1000; // 3 days
const MEMORY_CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes (function instance lifetime)

// In-memory cache (per function instance)
const memoryCache = new Map();

function getCacheKey(params) {
  const normalized = JSON.stringify(params, Object.keys(params).sort());
  return crypto.createHash('md5').update(normalized).digest('hex');
}

async function getCachedExercises(cacheKey) {
  // Layer 1: Memory cache (fastest)
  const memoryCached = memoryCache.get(cacheKey);
  if (memoryCached && Date.now() < memoryCached.expiresAt) {
    console.log('[ExerciseCache] Memory hit');
    return { data: memoryCached.data, source: 'memory' };
  }

  // Layer 2: Firestore cache
  try {
    const cacheDoc = await firestore.collection('cache').doc(`exercises_${cacheKey}`).get();
    if (cacheDoc.exists) {
      const cached = cacheDoc.data();
      const cachedAt = cached.cachedAt?.toMillis?.() || 0;
      const age = Date.now() - cachedAt;

      if (age < EXERCISE_CACHE_TTL_MS) {
        console.log('[ExerciseCache] Firestore hit', { age: Math.round(age / 1000) + 's' });
        // Warm memory cache
        memoryCache.set(cacheKey, {
          data: cached.data,
          expiresAt: Date.now() + MEMORY_CACHE_TTL_MS
        });
        return { data: cached.data, source: 'firestore' };
      }
    }
  } catch (e) {
    console.warn('[ExerciseCache] Firestore read error:', e.message);
  }

  return null; // Cache miss
}

async function setCachedExercises(cacheKey, data, queryParams) {
  // Set memory cache
  memoryCache.set(cacheKey, {
    data,
    expiresAt: Date.now() + MEMORY_CACHE_TTL_MS
  });

  // Set Firestore cache (async, don't await)
  firestore.collection('cache').doc(`exercises_${cacheKey}`).set({
    data,
    query: queryParams,
    cachedAt: admin.firestore.FieldValue.serverTimestamp(),
    itemCount: data.length
  }).catch(e => console.warn('[ExerciseCache] Firestore write error:', e.message));
}

/**
 * Firebase Function: Search Exercises (with caching)
 * Thin wrapper — business logic lives in shared/exercises.js.
 * This handler adds a two-layer cache (memory + Firestore) around the core search.
 */
async function searchExercisesHandler(req, res) {
  const {
    query,
    category, movementType, split, equipment,
    muscleGroup, primaryMuscle, secondaryMuscle,
    difficulty, planeOfMotion, unilateral,
    stimulusTag, programmingUseCase,
    limit, includeMerged, canonicalOnly,
    skipCache,
    fields,
  } = req.query || {};

  try {
    // Build cache key from query params
    const cacheParams = {
      version: 'v2',
      query, category, movementType, split, equipment, muscleGroup,
      primaryMuscle, secondaryMuscle, difficulty, planeOfMotion,
      unilateral, stimulusTag, programmingUseCase, limit,
      includeMerged, canonicalOnly
    };
    const cacheKey = getCacheKey(cacheParams);

    // Check cache first (unless skipCache=true)
    if (String(skipCache).toLowerCase() !== 'true') {
      const cached = await getCachedExercises(cacheKey);
      if (cached) {
        return ok(res, {
          items: cached.data,
          count: cached.data.length,
          source: cached.source,
          filters: cacheParams
        });
      }
    }
    console.log('[ExerciseCache] Cache miss, querying Firestore...');

    const result = await searchExercises(firestore, {
      query, category, movementType, split, equipment,
      muscleGroup, primaryMuscle, secondaryMuscle,
      difficulty, planeOfMotion, unilateral,
      stimulusTag, programmingUseCase,
      limit, includeMerged, canonicalOnly, fields,
    });

    // Cache the results for future requests (async, don't wait)
    setCachedExercises(cacheKey, result.items, cacheParams);
    console.log('[ExerciseCache] Cached results', { count: result.count });

    return ok(res, {
      items: result.items,
      count: result.count,
      source: 'fresh',
      fields: result.fieldsMode,
      filters: {
        query: query || null,
        category: category || null,
        muscleGroup: muscleGroup || null,
        primaryMuscle: primaryMuscle || null,
        secondaryMuscle: secondaryMuscle || null,
        equipment: equipment || null,
        difficulty: difficulty || null,
        planeOfMotion: planeOfMotion || null,
        unilateral: unilateral ?? null,
        movementType: movementType || null,
        split: split || null,
        stimulusTag: stimulusTag || null,
        programmingUseCase: programmingUseCase || null,
        limit: result.parsedLimit,
        canonicalOnly: result.canonicalOnly,
        includeMerged: result.includeMerged,
      },
    });

  } catch (error) {
    console.error('search-exercises function error:', error);
    return fail(res, 'INTERNAL', 'Failed to search exercises', { message: error.message }, 500);
  }
}

exports.searchExercises = onRequest(requireFlexibleAuth(searchExercisesHandler));
