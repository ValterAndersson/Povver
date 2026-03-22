# Domain Components — Module Architecture

Reusable UI components specific to the fitness domain. These render workout data but contain no data-fetching logic.

## File Inventory

| File | Purpose |
|------|---------|
| `ExerciseSection.swift` | Unified exercise block container with mode-specific density (readOnly/planning/execution) |
| `ExerciseSectionModel.swift` | Model and factory methods for ExerciseSection |
| `SetTable.swift` | Set grid for displaying workout sets across all modes. In readOnly mode, shows e1RM column instead of done checkmark. |
| `SetCellModel.swift` | Render model for individual set cells, plus `toSetCellModels()` extensions for `WorkoutExerciseSet`, `PlanSet`, `FocusModeSet`, and `WorkoutTemplateSet`. Includes `e1rm` field — computed client-side via Epley formula in the `WorkoutExerciseSet` mapper (reps ≤ 12 only), nil for all other mappers. |
| `WorkoutRow.swift` | Canonical workout row for listing across all surfaces (history, routines, templates) |
| `WorkoutSummaryContent.swift` | Workout analytics summary: stats, muscle group distribution, intensity, exercise list |

## Key Patterns

- **Mode-based density**: Components scale padding/font based on context (readOnly < planning < execution)
- **Render models**: `SetCellModel`, `ExerciseSectionModel` separate presentation from domain models
- **No data fetching**: All components are pure renderers — data is passed in via props
- **WorkoutSummaryContent**: All analytics are server-computed by `analytics-calculator.js`. No client-side calculation. Used by both post-workout completion flow and history detail screen. Supports optional `onEditWorkoutNote` / `onEditExerciseNote` callbacks for note editing (wired from history detail, nil in post-workout).
