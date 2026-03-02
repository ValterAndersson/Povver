# Training Analytics v2 — Module Architecture

Token-safe training analytics endpoints that provide bounded, paginated data for agent consumption. These endpoints prevent agent timeouts by enforcing response size caps.

See `docs/TRAINING_ANALYTICS_API_V2_SPEC.md` for the full specification.

## File Inventory

| File | Endpoints | Purpose |
|------|----------|---------|
| `set-facts-generator.js` | — (library) | Core set_facts computation: e1RM, hard set credit, muscle attribution |
| `query-sets.js` | `querySets`, `aggregateSets` | Paginated raw set queries with muscle/exercise filters (v2 onRequest + requireFlexibleAuth). When date range filters present, sorts by `workout_date` (not `workout_end_time`) to satisfy Firestore compound query constraints |
| `series-endpoints.js` | `getExerciseSeries`, `getMuscleGroupSeries`, `getMuscleSeries` | Weekly progression series (bounded to 52 weeks) |
| `progress-summary.js` | `getMuscleGroupSummary`, `getMuscleSummary`, `getExerciseSummary` | Comprehensive progress summaries with flags (plateau, deload, overreach) |
| `context-pack.js` | `getCoachingPack`, `getActiveSnapshotLite` | Single-call coaching context (<15KB) and minimal active workout state |
| `active-events.js` | `getActiveEvents` | Paginated workout event stream |
| `get-analysis-summary.js` | `getAnalysisSummary` | Consolidated retrieval of pre-computed training analysis (latest insights, weekly review). Supports `sections` filter, `date`, and `limit` params. Called by Shell Agent's `tool_get_training_analysis` via `app/shell/tools.py` |

## Data Model

- **Set facts** (`users/{uid}/set_facts/{id}`): One document per completed set with full attribution
- **Series** (`users/{uid}/analytics_series_exercise/{id}`, `analytics_series_muscle/{id}`): Weekly aggregated progression data
- **Rollups** (`users/{uid}/analytics_rollups/{week}`): Weekly totals

## Response Size Caps

| Endpoint | Max Response |
|----------|-------------|
| `querySets` | 32KB, 200 items |
| `series.*.get` | 10KB, 52 weeks |
| `progress.*.summary` | 15KB |
| `context.coaching.pack` | 15KB |
| `active.snapshotLite` | 2KB |

## `recommendation_history` Section

Added to `getAnalysisSummary` as a requestable section. Reads the last 30 days of `agent_recommendations` (limit 20, ordered by `created_at` desc).

Response shape per recommendation:
```
{
  id, created_at, state, scope, trigger,
  target: { exercise_name, template_name, muscle_group },
  recommendation: { type, summary, rationale, confidence, change_count },
  applied_at, applied_by
}
```

Empty results return `recommendation_history: []` (never null or omitted).

Consumers:
- Shell agent (`tool_get_training_analysis`): coaching context for recommendation-aware responses
- Workout brief (`workout_skills.py`): filtered to current workout exercises, capped at 3

## Cross-References

- Caps constants: `utils/caps.js`
- Muscle taxonomy: `utils/muscle-taxonomy.js`
- Agent tools: `adk_agent/canvas_orchestrator/app/shell/tools.py` (tool_get_muscle_group_progress, etc.)
- Triggers that populate data: `triggers/weekly-analytics.js`
