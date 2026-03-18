// src/tools.ts
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import admin from 'firebase-admin';
import { createRequire } from 'module';

// Import shared business logic (copied into build context)
// Path is ../shared/ because this runs from dist/ after TypeScript compilation
// createRequire needed because shared modules are CommonJS, this module is ESM
const require = createRequire(import.meta.url);
const routines = require('../shared/routines');
const templates = require('../shared/templates');
const workouts = require('../shared/workouts');
const exercises = require('../shared/exercises');
const trainingQueries = require('../shared/training-queries');
const planningContext = require('../shared/planning-context');

const db = admin.firestore();

/** Compact a workout to summary-only (no set-level data) */
function summarizeWorkout(w: any) {
  const exercises = (w.exercises || []).map((ex: any) => ({
    name: ex.name,
    exercise_id: ex.exercise_id,
    sets: (ex.sets || []).length,
  }));
  return {
    id: w.id,
    end_time: w.end_time,
    source_template_id: w.source_template_id,
    name: w.name || null,
    exercises,
    analytics: w.analytics ? {
      total_sets: w.analytics.total_sets,
      total_reps: w.analytics.total_reps,
      total_volume: w.analytics.total_weight,
    } : null,
  };
}

/** Compact planning context to fit within MCP token limits */
function compactSnapshot(ctx: any) {
  return {
    user: ctx.user ? {
      id: ctx.user.id,
      name: ctx.user.name,
      weight_unit: ctx.weight_unit,
      attributes: ctx.user.attributes ? {
        fitness_level: ctx.user.attributes.fitness_level,
        fitness_goal: ctx.user.attributes.fitness_goal,
        weight_format: ctx.user.attributes.weight_format,
      } : null,
    } : null,
    activeRoutine: ctx.activeRoutine ? {
      id: ctx.activeRoutine.id,
      name: ctx.activeRoutine.name,
      template_ids: ctx.activeRoutine.template_ids,
      frequency: ctx.activeRoutine.frequency,
    } : null,
    nextWorkout: ctx.nextWorkout ? {
      templateId: ctx.nextWorkout.templateId,
      templateIndex: ctx.nextWorkout.templateIndex,
      templateCount: ctx.nextWorkout.templateCount,
      templateName: ctx.nextWorkout.template?.name || null,
    } : null,
    templates: (ctx.templates || []).map((t: any) => ({
      id: t.id,
      name: t.name,
      exerciseCount: t.exerciseCount || t.exercises?.length || 0,
    })),
    recentWorkouts: (ctx.recentWorkoutsSummary || []).slice(0, 10).map((w: any) => ({
      id: w.id,
      end_time: w.end_time,
      source_template_id: w.source_template_id,
      exercises: (w.exercises || []).map((ex: any) => ({
        name: ex.name,
        working_sets: ex.working_sets,
      })),
    })),
    strengthSummary: ctx.strengthSummary || [],
  };
}

export function registerTools(server: McpServer, userId: string) {
  // Read tools
  server.tool('get_training_snapshot', 'Get compact overview: user profile, active routine, next workout, recent workouts (summary), strength records', {},
    async () => {
      const ctx = await planningContext.getPlanningContext(db, userId, {
        includeTemplateExercises: false,
        workoutLimit: 10,
      });
      const compact = compactSnapshot(ctx);
      return { content: [{ type: 'text' as const, text: JSON.stringify(compact, null, 2) }] };
    }
  );

  server.tool('list_routines', 'List all routines', {},
    async () => {
      const items = await routines.listRoutines(db, userId);
      return { content: [{ type: 'text' as const, text: JSON.stringify(items, null, 2) }] };
    }
  );

  server.tool('get_routine', 'Get a specific routine with template IDs', {
    routine_id: z.string().describe('Routine ID')
  }, async ({ routine_id }) => {
    const routine = await routines.getRoutine(db, userId, routine_id);
    return { content: [{ type: 'text' as const, text: JSON.stringify(routine, null, 2) }] };
  });

  // --- Templates ---
  server.tool('list_templates', 'List all workout templates (names + IDs, no exercises). Use get_template for full exercise list.', {},
    async () => {
      const items = await templates.listTemplates(db, userId);
      const summaries = (items || []).map((t: any) => ({
        id: t.id,
        name: t.name,
        description: t.description,
        exercise_count: t.exercises?.length || 0,
        exercise_names: (t.exercises || []).map((e: any) => e.name),
      }));
      return { content: [{ type: 'text' as const, text: JSON.stringify(summaries, null, 2) }] };
    }
  );

  server.tool('get_template', 'Get a specific template with full exercise list', {
    template_id: z.string().describe('Template ID')
  }, async ({ template_id }) => {
    const tmpl = await templates.getTemplate(db, userId, template_id);
    return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
  });

  // --- Workouts ---
  server.tool('list_workouts', 'List recent workouts (summaries: date, exercises, set counts). Use get_workout for full set data.', {
    limit: z.number().default(10).describe('Max results (default 10)')
  }, async ({ limit }) => {
    const result = await workouts.listWorkouts(db, userId, { limit: limit || 10 });
    const summaries = (result.items || []).map(summarizeWorkout);
    return { content: [{ type: 'text' as const, text: JSON.stringify({
      workouts: summaries,
      analytics: result.analytics,
      hasMore: result.hasMore,
    }, null, 2) }] };
  });

  server.tool('get_workout', 'Get a specific workout with full exercise and set data', {
    workout_id: z.string().describe('Workout ID')
  }, async ({ workout_id }) => {
    const w = await workouts.getWorkout(db, userId, workout_id);
    return { content: [{ type: 'text' as const, text: JSON.stringify(w, null, 2) }] };
  });

  // --- Exercises ---
  server.tool('search_exercises', 'Search exercise catalog', {
    query: z.string().describe('Search query'),
    limit: z.number().default(10).describe('Max results')
  }, async ({ query, limit }) => {
    const result = await exercises.searchExercises(db, { query, limit: limit || 10, fields: 'lean' });
    return { content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }] };
  });

  // --- Training Analysis ---
  server.tool('get_training_analysis', 'Get training analysis insights', {
    sections: z.array(z.string()).optional().describe('Sections: insights, weekly_review, recommendation_history'),
    include_expired: z.boolean().default(false).describe('Include expired/applied recommendations')
  }, async ({ sections, include_expired }) => {
    const analysis = await trainingQueries.getAnalysisSummary(db, userId, { sections, include_expired }, admin);
    return { content: [{ type: 'text' as const, text: JSON.stringify(analysis, null, 2) }] };
  });

  server.tool('get_muscle_group_progress', 'Get muscle group progress over time', {
    group: z.string().describe('Muscle group name'),
    weeks: z.number().default(8).describe('Number of weeks')
  }, async ({ group, weeks }) => {
    const data = await trainingQueries.getMuscleGroupSummary(db, userId, { muscle_group: group, window_weeks: weeks || 8 });
    return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
  });

  server.tool('get_exercise_progress', 'Get exercise progress over time', {
    exercise: z.string().describe('Exercise name'),
    weeks: z.number().default(8).describe('Number of weeks')
  }, async ({ exercise, weeks }) => {
    const data = await trainingQueries.getExerciseSummary(db, userId, { exercise_name: exercise, window_weeks: weeks || 8 });
    return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
  });

  server.tool('query_sets', 'Query raw set-level training data', {
    exercise_name: z.string().optional().describe('Exercise name (fuzzy match)'),
    muscle_group: z.string().optional().describe('Muscle group (e.g., "chest", "back", "shoulders")'),
    muscle: z.string().optional().describe('Specific muscle (e.g., "posterior deltoid")'),
    exercise_ids: z.array(z.string()).optional().describe('Exercise IDs (max 10)'),
    limit: z.number().default(50).describe('Max results')
  }, async ({ exercise_name, muscle_group, muscle, exercise_ids, limit }) => {
    const target: Record<string, any> = {};
    if (exercise_name) target.exercise = exercise_name;
    if (muscle_group) target.muscle_group = muscle_group;
    if (muscle) target.muscle = muscle;
    if (exercise_ids) target.exercise_ids = exercise_ids;

    const data = await trainingQueries.querySets(db, userId, { target, limit: limit || 50 });
    return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
  });

  // --- Write Tools ---
  server.tool('create_routine', 'Create a new routine', {
    name: z.string().describe('Routine name'),
    template_ids: z.array(z.string()).describe('Template IDs'),
    frequency: z.number().optional().describe('Days per week')
  }, async (args) => {
    const routine = await routines.createRoutine(db, userId, args);
    return { content: [{ type: 'text' as const, text: JSON.stringify(routine, null, 2) }] };
  });

  server.tool('update_routine', 'Update an existing routine', {
    routine_id: z.string().describe('Routine ID'),
    updates: z.record(z.string(), z.any()).describe('Fields to update')
  }, async ({ routine_id, updates }) => {
    const routine = await routines.patchRoutine(db, userId, routine_id, updates);
    return { content: [{ type: 'text' as const, text: JSON.stringify(routine, null, 2) }] };
  });

  server.tool('create_template', 'Create a new workout template', {
    name: z.string().describe('Template name'),
    exercises: z.array(z.object({
      exercise_id: z.string().describe('Exercise ID from search_exercises'),
      name: z.string().optional().describe('Exercise name'),
      position: z.number().describe('Order in template (0-based)'),
      sets: z.array(z.object({
        type: z.enum(['warmup', 'working']).default('working'),
        reps: z.number().describe('Target reps'),
        weight: z.number().nullable().describe('Target weight (kg) or null for bodyweight'),
        rir: z.number().optional().describe('Reps in reserve (0-5)'),
      })),
    })).describe('Exercises with set prescriptions'),
  }, async (args) => {
    const tmpl = await templates.createTemplate(db, userId, args);
    return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
  });

  server.tool('update_template', 'Update an existing template', {
    template_id: z.string().describe('Template ID'),
    updates: z.object({
      name: z.string().optional(),
      description: z.string().optional(),
      exercises: z.array(z.object({
        exercise_id: z.string().describe('Exercise ID'),
        name: z.string().optional().describe('Exercise name'),
        position: z.number().describe('Order (0-based)'),
        sets: z.array(z.object({
          type: z.enum(['warmup', 'working']).default('working'),
          reps: z.number().describe('Target reps'),
          weight: z.number().nullable().describe('Target weight (kg)'),
          rir: z.number().optional().describe('Reps in reserve (0-5)'),
        })),
      })).optional(),
    }).describe('Fields to update'),
  }, async ({ template_id, updates }) => {
    const tmpl = await templates.patchTemplate(db, userId, template_id, updates);
    return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
  });

  // --- Memory (read-only via MCP) ---
  server.tool('list_memories', 'List agent memories about the user', {},
    async () => {
      const memSnap = await db.collection(`users/${userId}/agent_memory`)
        .where('active', '==', true)
        .orderBy('created_at', 'desc')
        .limit(50)
        .get();
      const memories = memSnap.docs.map((d: any) => ({ id: d.id, ...d.data() }));
      return { content: [{ type: 'text' as const, text: JSON.stringify(memories, null, 2) }] };
    }
  );
}
