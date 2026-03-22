/**
 * FocusModeSetGrid.swift
 * 
 * Full-width spreadsheet-style set grid for Focus Mode.
 * 
 * Key design decisions:
 * - Always expanded (no collapsed state)
 * - Uses full available width with proportional columns
 * - Inline editing dock appears below selected row
 * - Swipe actions for delete/duplicate
 * - Large tap targets for fast input during workout
 */

import SwiftUI

// MARK: - Edit Scope (Apply to This/Remaining/All)

enum FocusModeEditScope: String, CaseIterable {
    case thisOnly = "This Only"
    case remaining = "Remaining"
    case allWorking = "All Working"
}

struct FocusModeSetGrid: View {
    let exercise: FocusModeExercise
    @Binding var selectedCell: FocusModeGridCell?

    let onLogSet: (String, String, Double?, Int, Int?) -> Void
    let onPatchField: (String, String, String, Any) -> Void
    let onAddSet: () -> Void
    let onRemoveSet: (String) -> Void
    var onToggleAllDone: (() -> Void)? = nil

    /// Ghost values for undone sets (keyed by set ID). Displayed at 40% opacity.
    /// When user taps done on a set with ghost values and no manual entry, ghost values become actuals.
    var ghostValues: [String: GhostValues] = [:]

    /// Whether this is the last exercise in the workout (for progressive haptics)
    var isLastExercise: Bool = false

    // Row height - larger than typical for gym use (big fingers, sweat)
    private let rowHeight: CGFloat = 52

    // Weight unit (snapshotted at workout start)
    private var weightUnit: WeightUnit { UserService.shared.activeWorkoutWeightUnit }
    
    // Set type picker state
    @State private var setTypePickerSetId: String? = nil
    
    // MARK: - Normalized Sets (warmups first, then working)
    
    private var warmupSets: [FocusModeSet] {
        exercise.sets.filter { $0.isWarmup }
    }
    
    private var workingSets: [FocusModeSet] {
        exercise.sets.filter { !$0.isWarmup }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header row
            gridHeader
            
            // Warmup sets (rendered first, normalized ordering)
            ForEach(Array(warmupSets.enumerated()), id: \.element.id) { index, set in
                setRowWithEditor(set: set, displayIndex: index, isWarmupSection: true)
            }
            
            // Dotted divider between warmup and working sets
            if !warmupSets.isEmpty && !workingSets.isEmpty {
                WarmupDivider()
                    .padding(.horizontal, Space.md)
            }
            
            // Working sets (rendered after warmups)
            ForEach(Array(workingSets.enumerated()), id: \.element.id) { index, set in
                setRowWithEditor(set: set, displayIndex: index, isWarmupSection: false)
            }
            
            // Add set button
            addSetButton
        }
        .sheet(isPresented: Binding(
            get: { setTypePickerSetId != nil },
            set: { if !$0 { setTypePickerSetId = nil } }
        )) {
            if let setId = setTypePickerSetId {
                FocusModeSetTypePickerSheet(
                    setId: setId,
                    exerciseId: exercise.instanceId,
                    currentType: exercise.sets.first { $0.id == setId }?.setType ?? .working,
                    isFailure: exercise.sets.first { $0.id == setId }?.tags?.isFailure ?? false,
                    onSelectType: { newType in
                        onPatchField(exercise.instanceId, setId, "set_type", newType.rawValue)
                        setTypePickerSetId = nil
                    },
                    onToggleFailure: { isFailure in
                        onPatchField(exercise.instanceId, setId, "tags.is_failure", isFailure)
                        setTypePickerSetId = nil
                    },
                    onDismiss: { setTypePickerSetId = nil }
                )
            }
        }
    }
    
    // MARK: - Set Row With Editor
    
    @ViewBuilder
    private func setRowWithEditor(set: FocusModeSet, displayIndex: Int, isWarmupSection: Bool) -> some View {
        VStack(spacing: 0) {
            // Set row with custom swipe-to-delete
            SwipeToDeleteRow(
                onDelete: {
                    onRemoveSet(set.id)
                    HapticManager.confirmAction()
                },
                content: {
                    setRow(set: set, index: displayIndex)
                }
            )
            
            // Inline editing dock
            if let selected = selectedCell,
               selected.exerciseId == exercise.instanceId,
               selected.setId == set.id {
                FocusModeEditingDock(
                    selectedCell: selected,
                    set: set,
                    exerciseId: exercise.instanceId,
                    allSets: exercise.sets,
                    onValueChange: { field, value in
                        onPatchField(exercise.instanceId, set.id, field, value)
                    },
                    onBatchValueChange: { field, value, scope in
                        // Apply to multiple sets based on scope
                        let currentIndex = exercise.sets.firstIndex { $0.id == set.id } ?? 0
                        let targetSets: [FocusModeSet]
                        switch scope {
                        case .allWorking:
                            targetSets = exercise.sets.filter { !$0.isWarmup }
                        case .remaining:
                            targetSets = Array(exercise.sets.dropFirst(currentIndex).filter { !$0.isWarmup })
                        case .thisOnly:
                            targetSets = [set]
                        }
                        for targetSet in targetSets {
                            onPatchField(exercise.instanceId, targetSet.id, field, value)
                        }
                    },
                    onLogSet: {
                        let ghost = ghostValues[set.id]
                        let weight = set.displayWeight ?? ghost?.weight
                        let reps = set.displayReps ?? ghost?.reps ?? 10
                        let rir = set.displayRir ?? ghost?.rir
                        onLogSet(exercise.instanceId, set.id, weight, reps, rir)
                        selectedCell = nil
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedCell = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(selected)
            }

            Divider()
                .padding(.leading, Space.md)
        }
        .setCompletionFlash(trigger: set.isDone)
        .background(rowBackground(for: set))
    }
    
    // MARK: - Grid Header
    
    private var gridHeader: some View {
        GeometryReader { geo in
            let widths = columnWidths(for: geo.size.width)

            HStack(spacing: 0) {
                Text("SET")
                    .frame(width: widths.set, alignment: .leading)
                Text("WEIGHT")
                    .frame(width: widths.weight, alignment: .center)
                Text("REPS")
                    .frame(width: widths.reps, alignment: .center)
                Text("RIR")
                    .frame(width: widths.rir, alignment: .center)

                // Tappable header: toggle all sets done/undone
                if let onToggleAllDone {
                    Button {
                        onToggleAllDone()
                        HapticManager.modeToggle()
                    } label: {
                        Text("✓")
                            .frame(width: widths.done, alignment: .center)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Text("✓")
                        .frame(width: widths.done, alignment: .center)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color.textSecondary)
            .frame(height: 32)
            .padding(.horizontal, Space.md)
        }
        .frame(height: 32)
        .background(Color.surfaceElevated.opacity(0.5))
    }
    
    // MARK: - Set Row
    
    private func setRow(set: FocusModeSet, index: Int) -> some View {
        GeometryReader { geo in
            let widths = columnWidths(for: geo.size.width)
            let ghost = ghostValues[set.id]

            HStack(spacing: 0) {
                // SET column
                setNumberCell(set: set, index: index, width: widths.set)

                // WEIGHT column — show ghost value at 40% opacity if no real value
                valueCell(
                    value: formatWeight(set.displayWeight),
                    ghostValue: (!set.isDone && set.displayWeight == nil) ? ghost?.weight.map { formatWeight($0) } : nil,
                    isSelected: selectedCell == .weight(exerciseId: exercise.instanceId, setId: set.id),
                    isSecondary: set.isWarmup,
                    isDone: set.isDone,
                    width: widths.weight
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedCell = .weight(exerciseId: exercise.instanceId, setId: set.id)
                    }
                }

                // REPS column — show ghost value at 40% opacity if no real value
                valueCell(
                    value: set.displayReps.map { "\($0)" } ?? "—",
                    ghostValue: (!set.isDone && set.displayReps == nil) ? ghost?.reps.map { "\($0)" } : nil,
                    isSelected: selectedCell == .reps(exerciseId: exercise.instanceId, setId: set.id),
                    isSecondary: set.isWarmup,
                    isDone: set.isDone,
                    width: widths.reps
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedCell = .reps(exerciseId: exercise.instanceId, setId: set.id)
                    }
                }

                // RIR column — show ghost value at 40% opacity if no real value
                valueCell(
                    value: set.isWarmup ? "—" : (set.displayRir.map { "\($0)" } ?? "—"),
                    ghostValue: (!set.isDone && !set.isWarmup && set.displayRir == nil) ? ghost?.rir.map { "\($0)" } : nil,
                    isSelected: selectedCell == .rir(exerciseId: exercise.instanceId, setId: set.id),
                    isSecondary: set.isWarmup || set.displayRir == nil,
                    isDone: set.isDone,
                    width: widths.rir
                ) {
                    if !set.isWarmup {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCell = .rir(exerciseId: exercise.instanceId, setId: set.id)
                        }
                    }
                }

                // DONE column
                doneCell(set: set, width: widths.done)
            }
            .frame(height: rowHeight)
            .padding(.horizontal, Space.md)
        }
        .frame(height: rowHeight)
    }
    
    // MARK: - Column Cells
    
    private func setNumberCell(set: FocusModeSet, index: Int, width: CGFloat) -> some View {
        Button {
            setTypePickerSetId = set.id
        } label: {
            let display = displayNumber(for: index, set: set)
            
            HStack(spacing: 4) {
                Text(display.text)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(display.color)
                    .frame(width: display.isLetter ? 24 : nil, alignment: .center)
                    .background(
                        display.isLetter && display.text != "W" ?
                            display.color.opacity(0.15) : Color.clear
                    )
                    .cornerRadius(4)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Value Cell (v1.1 Single Focus Rule)
    /// Only the selected/editing row gets accentMuted background - no thick colored borders.
    /// Ghost values are shown at 40% opacity when the set is undone and has no real value.
    private func valueCell(
        value: String,
        ghostValue: String? = nil,
        isSelected: Bool,
        isSecondary: Bool,
        isDone: Bool,
        width: CGFloat,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            // If a ghost value exists and the real value is the placeholder "—", show ghost text
            if let ghostText = ghostValue, value == "—" {
                Text(ghostText)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundColor(Color.textPrimary)
                    .opacity(InteractionToken.disabledOpacity)
                    .frame(width: width - 8, height: rowHeight - 12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Color.accentMuted : Color.clear)
                    )
            } else {
                Text(value)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundColor(cellTextColor(isSelected: isSelected, isSecondary: isSecondary, isDone: isDone, value: value))
                    .frame(width: width - 8, height: rowHeight - 12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Color.accentMuted : Color.clear)
                    )
            }
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: width)
    }
    
    private func doneCell(set: FocusModeSet, width: CGFloat) -> some View {
        SetCompletionCircle(
            isComplete: set.isDone,
            completionLevel: completionLevel(for: set),
            action: {
                if set.isDone {
                    // Already done -- tap to undo (forgiveness)
                    onPatchField(exercise.instanceId, set.id, "status", "planned")
                    HapticManager.selectionTick()
                } else {
                    // Mark as done: use ghost values as fallback when no manual entry exists
                    let ghost = ghostValues[set.id]
                    let weight = set.displayWeight ?? ghost?.weight
                    let reps = set.displayReps ?? ghost?.reps ?? 10
                    let rir = set.displayRir ?? ghost?.rir
                    onLogSet(exercise.instanceId, set.id, weight, reps, rir)
                    // Haptics are fired by SetCompletionCircle based on completionLevel
                }
            }
        )
        .frame(width: width, height: rowHeight)
    }

    /// Determine the completion level for progressive haptics.
    /// - Last undone working set of the last exercise = workoutFinal
    /// - Last undone working set of this exercise = exerciseFinal
    /// - Otherwise = standard
    private func completionLevel(for set: FocusModeSet) -> CompletionLevel {
        // Only working sets participate in progressive intensity
        guard !set.isWarmup else { return .standard }

        let undoneWorking = workingSets.filter { !$0.isDone }
        // If this set is the only undone working set, completing it finishes the exercise
        let isLastUndoneInExercise = undoneWorking.count == 1 && undoneWorking.first?.id == set.id

        if isLastUndoneInExercise && isLastExercise {
            return .workoutFinal
        } else if isLastUndoneInExercise {
            return .exerciseFinal
        }
        return .standard
    }
    
    // MARK: - Add Set Button
    
    private var addSetButton: some View {
        Button(action: onAddSet) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                Text("Add Set")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(Color.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Helpers
    
    private struct ColumnWidths {
        let set: CGFloat
        let weight: CGFloat
        let reps: CGFloat
        let rir: CGFloat
        let done: CGFloat
    }
    
    private func columnWidths(for totalWidth: CGFloat) -> ColumnWidths {
        // Proportional widths optimized for workout logging
        // SET 12%, WEIGHT 30%, REPS 20%, RIR 18%, DONE 20%
        return ColumnWidths(
            set: totalWidth * 0.12,
            weight: totalWidth * 0.30,
            reps: totalWidth * 0.20,
            rir: totalWidth * 0.18,
            done: totalWidth * 0.20
        )
    }
    
    /// Display info for set number column
    private struct SetDisplayInfo {
        let text: String
        let color: Color
        let isLetter: Bool
    }
    
    /// Returns display info for the set number column
    /// - Warmups: "WU" (secondary color)
    /// - Working sets: numbered 1, 2, 3... (1-based, primary color)
    /// - Drop sets: "D" (warning color)
    /// - Failure sets: "F" (error color)
    /// 
    /// Note: displayIndex is the 0-based index within the already-filtered section
    /// (warmupSets or workingSets), NOT the original exercise.sets array.
    private func displayNumber(for displayIndex: Int, set: FocusModeSet) -> SetDisplayInfo {
        if set.isWarmup {
            // Warmups show as "W" (compact to fit in single line)
            return SetDisplayInfo(text: "W", color: Color.textSecondary, isLetter: true)
        } else if set.tags?.isFailure == true {
            // Failure sets get "F" indicator
            return SetDisplayInfo(text: "F", color: Color.destructive, isLetter: true)
        } else if set.setType == .dropset {
            // Drop sets get "D" indicator
            return SetDisplayInfo(text: "D", color: Color.warning, isLetter: true)
        } else {
            // Working sets are 1-based: displayIndex 0 → "1", displayIndex 1 → "2", etc.
            return SetDisplayInfo(text: "\(displayIndex + 1)", color: Color.textPrimary, isLetter: false)
        }
    }

    private func formatWeight(_ weight: Double?) -> String {
        WeightFormatter.formatValue(weight, unit: weightUnit)
    }

    private func cellTextColor(isSelected: Bool, isSecondary: Bool, isDone: Bool, value: String) -> Color {
        if isSelected { return Color.accent }
        if isDone { return Color.success }
        if isSecondary || value == "—" { return Color.textSecondary }
        return Color.textPrimary
    }
    
    // MARK: - Row Background (v1.1 Single Focus Rule)
    /// Selected/editing row gets accentMuted. Done rows get subtle success tint.
    private func rowBackground(for set: FocusModeSet) -> Color {
        if let selected = selectedCell,
           selected.exerciseId == exercise.instanceId,
           selected.setId == set.id {
            // ONLY the active/editing row is tinted with accentMuted
            return Color.accentMuted
        }
        // Done sets get subtle success tint for at-a-glance visibility
        if set.isDone {
            return Color.success.opacity(0.06)
        }
        // Warmups get subtle grouping background
        if set.isWarmup {
            return Color.surfaceElevated.opacity(0.5)
        }
        return Color.clear
    }
}

// MARK: - Editing Dock

struct FocusModeEditingDock: View {
    let selectedCell: FocusModeGridCell
    let set: FocusModeSet
    let exerciseId: String
    let allSets: [FocusModeSet]

    let onValueChange: (String, Any) -> Void
    let onBatchValueChange: (String, Any, FocusModeEditScope) -> Void
    let onLogSet: () -> Void
    let onDismiss: () -> Void

    @State private var isEditingText = false
    @State private var textInputValue = ""
    @State private var editScope: FocusModeEditScope = .thisOnly
    @State private var hasComputedDefaultScope = false
    @FocusState private var textFieldFocused: Bool

    private var isWarmup: Bool { `set`.isWarmup }
    private var currentSetIndex: Int { allSets.firstIndex { $0.id == `set`.id } ?? 0 }

    // Weight unit (snapshotted at workout start)
    private var weightUnit: WeightUnit { UserService.shared.activeWorkoutWeightUnit }
    
    /// Compute smart default scope:
    /// - If subsequent sets have same value as current → default to "Remaining"
    /// - If they differ → default to "This"
    private var smartDefaultScope: FocusModeEditScope {
        guard !isWarmup else { return .thisOnly }
        
        let workingSets = allSets.filter { !$0.isWarmup }
        guard let currentWorkingIndex = workingSets.firstIndex(where: { $0.id == set.id }) else {
            return .thisOnly
        }
        
        let subsequentSets = Array(workingSets.dropFirst(currentWorkingIndex + 1))
        guard !subsequentSets.isEmpty else { return .thisOnly }
        
        // Check if subsequent sets match current based on what we're editing
        let allMatch: Bool
        switch selectedCell {
        case .weight:
            let currentWeight = set.displayWeight
            allMatch = subsequentSets.allSatisfy { $0.displayWeight == currentWeight }
        case .reps:
            let currentReps = set.displayReps
            allMatch = subsequentSets.allSatisfy { $0.displayReps == currentReps }
        case .rir:
            let currentRir = set.displayRir
            allMatch = subsequentSets.allSatisfy { $0.displayRir == currentRir }
        case .done:
            return .thisOnly
        }
        
        return allMatch ? .remaining : .thisOnly
    }
    
    /// Dismiss/Done button (closes editor, does NOT mark set complete)
    private var dockDoneButton: some View {
        Button(action: onDismiss) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.textInverse)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    var body: some View {
        VStack(spacing: Space.sm) {
            // Scope selector (only for working sets)
            if !isWarmup && (selectedCell.isWeight || selectedCell.isReps) {
                scopeSelector
            }

            // RIR pills need vertical layout to avoid overflow
            if selectedCell.isRir {
                VStack(spacing: Space.sm) {
                    valueEditor
                    HStack {
                        Spacer()
                        dockDoneButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: Space.md) {
                    valueEditor
                    Spacer()
                    dockDoneButton
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Color.surfaceElevated.opacity(0.95))
        .onAppear {
            // Set smart default scope on first appear
            if !hasComputedDefaultScope {
                editScope = smartDefaultScope
                hasComputedDefaultScope = true
            }
            // Auto-focus text field for weight/reps when dock opens
            // Start empty so typing replaces the value (current value shown as placeholder)
            switch selectedCell {
            case .weight, .reps:
                textInputValue = ""
                isEditingText = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    textFieldFocused = true
                }
            case .rir, .done:
                break
            }
        }
        .onDisappear {
            // Auto-save: commit any pending text input when switching cells
            if isEditingText { commitTextInput() }
        }
    }
    
    // MARK: - Scope Selector
    
    /// Counts for the scope segmented control (live updates)
    private var scopeCounts: (this: Int, remaining: Int, all: Int) {
        let workingSets = allSets.filter { !$0.isWarmup }
        let currentWorkingIndex = workingSets.firstIndex { $0.id == set.id } ?? 0
        // Remaining = sets after current one (including current for 1-based UX)
        let remainingCount = workingSets.count - currentWorkingIndex
        return (this: 1, remaining: remainingCount, all: workingSets.count)
    }
    
    private var scopeSelector: some View {
        HStack(spacing: Space.xs) {
            Text("Apply to:")
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
            
            ScopeSegmentedControl(
                selectedScope: $editScope,
                thisCount: scopeCounts.this,
                remainingCount: scopeCounts.remaining,
                allCount: scopeCounts.all
            )
            
            Spacer()
        }
    }
    
    // MARK: - Value Editor
    
    @ViewBuilder
    private var valueEditor: some View {
        switch selectedCell {
        case .weight:
            weightEditor
        case .reps:
            repsEditor
        case .rir:
            rirEditor
        case .done:
            EmptyView()
        }
    }
    
    private var weightEditor: some View {
        HStack(spacing: Space.md) {
            stepButton(systemName: "minus", disabled: (set.displayWeight ?? 0) <= 0) {
                textInputValue = ""  // Discard partial input; placeholder shows new value
                let currentDisplay = WeightFormatter.display(set.displayWeight ?? 0, unit: weightUnit)
                let newDisplay = currentDisplay - WeightFormatter.plateIncrement(unit: weightUnit)
                let newKg = WeightFormatter.toKg(max(0, newDisplay), from: weightUnit)
                applyValueChange("weight", max(0, newKg))
            }

            // Tappable value → TextField for direct keyboard input
            if isEditingText {
                VStack(spacing: 0) {
                    TextField(formatWeight(set.displayWeight), text: $textInputValue)
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .focused($textFieldFocused)
                        .frame(width: 80)
                        .onSubmit { commitTextInput() }
                        .onChange(of: textFieldFocused) { _, focused in
                            if !focused { commitTextInput() }
                        }
                    Text(weightUnit.label)
                        .font(.system(size: 11))
                        .foregroundColor(Color.textSecondary)
                }
                .frame(width: 90)
            } else {
                Button {
                    textInputValue = ""
                    isEditingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        textFieldFocused = true
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text(formatWeight(set.displayWeight))
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                        Text(weightUnit.label)
                            .font(.system(size: 12))
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(width: 80)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.surfaceElevated.opacity(0.5))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            stepButton(systemName: "plus", disabled: false) {
                textInputValue = ""  // Discard partial input; placeholder shows new value
                let currentDisplay = WeightFormatter.display(set.displayWeight ?? 0, unit: weightUnit)
                let newDisplay = currentDisplay + WeightFormatter.plateIncrement(unit: weightUnit)
                let newKg = WeightFormatter.toKg(newDisplay, from: weightUnit)
                applyValueChange("weight", newKg)
            }
        }
    }
    
    private var repsEditor: some View {
        HStack(spacing: Space.md) {
            stepButton(systemName: "minus", disabled: (set.displayReps ?? 1) <= 1) {
                textInputValue = ""  // Discard partial input; placeholder shows new value
                let newValue = (set.displayReps ?? 10) - 1
                applyValueChange("reps", max(1, newValue))
            }

            // Tappable value → TextField for direct keyboard input
            if isEditingText {
                VStack(spacing: 0) {
                    TextField("\(set.displayReps ?? 10)", text: $textInputValue)
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .focused($textFieldFocused)
                        .frame(width: 70)
                        .onSubmit { commitTextInput() }
                        .onChange(of: textFieldFocused) { _, focused in
                            if !focused { commitTextInput() }
                        }
                    Text("reps")
                        .font(.system(size: 11))
                        .foregroundColor(Color.textSecondary)
                }
                .frame(width: 80)
            } else {
                Button {
                    textInputValue = ""
                    isEditingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        textFieldFocused = true
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text("\(set.displayReps ?? 10)")
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                        Text("reps")
                            .font(.system(size: 12))
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(width: 70)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.surfaceElevated.opacity(0.5))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            stepButton(systemName: "plus", disabled: (set.displayReps ?? 0) >= 30) {
                textInputValue = ""  // Discard partial input; placeholder shows new value
                let newValue = (set.displayReps ?? 10) + 1
                applyValueChange("reps", min(30, newValue))
            }
        }
    }
    
    // MARK: - Value Change (respects scope)
    
    /// Apply value change based on the selected scope
    private func applyValueChange(_ field: String, _ value: Any) {
        if isWarmup {
            // Warmups always apply to this only
            onValueChange(field, value)
        } else {
            // Working sets use the selected scope
            onBatchValueChange(field, value, editScope)
        }
    }
    
    // MARK: - Text Input Commit
    
    private func commitTextInput() {
        isEditingText = false
        textFieldFocused = false

        let trimmed = textInputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch selectedCell {
        case .weight:
            if let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
                // User input is in their display unit - convert to kg for storage
                let kg = WeightFormatter.toKg(value, from: weightUnit)
                let rounded = (kg * 4).rounded() / 4  // Round to nearest 0.25kg
                applyValueChange("weight", max(0, rounded))
            }
        case .reps:
            if let value = Int(trimmed) {
                applyValueChange("reps", min(30, max(1, value)))
            }
        default:
            break
        }

        textInputValue = ""
    }
    
    private var rirEditor: some View {
        HStack(spacing: Space.sm) {
            ForEach(0...5, id: \.self) { rir in
                Button {
                    onValueChange("rir", rir)
                    HapticManager.selectionTick()
                } label: {
                    Text("\(rir)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(set.displayRir == rir ? .textInverse : Color.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(set.displayRir == rir ? rirColor(rir) : Color.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    // MARK: - Helpers
    
    /// Smaller, quieter +/- controls (spec #9: value dominates, controls recede)
    private func stepButton(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            HapticManager.selectionTick()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(disabled ? Color.textSecondary.opacity(0.3) : Color.accent)
                .frame(width: 40, height: 40)
                .background(Color.surfaceElevated.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
    
    private func formatWeight(_ weight: Double?) -> String {
        WeightFormatter.formatValue(weight, unit: weightUnit)
    }

    private func rirColor(_ rir: Int) -> Color {
        switch rir {
        case 0: return Color.destructive
        case 1: return Color.warning
        case 2: return Color.accent
        default: return Color.textSecondary
        }
    }
}

// MARK: - Set Type Picker Sheet

struct FocusModeSetTypePickerSheet: View {
    let setId: String
    let exerciseId: String
    let currentType: FocusModeSetType
    let isFailure: Bool
    let onSelectType: (FocusModeSetType) -> Void
    let onToggleFailure: (Bool) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Set Type")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.sm)
                
                VStack(spacing: 0) {
                    setTypeOption(type: .warmup, title: "Warm-up", icon: "flame", color: Color.textSecondary)
                    Divider().padding(.leading, 56)
                    setTypeOption(type: .working, title: "Working Set", icon: "dumbbell", color: Color.accent)
                    Divider().padding(.leading, 56)
                    setTypeOption(type: .dropset, title: "Drop Set", icon: "arrow.down.circle", color: Color.warning)
                }
                .background(Color.surface)
                
                // Failure toggle (separate from set type)
                Text("Modifiers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.sm)
                
                VStack(spacing: 0) {
                    Button {
                        onToggleFailure(!isFailure)
                    } label: {
                        HStack(spacing: Space.md) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 18))
                                .foregroundColor(Color.destructive)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Failure")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Color.textPrimary)
                                Text("Mark this set as taken to failure")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.textSecondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: isFailure ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundColor(isFailure ? Color.destructive : Color.textSecondary.opacity(0.3))
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .background(Color.surface)
                
                Spacer()
            }
            .background(Color.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    private func setTypeOption(type: FocusModeSetType, title: String, icon: String, color: Color) -> some View {
        Button {
            onSelectType(type)
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
                    .frame(width: 32)
                
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color.textPrimary)
                
                Spacer()
                
                if currentType == type {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.accent)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Preview

#Preview {
    FocusModeSetGrid(
        exercise: FocusModeExercise(
            instanceId: "ex1",
            exerciseId: "bench-press",
            name: "Bench Press",
            position: 0,
            sets: [
                FocusModeSet(id: "s1", setType: .warmup, status: .done, targetWeight: 40, targetReps: 10, weight: 40, reps: 10),
                FocusModeSet(id: "s2", setType: .working, status: .done, targetWeight: 70, targetReps: 8, targetRir: 2, weight: 70, reps: 8, rir: 2),
                FocusModeSet(id: "s3", setType: .working, status: .planned, targetWeight: 70, targetReps: 8, targetRir: 2),
                FocusModeSet(id: "s4", setType: .working, status: .planned, targetWeight: 70, targetReps: 8, targetRir: 2)
            ]
        ),
        selectedCell: .constant(nil),
        onLogSet: { _, _, _, _, _ in },
        onPatchField: { _, _, _, _ in },
        onAddSet: { },
        onRemoveSet: { _ in }
    )
    .padding()
    .background(Color.bg)
}
