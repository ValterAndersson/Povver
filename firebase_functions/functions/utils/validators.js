const { z } = require('zod');

// Security upper bounds — prevent data corruption and DoS
const MAX_WEIGHT_KG = 1500;              // Ronnie Coleman leg-pressed 2300lbs (~1043kg). Lightweight baby!
const MAX_REPS = 500;                    // Reasonable upper bound for bodyweight exercises
const MAX_EXERCISES_PER_WORKOUT = 50;
const MAX_SETS_PER_EXERCISE = 100;
const MAX_NAME_LENGTH = 200;
const MAX_NOTES_LENGTH = 5000;

// Shared schemas
const IdSchema = z.string().min(1);

const PreferencesSchema = z.object({
  timezone: z.string().optional(),
  weight_format: z.enum(['kilograms','pounds']).optional(),
  height_format: z.enum(['centimeter','feet']).optional(),
  week_starts_on_monday: z.boolean().optional(),
  locale: z.string().optional(),
});

const PlanSchema = z.object({
  blocks: z.array(z.object({
    exercise_id: IdSchema,
    sets: z.array(z.object({
      target: z.object({ reps: z.number().int().min(1).max(MAX_REPS), rir: z.number().int().min(0).max(5), weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable().optional(), tempo: z.string().optional(), rest_sec: z.number().int().optional() })
    })).max(MAX_SETS_PER_EXERCISE),
    alts: z.array(z.object({ exercise_id: IdSchema, reason: z.string().max(MAX_NOTES_LENGTH).optional() })).optional()
  })).max(MAX_EXERCISES_PER_WORKOUT)
});

const PrescribeSchema = z.object({
  workout_id: IdSchema,
  exercise_id: IdSchema,
  set_index: z.number().int().min(0),
  context: z.any().optional()
});

/**
 * LogSetSchemaV2 - Per FOCUS_MODE_WORKOUT_EXECUTION.md spec
 * Uses stable IDs (exercise_instance_id + set_id) instead of position-based (exercise_id + set_index)
 * 
 * Validation rules:
 * - reps: 0-30 (0 requires is_failure=true)
 * - rir: 0-5
 * - weight: >= 0 or null (null for bodyweight)
 */
const LogSetSchemaV2 = z.object({
  workout_id: IdSchema,
  exercise_instance_id: IdSchema,           // Workout-local stable ID (UUID)
  set_id: IdSchema,                          // Stable set ID (UUID)
  values: z.object({
    weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable(), // kg, null for bodyweight
    reps: z.number().int().min(0).max(30),       // 0-30 (0 requires is_failure)
    rir: z.number().int().min(0).max(5),         // Reps In Reserve
  }),
  is_failure: z.boolean().optional(),            // Required if reps=0
  idempotency_key: IdSchema,                     // Required for idempotency
  client_timestamp: z.string().optional(),       // ISO 8601 timestamp
}).refine(
  (data) => {
    // If reps is 0, is_failure must be true
    if (data.values.reps === 0 && data.is_failure !== true) {
      return false;
    }
    return true;
  },
  { message: 'reps=0 requires is_failure=true' }
);

const ScoreSetSchema = z.object({ actual: z.object({ reps: z.number().int().min(0).max(MAX_REPS), rir: z.number().int().min(0).max(5), weight: z.number().nonnegative().max(MAX_WEIGHT_KG).optional() }) });

/**
 * PatchActiveWorkoutSchema - Per FOCUS_MODE_WORKOUT_EXECUTION.md spec
 * 
 * Supports:
 * - set_field: Update a single field on a set
 * - add_set: Add a new set to an exercise
 * - remove_set: Remove a set from an exercise
 * 
 * Homogeneous constraint: 
 * - Only one op type per request
 * - set_field ops must target same set
 */
const PatchOpSchema = z.discriminatedUnion('op', [
  // Field update on a set
  z.object({
    op: z.literal('set_field'),
    target: z.object({
      exercise_instance_id: IdSchema,
      set_id: IdSchema,
    }),
    field: z.enum(['weight', 'reps', 'rir', 'status', 'set_type', 'tags.is_failure']),
    value: z.any(),
  }),
  // Field update on the workout itself (name, start_time, notes)
  z.object({
    op: z.literal('set_workout_field'),
    field: z.enum(['name', 'start_time', 'notes']),
    value: z.string().max(MAX_NOTES_LENGTH),
  }),
  // Field update on an exercise instance (notes, etc.)
  z.object({
    op: z.literal('set_exercise_field'),
    target: z.object({ exercise_instance_id: IdSchema }),
    field: z.enum(['notes']),
    value: z.string().max(MAX_NOTES_LENGTH),
  }),
  // Add set
  z.object({
    op: z.literal('add_set'),
    target: z.object({
      exercise_instance_id: IdSchema,
    }),
    value: z.object({
      id: IdSchema,                                      // Client-generated UUID (required)
      set_type: z.enum(['warmup', 'working', 'dropset']),
      reps: z.number().int().min(1).max(30),             // 1-30 for planned sets
      rir: z.number().int().min(0).max(5),
      weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable().optional(),  // Optional, defaults to null
      status: z.literal('planned'),                       // Must be 'planned'
      tags: z.object({}).optional(),
    }),
  }),
  // Remove set
  z.object({
    op: z.literal('remove_set'),
    target: z.object({
      exercise_instance_id: IdSchema,
      set_id: IdSchema,
    }),
  }),
  // Remove exercise
  z.object({
    op: z.literal('remove_exercise'),
    target: z.object({
      exercise_instance_id: IdSchema,
    }),
  }),
  // Reorder exercises
  z.object({
    op: z.literal('reorder_exercises'),
    value: z.object({
      order: z.array(IdSchema).min(1).max(MAX_EXERCISES_PER_WORKOUT),  // Array of exercise instance IDs in new order
    }),
  }),
]);

const PatchActiveWorkoutSchema = z.object({
  workout_id: IdSchema,
  ops: z.array(PatchOpSchema).min(1).max(100), // Reasonable upper bound for batch operations
  cause: z.enum(['user_edit', 'user_ai_action']),
  ui_source: z.string().max(MAX_NAME_LENGTH),
  idempotency_key: IdSchema,
  client_timestamp: z.string().optional(),
  ai_scope: z.object({
    exercise_instance_id: IdSchema,
  }).optional(), // Required when cause is 'user_ai_action'
}).refine(
  (data) => {
    // If cause is 'user_ai_action', ai_scope is required
    if (data.cause === 'user_ai_action' && !data.ai_scope) {
      return false;
    }
    return true;
  },
  { message: 'ai_scope is required when cause is user_ai_action' }
);

/**
 * AutofillExerciseSchema - Per FOCUS_MODE_WORKOUT_EXECUTION.md spec
 * AI bulk prescription for a single exercise
 */
const AutofillExerciseSchema = z.object({
  workout_id: IdSchema,
  exercise_instance_id: IdSchema,
  updates: z.array(z.object({
    set_id: IdSchema,
    weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable().optional(),
    reps: z.number().int().min(1).max(30).optional(),
    rir: z.number().int().min(0).max(5).optional(),
  })).max(MAX_SETS_PER_EXERCISE).optional(),
  additions: z.array(z.object({
    id: IdSchema,
    set_type: z.enum(['working', 'dropset']),
    reps: z.number().int().min(1).max(30),
    rir: z.number().int().min(0).max(5),
    weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable(),
  })).max(MAX_SETS_PER_EXERCISE).optional(),
  idempotency_key: IdSchema,
  client_timestamp: z.string().optional(),
});

module.exports = {
  IdSchema,
  PreferencesSchema,
  PlanSchema,
  PrescribeSchema,
  LogSetSchemaV2,
  ScoreSetSchema,
  PatchOpSchema,
  PatchActiveWorkoutSchema,
  AutofillExerciseSchema,
};

// Template & Routine schemas (minimal)
// Note: weight is nullable to support bodyweight exercises and unset values
// Analytics treats null weight as non-load-bearing (zero volume contribution)
const TemplateSetSchema = z.object({
  id: z.string().optional(),
  reps: z.number().int().min(0).max(MAX_REPS),
  rir: z.number().int().min(0).max(5),
  type: z.string().max(MAX_NAME_LENGTH).default('Working Set'),
  weight: z.number().nonnegative().max(MAX_WEIGHT_KG).nullable(),
  duration: z.number().int().optional(),
});

const TemplateExerciseSchema = z.object({
  id: z.string().optional(),
  exercise_id: IdSchema.optional(), // server uses exerciseId sometimes; keep minimal
  exerciseId: IdSchema.optional(),   // backward compat
  position: z.number().int().nonnegative().optional(),
  sets: z.array(TemplateSetSchema).min(0).max(MAX_SETS_PER_EXERCISE),
  rest_between_sets: z.number().int().optional(),
});

const TemplateSchema = z.object({
  name: z.string().min(1).max(MAX_NAME_LENGTH),
  description: z.string().max(MAX_NOTES_LENGTH).optional(),
  exercises: z.array(TemplateExerciseSchema).min(1).max(MAX_EXERCISES_PER_WORKOUT),
});

const RoutineSchema = z.object({
  name: z.string().min(1).max(MAX_NAME_LENGTH),
  description: z.string().max(MAX_NOTES_LENGTH).optional(),
  // Support both snake_case and camelCase for backward compat
  template_ids: z.array(z.string().min(1)).max(50).optional(), // Reasonable upper bound for templates in a routine
  templateIds: z.array(z.string().min(1)).max(50).optional(),
  frequency: z.number().int().min(1).max(7).optional(),
  days: z.array(z.any()).max(7).optional(),  // Legacy field
});

module.exports.TemplateSchema = TemplateSchema;
module.exports.RoutineSchema = RoutineSchema;

// Exercises
const ExerciseUpsertSchema = z.object({
  id: z.string().optional(),
  name: z.string().min(1).max(MAX_NAME_LENGTH),
  family_slug: z.string().max(MAX_NAME_LENGTH).optional(),
  variant_key: z.string().max(MAX_NAME_LENGTH).optional(),
  category: z.string().max(MAX_NAME_LENGTH).optional(),
  description: z.string().max(MAX_NOTES_LENGTH).optional(),
  metadata: z.object({
    level: z.string().max(MAX_NAME_LENGTH).optional(),
    plane_of_motion: z.string().max(MAX_NAME_LENGTH).optional(),
    unilateral: z.boolean().optional(),
  }).optional(),
  movement: z.object({
    split: z.string().max(MAX_NAME_LENGTH).optional(),
    type: z.string().max(MAX_NAME_LENGTH).optional(),
  }).optional(),
  equipment: z.array(z.string().max(MAX_NAME_LENGTH)).max(20).optional(),
  muscles: z.object({
    primary: z.array(z.string().max(MAX_NAME_LENGTH)).max(10).optional(),
    secondary: z.array(z.string().max(MAX_NAME_LENGTH)).max(10).optional(),
    category: z.array(z.string().max(MAX_NAME_LENGTH)).max(10).optional(),
    contribution: z.record(z.string(), z.number()).optional(),
  }).optional(),
  execution_notes: z.array(z.string().max(MAX_NOTES_LENGTH)).max(50).optional(),
  common_mistakes: z.array(z.string().max(MAX_NOTES_LENGTH)).max(50).optional(),
  programming_use_cases: z.array(z.string().max(MAX_NOTES_LENGTH)).max(50).optional(),
  stimulus_tags: z.array(z.string().max(MAX_NAME_LENGTH)).max(50).optional(),
  suitability_notes: z.array(z.string().max(MAX_NOTES_LENGTH)).max(50).optional(),
  coaching_cues: z.array(z.string().max(MAX_NOTES_LENGTH)).max(50).optional(),
  status: z.enum(['draft','approved']).optional(),
  version: z.number().int().optional(),
  aliases: z.array(z.string().max(MAX_NAME_LENGTH)).max(20).optional(),
});

module.exports.ExerciseUpsertSchema = ExerciseUpsertSchema;
