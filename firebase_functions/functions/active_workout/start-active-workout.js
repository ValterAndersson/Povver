/**
 * =============================================================================
 * start-active-workout.js - Begin Live Workout Session
 * =============================================================================
 *
 * PURPOSE:
 * Creates a new active_workout document when user starts exercising.
 * This is the ENTRY POINT for the live workout execution flow.
 *
 * SINGLE ACTIVE WORKOUT MODEL:
 * Only one in_progress workout is allowed per user at a time.
 * Uses a lock document (users/{uid}/meta/active_workout_state) to enforce this
 * atomically and prevent race conditions from concurrent requests.
 *
 * SEED SOURCES:
 * 1. Empty workout - no template or plan, exercises added during workout
 * 2. Template seed - template_id provided, exercises populated from template
 * 3. Plan seed - plan.blocks provided, exercises populated from plan
 * 4. Direct exercises - exercises array provided (for testing)
 *
 * ACTIVE WORKOUT LIFECYCLE:
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │ 1. START (this file)                                                   │
 * │    User taps "Start Workout" → Creates active_workout doc              │
 * │    Status: in_progress, exercises: [] or seeded from template/plan    │
 * │                                                                         │
 * │ 2. LOG SETS (log-set.js)                                               │
 * │    User completes sets → Updates exercises[], updates totals           │
 * │                                                                         │
 * │ 3. COMPLETE (complete-active-workout.js)                               │
 * │    User finishes workout → Archives to workouts collection             │
 * │    Status: completed, clears lock, triggers routine cursor update      │
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * FIRESTORE WRITES:
 * - Creates: users/{uid}/active_workouts/{workoutId}
 * - Updates: users/{uid}/meta/active_workout_state (lock document)
 *
 * RESPONSE SHAPE (always consistent):
 * {
 *   success: true,
 *   workout_id: string,
 *   workout: { ... full workout doc ... },
 *   resumed: boolean
 * }
 *
 * CALLED BY:
 * - iOS: FocusModeWorkoutService.startWorkout()
 * - iOS: CanvasScreen "Start Workout" from session_plan card
 *
 * RELATED FILES:
 * - ../utils/workout-seed-mapper.js: Template/plan to exercises transformation
 * - get-active-workout.js: Returns current active workout
 * - cancel-active-workout.js: Cancels workout and clears lock
 * - complete-active-workout.js: Archives workout and clears lock
 *
 * =============================================================================
 */

const { onRequest } = require('firebase-functions/v2/https');
const { requireFlexibleAuth } = require('../auth/middleware');
const { ok, fail } = require('../utils/response');
const admin = require('firebase-admin');
const { v4: uuidv4 } = require('uuid');
const { templateToExercises, planBlocksToExercises, normalizePlan } = require('../utils/workout-seed-mapper');
const { writeLimiter } = require('../utils/rate-limiter');

const firestore = admin.firestore();

async function startActiveWorkoutHandler(req, res) {
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ success: false, error: 'Method Not Allowed' });
    }

    // User ID from Firebase Auth or API key middleware
    const userId = req.user?.uid || req.auth?.uid;
    if (!userId) return fail(res, 'UNAUTHENTICATED', 'Unauthorized', null, 401);

    if (!writeLimiter.check(userId)) {
      return fail(res, 'RATE_LIMITED', 'Too many requests', null, 429);
    }

    // ==========================================================================
    // NORMALIZE REQUEST KEYS (accept both variants for backward compatibility)
    // ==========================================================================
    const templateId = req.body?.template_id ?? req.body?.source_template_id ?? null;
    const sourceRoutineId = req.body?.source_routine_id ?? req.body?.routine_id ?? null;
    const forceNew = req.body?.force_new === true;
    
    let plan = req.body?.plan ?? null;
    const name = req.body?.name ?? null;
    let exercises = req.body?.exercises ?? [];

    // ==========================================================================
    // SEED EXERCISES FROM TEMPLATE OR PLAN (before transaction to avoid reads inside)
    // ==========================================================================
    if (exercises.length === 0 && templateId) {
      console.log(`Seeding exercises from template ${templateId}`);
      exercises = await templateToExercises(userId, templateId);
    }
    
    if (exercises.length === 0 && plan?.blocks) {
      console.log(`Seeding exercises from plan with ${plan.blocks.length} blocks`);
      exercises = await planBlocksToExercises(plan.blocks);
    }

    // Normalize plan shape for storage (unwrap target wrapper, validate values)
    if (plan) {
      plan = normalizePlan(plan);
    }

    // ==========================================================================
    // LOCK-BASED SINGLE WORKOUT ENFORCEMENT (transactional)
    // ==========================================================================
    const lockRef = firestore.collection('users').doc(userId).collection('meta').doc('active_workout_state');
    const activeWorkoutsRef = firestore.collection('users').doc(userId).collection('active_workouts');

    const result = await firestore.runTransaction(async (tx) => {
      // Read lock document
      const lockDoc = await tx.get(lockRef);
      const lockData = lockDoc.exists ? lockDoc.data() : { active_workout_id: null };

      // Check for existing in_progress workout
      if (lockData.active_workout_id) {
        const existingRef = activeWorkoutsRef.doc(lockData.active_workout_id);
        const existingDoc = await tx.get(existingRef);

        // Missing doc recovery: if lock points to non-existent doc, clear and proceed
        if (!existingDoc.exists) {
          console.log(`Lock pointed to missing workout ${lockData.active_workout_id}, clearing`);
          // Will be overwritten below when we create new workout
        } else if (existingDoc.data().status === 'in_progress') {
          // Auto-cancel stale workouts (> 6 hours old)
          const STALE_MS = 6 * 60 * 60 * 1000;
          const startTime = existingDoc.data().start_time;
          const startMs = startTime?.toMillis ? startTime.toMillis() : (startTime ? new Date(startTime).getTime() : 0);
          const isStale = startMs > 0 && (Date.now() - startMs > STALE_MS);

          if (isStale) {
            console.log(`Auto-cancelling stale workout ${existingDoc.id} (age: ${Math.round((Date.now() - startMs) / 3600000)}h)`);
            tx.update(existingRef, {
              status: 'cancelled',
              end_time: admin.firestore.FieldValue.serverTimestamp(),
              updated_at: admin.firestore.FieldValue.serverTimestamp(),
            });
            // Fall through to create new workout
          } else if (!forceNew) {
            // Return existing workout (resume)
            const existingWorkout = { id: existingDoc.id, ...existingDoc.data() };
            console.log(`Returning existing in_progress workout ${existingDoc.id}`);
            return {
              success: true,
              workout_id: existingDoc.id,
              workout: existingWorkout,
              resumed: true
            };
          } else {
            // force_new=true: cancel existing before creating new
            console.log(`force_new=true, cancelling existing workout ${existingDoc.id}`);
            tx.update(existingRef, {
              status: 'cancelled',
              updated_at: admin.firestore.FieldValue.serverTimestamp()
            });
          }
        }
        // If doc exists but status != in_progress, just proceed to create new
      }

      // ==========================================================================
      // CREATE NEW WORKOUT
      // ==========================================================================
      const newWorkoutRef = activeWorkoutsRef.doc();
      const newWorkoutId = newWorkoutRef.id;
      const now = new Date();

      const workoutDoc = {
        id: newWorkoutId,  // Keep id in doc for Focus Mode model compatibility
        user_id: userId,
        name: name || null,
        status: 'in_progress',
        source_template_id: templateId,
        source_routine_id: sourceRoutineId,
        notes: null,
        plan: plan || null,
        current: null,
        exercises: exercises,
        totals: { sets: 0, reps: 0, volume: 0, stimulus_score: 0 },
        version: 1,
        start_time: now,
        end_time: null,
        created_at: now,
        updated_at: now
      };

      tx.set(newWorkoutRef, workoutDoc);

      // Update lock document to point to new workout
      tx.set(lockRef, {
        active_workout_id: newWorkoutId,
        status: 'in_progress',
        updated_at: now
      });

      console.log(`Created new workout ${newWorkoutId} with ${exercises.length} exercises`);

      return {
        success: true,
        workout_id: newWorkoutId,
        workout: workoutDoc,
        resumed: false
      };
    });

    return ok(res, result);
  } catch (error) {
    console.error('start-active-workout error:', error);
    return fail(res, 'INTERNAL', 'Failed to start active workout', { message: error.message }, 500);
  }
}

exports.startActiveWorkout = onRequest(
  { invoker: 'public' },
  requireFlexibleAuth(startActiveWorkoutHandler)
);
