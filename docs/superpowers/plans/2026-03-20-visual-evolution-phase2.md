# Visual Evolution Phase 2 — Remaining Spec Implementation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement all remaining spec items from the Visual Evolution design that were missed or only partially implemented in Phase 1. Focus on the substantive screen redesigns (Library, Train pre-workout, Workout mode card hierarchy) and the polish items (Coach tab Tier 2 heroes, completion summary enhancements, History PR/trend, set input micro-interactions) that make the visual evolution feel complete.

**Architecture:** All changes are iOS-only SwiftUI. Data services (`TrainingDataService`, `CoachTabViewModel`) already exist from Phase 1. This phase focuses on view-layer changes. The existing design token system (`Tokens.swift`) is used throughout.

**Tech Stack:** SwiftUI, Firebase/Firestore (read-only from iOS), existing design tokens in `Tokens.swift`

**Branch:** `feat/visual-evolution` (continue existing branch)

**Build command:** `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

---

## File Structure

### Modified Files
| File | Responsibility |
|------|---------------|
| `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` | `ExerciseCardContainer` — Tier 2/0 card hierarchy, completed emerald left-edge |
| `Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift` | Exercise header typography → design tokens |
| `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift` | Pre-workout start view redesign (Tier 2 hero + full-width CTA) |
| `Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift` | Completion summary — consistency map, coach reflection |
| `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift` | Set completion scale pulse, ghost values from previous session |
| `Povver/Povver/Views/Tabs/CoachTabView.swift` | Tier 2 hero cards, "YOUR COACH" label, consistency map in workout day, milestone display |
| `Povver/Povver/ViewModels/CoachTabViewModel.swift` | Consistency map in workout day hero, milestone hero state |
| `Povver/Povver/Views/Tabs/LibraryView.swift` | Full redesign — routine hero + mini week strip, template cards, exercise section |
| `Povver/Povver/Views/Tabs/HistoryView.swift` | Date header `sectionLabel` style, PR badge on workout rows |
| `Povver/Povver/UI/Shared/FloatingWorkoutBanner.swift` | Exercise name instead of workout name, design token typography |
| `Povver/Povver/UI/DesignSystem/Tokens.swift` | `Color.chartInactive` already added; no further changes expected |

### New Files
| File | Responsibility |
|------|---------------|
| `Povver/Povver/UI/Components/MiniWeekStrip.swift` | Compact week schedule indicator for Library routine hero |

---

## Task 1: Workout Mode — Exercise Card Tier Hierarchy

The spec defines three visual states for exercise cards during a workout: Tier 2 (active, elevated), Tier 0 (upcoming, flat), and completed (emerald left-edge). Currently all cards use the same `Color.surface` background with hairline stroke regardless of state.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift:940-963` (`ExerciseCardContainer`)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift:775-800` (pass `isCompleted` to container)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift:127-230` (pass `isCompleted` prop)

**Spec reference:** Section 2.6 — "Active exercise card lifts to Tier 2... All other cards recede to Tier 0... Completed exercises get a thin emerald left-edge indicator"

- [ ] **Step 1: Update `ExerciseCardContainer` to accept `isCompleted` and implement 3-tier hierarchy**

  Add `isCompleted: Bool` parameter. Change the body:
  - **Active (`isActive == true`):** `Color.surfaceElevated` background, no hairline stroke, `ShadowsToken.level1` shadow, emerald left-edge bar (already has this).
  - **Completed (`isCompleted == true`, not active):** No background (transparent, inherits `bg`), no stroke, no shadow, emerald left-edge bar (3pt, `radiusIcon` corners).
  - **Upcoming (default):** No background (transparent), no stroke, no shadow. Content flows on `bg`. Exercise name in `textSecondary` instead of `textPrimary`.

  ```swift
  struct ExerciseCardContainer<Content: View>: View {
      let isActive: Bool
      let isCompleted: Bool
      let content: () -> Content

      var body: some View {
          content()
              .background(isActive ? Color.surfaceElevated : (isCompleted ? Color.surface : Color.clear))
              .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
              .shadowStyle(isActive ? ShadowsToken.level1 : ShadowStyle(color: .clear, x: 0, y: 0, blur: 0))
              .overlay(alignment: .leading) {
                  // Emerald left-edge: active exercise AND completed exercises (earned color)
                  if isActive || isCompleted {
                      RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon)
                          .fill(Color.accent)
                          .frame(width: 3)
                          .padding(.vertical, 2)
                          .padding(.leading, 2)
                  }
              }
      }
  }
  ```

  Note: The old hairline stroke overlay is removed entirely — all three states (active, completed, upcoming) have no stroke per spec.

- [ ] **Step 2: Pass `isCompleted` from `FocusModeWorkoutScreen` to `ExerciseCardContainer`**

  At line ~776-778, compute `isCompleted` from the exercise:
  ```swift
  let isCompleted = exercise.isComplete
  ExerciseCardContainer(isActive: isActive, isCompleted: isCompleted) {
  ```

- [ ] **Step 3: Migrate exercise header typography to design tokens**

  In `FocusModeExerciseSection.swift` and `FocusModeExerciseSectionNew`, replace:
  - `.font(.system(size: 16, weight: .semibold))` → `.textStyle(.bodyStrong)` (line 51)
  - `.font(.system(size: 13))` → `.textStyle(.caption)` (line 55)

  In `FocusModeExerciseSectionNew` exercise header (line ~230+), do the same for equivalent raw font calls.

- [ ] **Step 4: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add -A && git commit -m "feat(workout): implement 3-tier exercise card hierarchy (active/completed/upcoming)"
  ```

---

## Task 2: Train Tab — Pre-Workout Start View Redesign

The current start view uses `startOptionButton()` rows. The spec calls for a Tier 2 hero card with the scheduled workout info, a full-width emerald CTA, and secondary text links below.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift:~530-660` (the start view section)

**Spec reference:** Section 5.2 — "Tier 2 hero card showing the workout name, day label... Primary CTA: 'Start Session' — full-width emerald PovverButton"

- [ ] **Step 1: Redesign the start view for "scheduled workout exists" state**

  Replace the current `startOptionButton(isPrimary: true)` for the scheduled workout with:
  - A **Tier 2 hero card**: `surfaceElevated` background, `radiusCard` corners, `ShadowsToken.level1` shadow
  - Inside: workout name in `bodyStrong`, day label ("Day 3 of 4") in `secondary`, exercise count in `caption`
  - Below the card: full-width emerald `PovverButton` with "Start Session" text

  Then replace the "Start Empty" and "From Template" `startOptionButton` calls with:
  - Simple `textSecondary` text links (Tier 0 — no card, no border, just text + chevron)

- [ ] **Step 2: Redesign the start view for "no scheduled workout" state**

  When there's no active routine / no next workout:
  - No hero card
  - "Start Empty Workout" as primary `PovverButton` (full-width)
  - "From Template" as secondary text link in `textSecondary`

- [ ] **Step 3: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add -A && git commit -m "feat(train): redesign pre-workout start view with Tier 2 hero and full-width CTA"
  ```

---

## Task 3: Library Tab — Full Redesign

Transform the Library from a 3-row navigation list into a content-rich dashboard showing training assets at a glance.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift:1-86` (main `LibraryView` body)
- Create: `Povver/Povver/UI/Components/MiniWeekStrip.swift`

**Spec reference:** Section 5.3 — "Rethought from a 3-row transit screen into a content-rich surface"

- [ ] **Step 1: Create `MiniWeekStrip` component**

  A horizontal row of day indicators for the active routine's schedule:
  ```swift
  struct MiniWeekStrip: View {
      let totalDays: Int          // routine template count
      let completedThisWeek: Int  // workouts completed this week
      let currentDayIndex: Int    // which day is "today" (0-based)

      var body: some View {
          HStack(spacing: Space.xs) {
              ForEach(0..<totalDays, id: \.self) { index in
                  RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon)
                      .fill(fillColor(for: index))
                      .overlay(
                          RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon)
                              .stroke(strokeColor(for: index), lineWidth: index == currentDayIndex ? 1.5 : 0)
                      )
                      .frame(height: 6)
              }
          }
      }

      private func fillColor(for index: Int) -> Color {
          if index < completedThisWeek { return Color.accent }
          return Color.clear
      }

      private func strokeColor(for index: Int) -> Color {
          if index < completedThisWeek { return Color.clear }
          if index == currentDayIndex { return Color.accent }
          return Color.separatorLine
      }
  }
  ```

- [ ] **Step 2: Redesign `LibraryView` main body**

  Replace the current 3-row navigation list with:

  **Header:** "Library" in `screenTitle` + contextual subtitle with actual counts ("X routines, Y templates") in `secondary`.

  **Active Routine section** (`sectionLabel`: "YOUR PROGRAM"):
  - If active routine exists: Tier 2 card (`surfaceElevated` + `level1` shadow) with:
    - Routine name in `bodyStrong`
    - `MiniWeekStrip` showing the week progress
    - "Next: [template name]" in `secondary` / `textSecondary`
    - NavigationLink to `RoutineDetailView`
  - If no active routine: coach-voiced empty state — "No programs yet — want me to design one for you?"

  **Other Routines** (if multiple): `sectionLabel` "OTHER ROUTINES", Tier 0 rows.

  **Templates section** (`sectionLabel`: "TEMPLATES"):
  - Show up to 3 most recent as Tier 1 cards (surface + hairline). Each: name in `bodyStrong`, exercise count in `secondary`.
  - "See all (N)" link if > 3.

  **Exercises section** (`sectionLabel`: "EXERCISES"):
  - "Browse all exercises" row with chevron → `ExercisesListView`.

  This requires loading routines and templates in `.task`. Use existing `FocusModeWorkoutService.shared.getUserRoutines()` and similar.

  **Fix the Button-wrapping-NavigationLink anti-pattern** (lines 28-67): Remove the outer `Button` wrapper. Fire analytics from `.onAppear` of the destination or use `NavigationLink` directly with `.simultaneousGesture`.

- [ ] **Step 3: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add -A && git commit -m "feat(library): redesign as content-rich dashboard with routine hero, template cards, exercise section"
  ```

---

## Task 4: Coach Tab — Tier 2 Heroes and Enhancements

Upgrade all Coach tab hero sections to Tier 2 cards and add missing elements per spec.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift:96-271` (hero sections)
- Modify: `Povver/Povver/ViewModels/CoachTabViewModel.swift` (expose data for consistency map in workout day state)

**Spec reference:** Section 5.1 — "Hero (Tier 2)" for all states, "YOUR COACH" sectionLabel, consistency map in workout day

- [ ] **Step 1: Add Tier 2 card wrapper to all hero sections**

  Create a shared hero card wrapper used by all hero states:
  ```swift
  private func heroCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
      VStack(spacing: Space.md) {
          content()
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, Space.lg)
      .padding(.horizontal, Space.md)
      .background(Color.surfaceElevated)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
      .shadowStyle(ShadowsToken.level1)
  }
  ```

  Apply to all hero sections: `newUserHero`, `workoutDayHero`, `restDayHero`, `postWorkoutHero`, `inactivityHero`.

- [ ] **Step 2: Add "YOUR COACH" sectionLabel above coach presence indicator**

  In each hero section, add above `CoachPresenceIndicator`:
  ```swift
  Text("YOUR COACH")
      .textStyle(.sectionLabel)
  ```

- [ ] **Step 3: Add Training Consistency Map to workout day hero**

  The consistency map currently only shows in `restDayHero`. Add it to `workoutDayHero` as well (spec says it should show on workout day, rest day, and returning states):

  ```swift
  if !viewModel.weeklyWorkoutCounts.isEmpty {
      TrainingConsistencyMap(
          weeks: viewModel.weeklyWorkoutCounts,
          routineFrequency: viewModel.routineFrequency
      )
      .padding(.top, Space.xs)
  }
  ```

  Also add it to `inactivityHero`.

- [ ] **Step 4: Enhance new user hero with focused CTA**

  Replace the generic "Start with a routine, or ask me anything" with:
  - "Tell me about your goals and I'll design a routine for you." in `secondary`
  - Single CTA button: "Create your first program" that triggers coach conversation

- [ ] **Step 5: Add post-workout hero PR highlights**

  In `postWorkoutHero`, after the stats row, show PR highlights from the post-workout insight.

  `PostWorkoutSummary` wraps a `PostWorkoutInsight` (via `.insight` property). The highlights are at `ctx.summary?.insight.highlights` and each `Highlight` has `type: String?`, `message: String?`, `exerciseId: String?`.

  ```swift
  if let highlights = ctx.summary?.insight.highlights?.filter({ $0.type == "pr" }),
     !highlights.isEmpty {
      ForEach(Array(highlights.enumerated()), id: \.offset) { _, highlight in
          HStack(spacing: Space.sm) {
              Text("PR")
                  .textStyle(.micro)
                  .fontWeight(.semibold)
                  .foregroundStyle(Color.accent)
                  .padding(.horizontal, Space.sm)
                  .padding(.vertical, Space.xxs)
                  .background(Color.accent.opacity(0.12))
                  .clipShape(Capsule())
              Text(highlight.message ?? "Personal record")
                  .textStyle(.secondary)
                  .foregroundStyle(Color.textSecondary)
          }
      }
  }
  ```

- [ ] **Step 6: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add -A && git commit -m "feat(coach): upgrade heroes to Tier 2 cards, add YOUR COACH label, consistency map, PR highlights"
  ```

---

## Task 5: History Tab — Date Headers, PR Badges

Upgrade History tab with `sectionLabel` date headers and PR badge on workout rows.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift`

**Spec reference:** Section 5.4 — "Adopt sectionLabel style: 'TODAY', 'YESTERDAY', 'MONDAY, MAR 17'" and "PR badge — if the workout contains a PR... a small emerald 'PR' capsule badge appears"

- [x] **Step 1: `DateHeaderView` already uses `sectionLabel` style** (completed in Phase 1)

  `DateHeaderView` at line 296 of `HistoryView.swift` already uses `.textStyle(.sectionLabel)`, which applies `.textCase(.uppercase)` and tracking automatically. No changes needed.

- [ ] **Step 2: Add PR badge to `WorkoutRow.history()` calls**

  This requires knowing if a workout has PRs. Two approaches:
  - **Simple (recommended):** Store a `hasPR: Bool` field on `HistoryWorkoutItem`. Derive from the workout's `analytics` or from a lightweight check against `analysis_insights`.
  - For now, if `Workout` model has a highlights/PR field, use it. If not, skip PR badge for this task (data layer work needed — note as out of scope).

  If data is available, add a trailing PR badge to the workout row:
  ```swift
  if workout.hasPR {
      Text("PR")
          .textStyle(.micro)
          .fontWeight(.semibold)
          .foregroundStyle(Color.accent)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.accent.opacity(0.12))
          .clipShape(Capsule())
  }
  ```

- [ ] **Step 3: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add -A && git commit -m "feat(history): upgrade date headers to sectionLabel style, add PR badge support"
  ```

---

## Task 6: Post-Workout Completion Summary — Consistency Map and Coach Reflection

Enhance the `WorkoutCompletionSummary` with the Training Consistency Map and optional coach reflection.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift:25-212` (`WorkoutCompletionSummary`)

**Spec reference:** Section 5.2 Finish Workout — "Consistency Map update (stagger +0.2s after highlights)... today's cell fills with emerald" and "Coach reflection (bottom)"

- [ ] **Step 1: Load consistency map data and coach reflection in `loadWorkout()`**

  Add state properties:
  ```swift
  @State private var weeklyWorkoutCounts: [WeekWorkoutCount] = []
  @State private var routineFrequency: Int = 4
  @State private var coachReflection: String? = nil
  ```

  In `loadWorkout()`, after fetching the workout, also load:
  ```swift
  // Load consistency map data
  let trainingService = TrainingDataService.shared
  weeklyWorkoutCounts = (try? await trainingService.fetchWeeklyWorkoutCounts(weeks: 12)) ?? []

  // Load coach reflection from post-workout summary
  if let summary = try? await trainingService.fetchPostWorkoutSummary(workoutId: workoutId) {
      coachReflection = summary.summary
  }
  ```

- [ ] **Step 2: Add consistency map to reveal sequence (phase 5, before exercise breakdown)**

  Insert between current phase 3 (exercise count) and phase 5 (workout detail):
  ```swift
  // Phase 4: Consistency Map with animated fill
  if !weeklyWorkoutCounts.isEmpty {
      TrainingConsistencyMap(
          weeks: weeklyWorkoutCounts,
          routineFrequency: routineFrequency
      )
      .padding(.horizontal, Space.lg)
      .opacity(revealPhase >= 4 ? 1 : 0)
      .offset(y: revealPhase >= 4 ? 0 : 8)
      .animation(MotionToken.bouncy, value: revealPhase)
  }
  ```

- [ ] **Step 3: Add coach reflection at the bottom**

  After `WorkoutSummaryContent`, add:
  ```swift
  if let reflection = coachReflection, !reflection.isEmpty {
      VStack(spacing: Space.sm) {
          CoachPresenceIndicator(size: 24)
          Text(reflection)
              .textStyle(.secondary)
              .foregroundStyle(Color.textSecondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal, Space.lg)
      }
      .opacity(revealPhase >= 5 ? 1 : 0)
      .offset(y: revealPhase >= 5 ? 0 : 8)
      .animation(MotionToken.gentle, value: revealPhase)
  }
  ```

  Adjust phase numbering so the full `WorkoutSummaryContent` is phase 6.

- [ ] **Step 4: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add -A && git commit -m "feat(completion): add consistency map and coach reflection to workout summary"
  ```

---

## Task 7: Set Completion Micro-Interaction — Scale Pulse

Add a brief scale pulse on the checkmark when a set is completed, per spec.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift` (the done/checkmark button area)

**Spec reference:** Section 5.2 — "Set completion: 0.12s scale pulse on the checkmark (1.0 → 1.15 → 1.0)"

- [ ] **Step 1: Add scale pulse animation to set completion checkmark**

  Find the checkmark/done button in `FocusModeSetGrid.swift`. Add a `@State` scale property and trigger a brief bounce on completion:
  ```swift
  // In the set row's done button:
  .scaleEffect(completionScale)
  .onChange(of: set.isDone) { _, isDone in
      if isDone {
          withAnimation(.spring(response: 0.12, dampingFraction: 0.5)) {
              completionScale = 1.15
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
              withAnimation(.spring(response: 0.12, dampingFraction: 0.8)) {
                  completionScale = 1.0
              }
          }
      }
  }
  ```

  Note: Since set rows are in a `ForEach`, use a per-row `@State` or a tracked dict. The simplest approach is to use an identifiable state wrapper or put the scale on the `CompletionCircle` component itself.

- [ ] **Step 2: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "feat(workout): add scale pulse micro-interaction on set completion"
  ```

---

## Task 8: FloatingWorkoutBanner — Design Token Typography and Exercise Name

Migrate `FloatingWorkoutBanner` to use design tokens and show the current exercise name.

**Files:**
- Modify: `Povver/Povver/UI/Shared/FloatingWorkoutBanner.swift`

**Spec reference:** Section 2.6 — "Content: show current exercise name instead of workout name"

- [ ] **Step 1: Migrate typography to design tokens**

  Replace raw `.font(.system(size: 14, weight: ...))` calls with `.textStyle(.secondary)` or `.textStyle(.caption)` as appropriate:
  - Workout/exercise name: `.textStyle(.secondary).fontWeight(.semibold)`
  - Timer: `.textStyle(.secondary).fontWeight(.medium)` + `.monospacedDigit()`
  - Icon fonts: keep as `.system(size:)` (icons don't use text styles)

- [ ] **Step 2: Add `currentExerciseName` parameter**

  Add an optional `currentExerciseName: String?` parameter. Show it alongside or instead of the workout name:
  ```swift
  let currentExerciseName: String?

  // In body:
  Text(currentExerciseName ?? workoutName)
      .textStyle(.secondary)
      .fontWeight(.semibold)
      .lineLimit(1)
  ```

  Update all call sites to pass `currentExerciseName`. In the main tab view, derive it from `FocusModeWorkoutService.shared` (the active exercise name).

- [ ] **Step 3: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add -A && git commit -m "feat(banner): migrate to design tokens, show current exercise name"
  ```

---

## Task 9: Exercise Sort Chips — Earned Color Fix

The sort chips in `ExercisesListView` use `Color.accent` for the selected state, violating the earned color principle. Fix to use neutral selection styling.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift:~639` (sort chips in `ExercisesListView`)

**Spec reference:** Section 3.6 — "Chip selected state: Stronger surface background + semibold text + slightly heavier border. No accentMuted fill."

- [ ] **Step 1: Find and update sort chip and filter button styling**

  Search for ALL `Color.accent` usage in `ExercisesListView`. There are two locations:
  - **Sort chips** (~lines 627-645): Selected chips use `Color.accent` background with `.textInverse` text.
  - **Filter button** (~lines 504-511): Also uses `Color.accent`.

  Replace both with neutral selection styling per earned color principle:
  - Selected: `Color.surface` background with `textPrimary` semibold text, `StrokeWidthToken.thin` border in `separatorLine`
  - Unselected: `Color.clear` background with `textSecondary` regular text, hairline border

- [ ] **Step 2: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add -A && git commit -m "fix(library): replace earned color on sort chips with neutral selection styling"
  ```

---

## Task 10: Raw Font Audit — Remaining Inline Typography

Sweep remaining raw `.font(.system(size:weight:))` calls in the modified screens and replace with design tokens.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift` (start option buttons: lines 621-627)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift` (AI action buttons: lines 107-114)
- Modify: `Povver/Povver/UI/Shared/FloatingWorkoutBanner.swift` (if not already done in Task 8)

**Spec reference:** Section 3.1 — "Audit every view using raw .font(.system(size:weight:)) and migrate to .textStyle()"

- [ ] **Step 1: Audit and replace raw fonts in FocusModeWorkoutScreen start options**

  In `startOptionButton()`:
  - `.font(.system(size: 16, weight: .semibold))` → `.textStyle(.bodyStrong)` (title)
  - `.font(.system(size: 13))` → `.textStyle(.caption)` (subtitle)
  - `.font(.system(size: 14, weight: .semibold))` → `.textStyle(.secondary).fontWeight(.semibold)` (Start label)

  Note: If Task 2 already rewrites the start view, this may already be done. Verify and clean up any remaining raw fonts.

- [ ] **Step 2: Audit and replace raw fonts in exercise AI action buttons**

  In `FocusModeExerciseSection.swift` `aiActionButton()`:
  - `.font(.system(size: 11, weight: .medium))` → `.textStyle(.micro).fontWeight(.medium)` (icon)
  - `.font(.system(size: 12, weight: .medium))` → `.textStyle(.micro).fontWeight(.medium)` (label)

- [ ] **Step 3: Build and verify**

  ```bash
  cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add -A && git commit -m "style: migrate remaining raw font calls to design token textStyle()"
  ```

---

## Dependency Graph

```
Task 1 (Card Hierarchy)     — independent
Task 2 (Start View)         — independent
Task 3 (Library Redesign)   — independent
Task 4 (Coach Heroes)       — independent
Task 5 (History Headers)    — independent
Task 6 (Completion Summary) — independent
Task 7 (Set Pulse)          — independent
Task 8 (Banner)             — independent
Task 9 (Sort Chips)         — independent (can merge with Task 3)
Task 10 (Font Audit)        — depends on Tasks 1, 2, 8 (avoids duplicate edits to same files)
```

Tasks 1–9 are independent and can be executed in any order. Task 10 should run last as a cleanup pass.

---

## Out of Scope (Noted for Future Work)

These spec items require more significant backend, data-layer, or cross-cutting work and are deferred:

1. **In-workout PR detection** (Section 8.6): Requires prefetching `analytics_series_exercise` on workout start and computing e1RM client-side. Worth doing but complex enough for its own task.
2. **Ghost values from previous session** (Section 5.2): Requires fetching last session data per exercise on workout start. The `getExerciseSummary` endpoint exists but wiring it into the set grid is a non-trivial UX + data flow change.
3. **`fetchExerciseTrend()` and History trend indicators** (Section 5.4): Requires `ExerciseTrend` model (already exists in `TrainingIntelligence.swift`) and wiring `getExerciseSummary` results into workout detail views.
4. **Multi-modal prompt bar** (Section 5.1): Voice chat and file/image upload — significant feature work beyond visual polish.
5. **Milestone hero state** (Section 6.2): The milestone detection exists in `CoachTabViewModel` but no hero state rendering for milestones. Deferred as it requires a new `CoachState` case.
6. **`workoutActive` environment value propagation** (Section 2.3): The key exists in `Tokens.swift` but no components read it to switch motion curves. Requires a systematic pass through all animated components.
7. **More/Settings screen changes** (Section 5.5): Profile avatar neutral tint, section headers to `sectionLabel`, row typography migration, sign-out as destructive text link. Low visual impact — deferred to a follow-up polish pass.
8. **Tab bar tint** (Section 3.6): Change from emerald tint to `textSecondary` neutral. Affects `MainTabView` — deferred as it's a single change with large UX impact that should be evaluated separately.
9. **Empty states with coach voice** (Section 6.4): Partial coverage in Library (Task 3). Remaining screens (History, Coach no-conversations, Exercise search no-results) deferred to a follow-up pass.
10. **History screen header** (Section 5.4): Already shows "History" in `screenTitle` + session count in `secondary` (lines 80-86 of `HistoryView.swift`). No changes needed — already implemented.
