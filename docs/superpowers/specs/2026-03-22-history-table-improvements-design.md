# History Table Improvements

## Problem

Two issues with how past workout sets are displayed:

1. **ExercisePerformanceSheet** (in-workout history via exercise ellipsis menu): Missing RIR and set type indicators. Only shows Set, Weight, Reps, e1RM.
2. **SetTable in readOnly mode** (history tab detail view): Missing e1RM. Shows a "done" checkmark column that is always checked (no informational value).
3. Both tables are visually plain — headers lack visual distinction from data rows.

## Design

### 1. ExercisePerformanceSheet — Add RIR + Set Type

- Add `rir`, `is_warmup`, `is_failure` fields to the private `SetFact` model (already stored in Firestore `set_facts` documents).
- Add RIR column between Reps and e1RM.
- Show set type badge in the Set column (reuse W/F/D badge pattern from `SetTable.setIndexCell`).
- Final columns: **SET | WEIGHT | REPS | RIR | e1RM**

### 2. SetTable (readOnly) — Replace Done with e1RM

- Remove the checkmark done column in `.readOnly` mode.
- Add e1RM column in its place.
- Add `e1rm: String?` field to `SetCellModel`.
- Compute e1RM client-side during `WorkoutExerciseSet.toSetCellModel()` mapping: Epley formula `weight * (1 + reps/30)` for reps <= 12, nil otherwise. Show "—" when nil.
- Keep done column unchanged for `.execution` and `.planning` modes.

### 3. Styling — Subtle Polish

- Use accent-tinted header text instead of `textTertiary`.
- Slightly stronger header divider to visually separate header from data rows.
- Ensure consistent center-alignment across all columns.
- No additional backgrounds, shadows, or decorative elements.

## Scope

- Client-side Swift only. No backend/Firestore changes.
- Changes touch: `SetCellModel.swift`, `SetTable.swift`, `ExercisePerformanceSheet.swift`.
- All four `SetCellModel` mappers (WorkoutExerciseSet, WorkoutTemplateSet, PlanSet, FocusModeSet) need the new `e1rm` field — only WorkoutExerciseSet computes it; others pass nil.

## Decisions

- e1RM shows "—" for sets with >12 reps (Epley unreliable above that). Accepted tradeoff.
- e1RM is computed client-side from weight_kg and reps — no need to store on workout documents.
- Warmup sets show nil for both RIR and e1RM (by convention).
