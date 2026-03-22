# Focus Mode — Module Architecture

Focus Mode is the active workout UI. It provides a distraction-free interface for logging sets, swapping exercises, and completing workouts. Designed for gym use: large tap targets, sweat-proof gestures, single-hand operation.

## File Inventory

| File | Purpose |
|------|---------|
| `FocusModeWorkoutScreen.swift` | Main workout screen: exercise list, hero header, scroll tracking, finish/discard flow, exercise reordering. (~1430 lines after extraction.) |
| `FocusModeExerciseSection.swift` | Exercise section views: `FocusModeExerciseSection` (legacy), `FocusModeExerciseSectionNew` (with ActionRail), `FocusModeGridCell` enum. Extracted from FocusModeWorkoutScreen. |
| `FocusModeWorkoutHelpers.swift` | Supporting types: `CompletedWorkoutRef`, `WorkoutCompletionSummary`, `WorkoutAlertsModifier`. Extracted from FocusModeWorkoutScreen. |
| `FocusModeSetGrid.swift` | Set grid for logging reps, weight, and RIR per exercise. Contains `FocusModeEditingDock` (inline editor with stepper/keyboard/RIR pills), `FocusModeEditScope` enum (this/remaining/all). |
| `FocusModeComponents.swift` | Shared UI components: `WorkoutHero`, `TimerPill`, `SwipeToDeleteRow`, `WarmupDivider`, `ExerciseCardContainer`, `CoachButton`, `ReorderModeBanner`, `ActionRail`. Also contains `FocusModeActiveSheet` enum (centralized sheet state machine). |
| `FocusModeExerciseSearch.swift` | Exercise search for adding/swapping exercises mid-workout. Includes `ExerciseSortOption` enum (Recent/Frequent/A–Z) and `ExerciseFilters` model. Sort chips UI wired to `ExercisesViewModel.setSortOption()`. |
| `ExercisePerformanceSheet.swift` | In-workout exercise performance history. Queries `set_facts` for the given exercise and shows recent sessions grouped by date with summary stats (best e1RM, last weight/reps). Displays SET (with W/F type badges), WEIGHT, REPS, RIR, and e1RM columns. Requires Firestore composite index — see FIRESTORE_SCHEMA.md. |
| `WorkoutCoachView.swift` | AI copilot chat sheet for in-workout coaching. Displays `ThinkingBubble` (Gemini-style collapsible thought process) while agent is active, hides empty placeholder messages during streaming, auto-scrolls to thinking bubble and latest message. |

## Entry Point

Navigation enters Focus Mode via two paths:
1. **TrainTabView** (primary): `FocusModeWorkoutScreen` is embedded inline in the Train tab. The tab bar remains visible during workouts so users can browse other tabs. A `FloatingWorkoutBanner` overlay on `MainTabsView` shows the workout name and elapsed time on non-Train tabs, tapping it returns to the Train tab.
2. **ConversationScreen** (secondary): Presented as a `.fullScreenCover` when starting a workout from a chat-generated plan. In this context `dismiss()` correctly closes the cover on discard/complete.

## Key Relationships

- **FocusModeWorkoutService** (`Services/FocusModeWorkoutService.swift`): `@MainActor ObservableObject`. API calls for `startActiveWorkout`, `completeActiveWorkout`, `logSet`, `patchField`, `swapExercise`, `removeExercise`. Drains all pending sync operations before sending completion request (prevents race conditions). Exposes `workout` as published property. `refreshFromServer()` fetches server state via `getActiveWorkout` and merges agent-added exercises into local workout, mapping Firestore flat `weight`/`reps` fields to `targetWeight`/`targetReps` for planned set display.
- **WorkoutSessionLogger** (`Services/WorkoutSessionLogger.swift`): Records every workout event (start, log_set, complete, error) to timestamped JSON files in `Documents/workout_logs/`. Auto-flushes on app background. Writes breadcrumbs to Crashlytics for crash correlation.
- **FocusModeLogger** (`Services/DebugLogger.swift`): Convenience facade for workout debug logging. Preserves enum-based API (`MutationPhase`, `CoordinatorEvent`) for pattern matching. All output delegates to `AppLogger`.
- **FocusModeModels** (`Models/FocusModeModels.swift`): `FocusModeWorkout`, `FocusModeExercise`, `FocusModeSet` structs matching the `active_workouts` Firestore schema.

## Data Flow

```
User taps "Start Workout"
    → FocusModeWorkoutService.startWorkout(templateId, routineId?)
    → POST /startActiveWorkout
    → Firestore: active_workouts/{id} created
    → FocusModeWorkoutScreen displayed (screen auto-lock disabled)

User logs set (tap checkmark)
    → Immediate haptic feedback (single, in doneCell)
    → FocusModeWorkoutService.logSet() (async, fire-and-forget)
    → POST /logSet
    → WorkoutSessionLogger records event
    → On failure: warning banner auto-dismisses ("Set sync pending")

User finishes
    → FocusModeWorkoutService drains all in-flight logSet/patchField calls
    → POST /completeActiveWorkout
    → Firestore: workouts/{id} created, active_workouts/{id} archived
    → Trigger: workout-routine-cursor.js advances routine cursor
    → completedWorkoutId set → fullScreenCover presents WorkoutCompletionSummary
    → Screen auto-lock re-enabled
```

## Weight Unit Handling

Focus Mode uses `UserService.shared.activeWorkoutWeightUnit` — a snapshot of the user's weight preference taken when the workout starts (via `snapshotForWorkout()` called from `ActiveWorkoutManager.startWorkout()`). This prevents a mid-workout preference change from corrupting in-progress edits.

- **Display**: All `set.displayWeight` values from Firestore are in kg. `WeightFormatter.formatValue(kg, unit:)` converts for display.
- **Input**: User types/steps in their preferred unit. `WeightFormatter.toKg(value, from:)` converts back to kg before `applyValueChange("weight", kgValue)`.
- **Stepper increments**: 2.5 kg or 5 lbs (via `WeightFormatter.plateIncrement(unit:)`).

## Screen Mode State Machine

`FocusModeWorkoutScreen` uses a `screenMode` enum to manage UI state:

| Mode | Description |
|------|-------------|
| `.normal` | Default scrollable exercise list |
| `.editingSet(exerciseId, setId, cellType)` | Inline editing dock open for a specific cell |
| `.reordering` | List edit mode for drag-to-reorder exercises |

`screenMode` changes drive: editing dock visibility, `ScrollViewReader` scroll-to-dock, list edit mode sync.

## Key UI Patterns

### SwipeToDeleteRow (FocusModeComponents.swift)

Uses `@GestureState` (not `@State`) for the live drag offset so it auto-resets to zero when the gesture is cancelled (e.g., when ScrollView steals the touch). This prevents the "stuck at 30%" bug where `onEnded` never fires.

- `DragGesture(minimumDistance: 20)` — higher threshold to avoid capturing vertical scrolls
- Horizontal-only guard: `abs(width) > abs(height)` in the `updating` block
- `baseOffset` (`@State`) persists revealed/closed state between gestures
- `visibleOffset = baseOffset + dragOffset` — clean separation of concerns
- `.onTapGesture` (not `simultaneousGesture`) closes revealed state without interfering with child buttons

### FocusModeEditingDock (FocusModeSetGrid.swift)

Inline editor that appears below the selected set row. Attached to the set grid via `.id(selectedCell)` for `ScrollViewReader` targeting.

- **Type-to-replace**: Text field starts empty; current value shown as placeholder. Typing replaces the value entirely (no "4060" concatenation).
- **Stepper buttons (+/-)**: Do NOT dismiss keyboard. Clear partial text input so placeholder reflects the new value.
- **Scope selector**: "This" / "Remaining" / "All" — defaults to "Remaining" when subsequent sets have the same value, "This" otherwise.
- **RIR layout**: Uses `VStack` (pills on top, Done button below) instead of `HStack` to prevent 6-pill overflow on narrow screens. Weight/reps editors use `HStack`.

### Scroll-to-Dock (FocusModeWorkoutScreen.swift)

`ScrollViewReader` wraps the `LazyVStack` inside the `ScrollView`. An `.onChange(of: screenMode)` handler detects when editing starts and scrolls to the dock's `.id(cell)` with `.bottom` anchor after a 0.35s delay (to let the keyboard animation begin).

### Mark All Done (Column Header)

The "checkmark" column header in `FocusModeSetGrid` is a tappable button when `onToggleAllDone` is provided. Logic: if all working sets are done, undo all (patch to "planned"); otherwise, log all undone working sets.

### Done State Visibility

Completed sets have:
- Subtle success-tinted row background (`Color.success.opacity(0.06)`)
- Filled circle indicator (`Color.success.opacity(0.15)` fill + green stroke)
- Green checkmark and text color

### Exercise Ellipsis Menu Sheets

The exercise ellipsis menu (in `FocusModeExerciseSectionNew`) provides contextual actions:
- **Auto-fill Sets** — pre-fills set values from history
- **Exercise Info** — opens `ExerciseDetailSheet` (from `UI/Canvas/Cards/`) via `.exerciseDetail` sheet case
- **Performance** — opens `ExercisePerformanceSheet` via `.exercisePerformance` sheet case
- **Remove Exercise** — destructive, with confirmation dialog

Both sheet actions use the centralized `FocusModeActiveSheet` enum and the `presentSheet()` helper, which safely exits editing/reorder mode before presenting. Callbacks (`onShowDetails`, `onShowPerformance`) are optional on `FocusModeExerciseSectionNew` for backwards compatibility.

### WorkoutAlertsModifier

Alert/confirmation dialogs (finish, name edit, discard, resume gate) are extracted into a `ViewModifier` to reduce type-checker load on the main `body` computed property.

### Ghost Value Resolution (GhostValueResolver.swift)

Ghost values provide contextual pre-fills in the set grid. Resolution priority:
1. **Last session data** — weight/reps/RIR from the same set index in the most recent session for this exercise (via `set_facts` subcollection)
2. **Template prescription** — `targetWeight`/`targetReps`/`targetRir` from the template
3. **Blank** — no ghost value shown

Ghost values display at 40% opacity. When the user taps "done" on a set with ghost values, the ghost values are accepted as the actual values. User-entered values always take priority over ghosts.

`FocusModeWorkoutService.fetchLastSessionData()` populates `lastSessionData: [String: LastSessionExerciseData]` from Firestore on workout start.

### Auto-Advance Focus Progression (AutoAdvance enum)

After logging a set, focus automatically advances to the next undone set:
- `AutoAdvance.findNextUndoneSet()` scans exercises/sets in order, skipping done sets
- **With ghost values**: highlights the done button (user can confirm with one tap)
- **Without ghost values**: enters weight editing (user can type immediately)
- **Cross-exercise**: scrolls to the next exercise if needed
- **All done**: returns to normal mode

### Set Completion Signature (SetCompletionEffect.swift)

Choreographed completion animation (~0.5s total):
1. Radial fill (accent circle expands)
2. Pulse (`.bouncy` spring scale)
3. Haptic feedback
4. Checkmark appearance
5. Row flash (subtle highlight)

**Progressive intensity** via `CompletionLevel`:
- `.standard` — light haptic
- `.exerciseFinal` — medium haptic (last set in exercise)
- `.workoutFinal` — success notification haptic (last set in workout)

### Contextual Density (ExerciseDensity enum)

Exercise sections adapt their visual density based on workout state:
- `.active` — full set grid with editing controls
- `.completed` — compressed view with emerald left-edge bar, tap to expand
- `.upcoming` — 0.6 opacity, shown at normal size

### Destructive Action Tiers

Three tiers based on reversibility:
- **Tier 1** (reversible: remove set/exercise) — immediate action + undo toast (5s window)
- **Tier 2** (significant: swipe thresholds) — >150pt full swipe or >60pt with release
- **Tier 3** (irreversible: finish/discard workout, delete template) — standardized confirmation dialog

### Workout Completion Arc

Completion sequence after saving:
1. Final exercise signature plays
2. 500ms held beat of stillness
3. Success haptic fires
4. Full-screen summary with staggered reveal (200ms intervals across 6 phases)

Summary uses `.revealEffect()` for each phase. Coach reflection loads asynchronously and reveals last.
