# History Table Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add RIR + set types to the in-workout performance sheet, replace the always-checked done column with e1RM in history set tables, and apply subtle styling polish to both table surfaces.

**Architecture:** Three files change. `SetCellModel` gains an `e1rm` field and Epley computation in its mapper. `SetTable` swaps the done column for e1RM in readOnly mode and gets header styling. `ExercisePerformanceSheet` gains RIR column, set type badges, and matching header styling.

**Tech Stack:** SwiftUI, iOS design tokens (Tokens.swift)

**Spec:** `docs/superpowers/specs/2026-03-22-history-table-improvements-design.md`

---

### Task 1: Add e1RM field to SetCellModel and compute in WorkoutExerciseSet mapper

**Files:**
- Modify: `Povver/Povver/UI/Components/Domain/SetCellModel.swift`

- [ ] **Step 1: Add `e1rm` field to `SetCellModel`**

Add after the `rir` property (line 19):

```swift
let e1rm: String?     // e.g., "102" or nil for warmups/high-rep sets
```

Update all existing `SetCellModel(...)` initializer call sites in this file to include `e1rm: nil` — except the `WorkoutExerciseSet` mapper which will compute it.

- [ ] **Step 2: Add Epley computation to `WorkoutExerciseSet.toSetCellModel()`**

In the `WorkoutExerciseSet` mapper (line 58), compute e1RM and pass it:

```swift
func toSetCellModel(indexLabel: String, weightUnit: WeightUnit) -> SetCellModel {
    let indicator = setTypeIndicator(from: type)
    let e1rmValue = computeE1RM(weightKg: weight, reps: reps, isWarmup: indicator == .warmup)

    return SetCellModel(
        id: id,
        indexLabel: indicator != nil ? indicator!.label : indexLabel,
        weight: formatWeight(weight, unit: weightUnit),
        reps: "\(reps)",
        rir: indicator == .warmup ? nil : rir.map { "\($0)" },
        e1rm: e1rmValue.map { WeightFormatter.formatValue($0, unit: weightUnit) },
        setTypeIndicator: indicator,
        isActive: false,
        isCompleted: isCompleted
    )
}

/// Epley e1RM: weight * (1 + reps/30). Only for non-warmup sets with reps <= 12.
private func computeE1RM(weightKg: Double, reps: Int, isWarmup: Bool) -> Double? {
    guard !isWarmup, reps >= 1, reps <= 12, weightKg > 0 else { return nil }
    if reps == 1 { return weightKg }
    return weightKg * (1.0 + Double(reps) / 30.0)
}
```

- [ ] **Step 3: Pass `e1rm: nil` in all other mappers**

Update these mappers to pass `e1rm: nil` in their `SetCellModel(...)` calls:
- `WorkoutTemplateSet.toSetCellModel()` (line 124)
- `PlanSet.toSetCellModel()` (line 190)
- `FocusModeSet.toSetCellModel()` (line 257)

- [ ] **Step 4: Update preview sample data**

In `SetTable_Previews` (in `SetTable.swift`), add `e1rm:` to each `SetCellModel(...)` call:
- Warmup sets: `e1rm: nil`
- Working sets: `e1rm: "102"`, `e1rm: "98"`, etc.

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/Components/Domain/SetCellModel.swift Povver/Povver/UI/Components/Domain/SetTable.swift
git commit -m "feat(history): add e1rm field to SetCellModel with Epley computation"
```

---

### Task 2: Replace done column with e1RM in SetTable readOnly mode

**Files:**
- Modify: `Povver/Povver/UI/Components/Domain/SetTable.swift`

- [ ] **Step 1: Update `showDoneColumn` to exclude readOnly**

Change the `showDoneColumn` computed property:

```swift
private var showDoneColumn: Bool {
    switch mode {
    case .readOnly: return false  // Replaced by e1RM column
    case .planning: return false
    case .execution: return true
    }
}
```

- [ ] **Step 2: Add `showE1RMColumn` computed property**

```swift
private var showE1RMColumn: Bool {
    mode == .readOnly
}
```

- [ ] **Step 3: Add e1RM to the header row**

After the RIR header `Text("RIR")` block, add:

```swift
if showE1RMColumn {
    Text("e1RM")
        .frame(width: 52, alignment: .center)
}
```

- [ ] **Step 4: Add e1RM to the set row**

In `setRow(_:)`, after the RIR column block and before the done column block, add:

```swift
// e1RM column (readOnly only)
if showE1RMColumn {
    Text(set.e1rm ?? "—")
        .font(.system(size: 16, weight: .medium).monospacedDigit())
        .foregroundColor(set.e1rm != nil ? Color.textSecondary : Color.textTertiary)
        .frame(width: 52, alignment: .center)
}
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/Components/Domain/SetTable.swift
git commit -m "feat(history): replace done column with e1RM in readOnly SetTable"
```

---

### Task 3: Add RIR + set type to ExercisePerformanceSheet

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/ExercisePerformanceSheet.swift`

- [ ] **Step 1: Add fields to SetFact model**

Add `rir`, `isWarmup`, and `isFailure` fields to the private `SetFact` struct:

```swift
private struct SetFact: Decodable {
    let workoutId: String
    let workoutDate: String
    let setIndex: Int
    let weightKg: Double?
    let reps: Int?
    let rir: Int?
    let e1rm: Double?
    let isWarmup: Bool
    let isFailure: Bool

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case workoutDate = "workout_date"
        case setIndex = "set_index"
        case weightKg = "weight_kg"
        case reps
        case rir
        case e1rm
        case isWarmup = "is_warmup"
        case isFailure = "is_failure"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workoutId = try container.decodeIfPresent(String.self, forKey: .workoutId) ?? ""
        workoutDate = try container.decodeIfPresent(String.self, forKey: .workoutDate) ?? ""
        setIndex = try container.decodeIfPresent(Int.self, forKey: .setIndex) ?? 0
        weightKg = try container.decodeIfPresent(Double.self, forKey: .weightKg)
        reps = try container.decodeIfPresent(Int.self, forKey: .reps)
        rir = try container.decodeIfPresent(Int.self, forKey: .rir)
        e1rm = try container.decodeIfPresent(Double.self, forKey: .e1rm)
        isWarmup = try container.decodeIfPresent(Bool.self, forKey: .isWarmup) ?? false
        isFailure = try container.decodeIfPresent(Bool.self, forKey: .isFailure) ?? false
    }

    /// Set type indicator matching SetTable convention
    var setTypeLabel: String? {
        if isWarmup { return "W" }
        if isFailure { return "F" }
        return nil
    }

    var setTypeColor: Color? {
        if isWarmup { return Color.warning }
        if isFailure { return Color.destructive }
        return nil
    }
}
```

- [ ] **Step 2: Update the header row in `sessionCard`**

Replace the header HStack (lines 259-268) with:

```swift
HStack(spacing: 0) {
    Text("Set")
        .frame(width: 36, alignment: .center)
    Text("Weight")
        .frame(maxWidth: .infinity, alignment: .center)
    Text("Reps")
        .frame(width: 44, alignment: .center)
    Text("RIR")
        .frame(width: 36, alignment: .center)
    Text("e1RM")
        .frame(width: 52, alignment: .center)
}
```

- [ ] **Step 3: Update `setRow` to include RIR and set type badge**

Replace the `setRow(index:fact:)` function (lines 292-310) with:

```swift
private func setRow(index: Int, fact: SetFact) -> some View {
    HStack(spacing: 0) {
        // Set index with type badge
        ZStack {
            if let label = fact.setTypeLabel, let color = fact.setTypeColor {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textInverse)
                    .frame(width: 22, height: 22)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("\(index)")
                    .foregroundColor(Color.textSecondary)
            }
        }
        .frame(width: 36, alignment: .center)

        Text(fact.weightKg.map { WeightFormatter.formatValue($0, unit: weightUnit) } ?? "—")
            .frame(maxWidth: .infinity, alignment: .center)
            .foregroundColor(Color.textPrimary)

        Text(fact.reps.map { "\($0)" } ?? "—")
            .frame(width: 44, alignment: .center)
            .foregroundColor(Color.textPrimary)

        Text(fact.isWarmup ? "—" : (fact.rir.map { "\($0)" } ?? "—"))
            .frame(width: 36, alignment: .center)
            .foregroundColor(fact.rir != nil && !fact.isWarmup ? Color.textPrimary : Color.textTertiary)

        Text(fact.e1rm.map { WeightFormatter.formatValue($0, unit: weightUnit) } ?? "—")
            .frame(width: 52, alignment: .center)
            .foregroundColor(fact.e1rm != nil ? Color.textSecondary : Color.textTertiary)
    }
    .font(.system(size: 14).monospacedDigit())
    .padding(.horizontal, Space.md)
    .padding(.vertical, 8)
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/FocusMode/ExercisePerformanceSheet.swift
git commit -m "feat(history): add RIR and set type badges to ExercisePerformanceSheet"
```

---

### Task 4: Styling polish for both tables

**Files:**
- Modify: `Povver/Povver/UI/Components/Domain/SetTable.swift`
- Modify: `Povver/Povver/UI/FocusMode/ExercisePerformanceSheet.swift`

- [ ] **Step 1: Style SetTable header**

In `SetTable.headerRow`, update the header styling:

Change `.foregroundColor(Color.textTertiary)` to `.foregroundColor(Color.accent.opacity(0.6))`.

Replace the `Divider()` after `headerRow` in `body` with a stronger separator:

```swift
Rectangle()
    .fill(Color.accent.opacity(0.15))
    .frame(height: 1)
```

- [ ] **Step 2: Style ExercisePerformanceSheet header**

In the `sessionCard` header HStack, apply matching styling:

Change `.foregroundColor(Color.textTertiary)` to `.foregroundColor(Color.accent.opacity(0.6))`.

Replace the `Divider()` after the header with:

```swift
Rectangle()
    .fill(Color.accent.opacity(0.15))
    .frame(height: 1)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/Components/Domain/SetTable.swift Povver/Povver/UI/FocusMode/ExercisePerformanceSheet.swift
git commit -m "style(history): accent-tinted headers and stronger dividers for set tables"
```

---

### Task 5: Visual verification

- [ ] **Step 1: Build and run on simulator**

Use XcodeBuildMCP `build_run_sim` to launch the app.

- [ ] **Step 2: Verify history detail view**

Navigate to History tab > tap a workout > verify:
- e1RM column appears where done checkmark was
- e1RM shows values for sets with <= 12 reps, "—" for others
- Warmup rows show "—" for e1RM
- Header has accent-tinted text and stronger divider
- No done checkmark column

- [ ] **Step 3: Verify in-workout performance sheet**

Start a workout > tap exercise ellipsis > "Performance" > verify:
- Set type badges (W/F) appear in Set column
- RIR column appears between Reps and e1RM
- e1RM shows values or "—" consistently
- Header styling matches SetTable

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat(history): complete history table improvements — e1RM, RIR, set types, styling"
```
