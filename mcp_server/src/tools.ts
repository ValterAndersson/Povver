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

export function registerTools(server: McpServer, userId: string) {
  // Read tools
  server.tool('get_training_snapshot', 'Get user training snapshot', {},
    async () => {
      const ctx = await planningContext.getPlanningContext(db, userId);
      return { content: [{ type: 'text' as const, text: JSON.stringify(ctx, null, 2) }] };
    }
  );

  server.tool('list_routines', 'List all routines', {},
    async () => {
      const items = await routines.listRoutines(db, userId);
      return { content: [{ type: 'text' as const, text: JSON.stringify(items, null, 2) }] };
    }
  );

  server.tool('get_routine', 'Get a specific routine', {
    routine_id: z.string().describe('Routine ID')
  }, async ({ routine_id }) => {
    const routine = await routines.getRoutine(db, userId, routine_id);
    return { content: [{ type: 'text' as const, text: JSON.stringify(routine, null, 2) }] };
  });

  // --- Templates ---
  server.tool('list_templates', 'List all workout templates', {},
    async () => {
      const items = await templates.listTemplates(db, userId);
      return { content: [{ type: 'text' as const, text: JSON.stringify(items, null, 2) }] };
    }
  );

  server.tool('get_template', 'Get a specific template', {
    template_id: z.string().describe('Template ID')
  }, async ({ template_id }) => {
    const tmpl = await templates.getTemplate(db, userId, template_id);
    return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
  });

  // --- Workouts ---
  server.tool('list_workouts', 'List recent workouts', {
    limit: z.number().default(20).describe('Max results (default 20)')
  }, async ({ limit }) => {
    const items = await workouts.listWorkouts(db, userId, { limit: limit || 20 });
    return { content: [{ type: 'text' as const, text: JSON.stringify(items, null, 2) }] };
  });

  server.tool('get_workout', 'Get a specific workout', {
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
    const result = await exercises.searchExercises(db, { query, limit: limit || 10 });
    return { content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }] };
  });

  // --- Training Analysis ---
  server.tool('get_training_analysis', 'Get training analysis insights', {
    sections: z.array(z.string()).optional().describe('Sections to include')
  }, async ({ sections }) => {
    const analysis = await trainingQueries.getAnalysisSummary(db, userId, { sections }, admin);
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
    target: z.record(z.string(), z.any()).describe('Target filter (exercise, muscle_group, or muscle)'),
    limit: z.number().default(50).describe('Max results')
  }, async ({ target, limit }) => {
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
    exercises: z.array(z.any()).describe('Exercise list with sets')
  }, async (args) => {
    const tmpl = await templates.createTemplate(db, userId, args);
    return { content: [{ type: 'text' as const, text: JSON.stringify(tmpl, null, 2) }] };
  });

  server.tool('update_template', 'Update an existing template', {
    template_id: z.string().describe('Template ID'),
    updates: z.record(z.string(), z.any()).describe('Fields to update')
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
