/**
 * FocusModeExerciseSection.swift
 *
 * Exercise section views for the workout execution screen.
 * Extracted from FocusModeWorkoutScreen.swift to reduce file size.
 *
 * Contains:
 * - FocusModeExerciseSection: Legacy exercise card with inline AI action buttons
 * - FocusModeExerciseSectionNew: Current exercise card with ActionRail and screenMode binding
 */

import SwiftUI

struct FocusModeExerciseSection: View {
    let exercise: FocusModeExercise
    @Binding var selectedCell: FocusModeGridCell?

    let onLogSet: (String, String, Double?, Int, Int?) -> Void
    let onPatchField: (String, String, String, Any) -> Void
    let onAddSet: () -> Void
    let onRemoveSet: (String) -> Void
    let onAutofill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Exercise Header
            exerciseHeader

            // AI Actions Row (non-intrusive)
            aiActionsRow

            // Set Grid - EXPANDED by default, using full width
            FocusModeSetGrid(
                exercise: exercise,
                selectedCell: $selectedCell,
                onLogSet: onLogSet,
                onPatchField: onPatchField,
                onAddSet: onAddSet,
                onRemoveSet: onRemoveSet
            )
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .padding(.top, Space.md)
    }

    private var exerciseHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .textStyle(.bodyStrong)
                    .foregroundColor(Color.textPrimary)

                Text("\(exercise.completedSetsCount)/\(exercise.totalWorkingSetsCount) sets")
                    .textStyle(.caption)
                    .foregroundColor(Color.textSecondary)
            }

            Spacer()

            // Progress indicator
            if exercise.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color.success)
                    .font(.system(size: 20))
            }

            // More menu
            Menu {
                Button { onAutofill() } label: {
                    Label("Auto-fill Sets", systemImage: "sparkles")
                }
                Button(role: .destructive) {
                    // TODO: Remove exercise
                } label: {
                    Label("Remove Exercise", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundColor(Color.textSecondary)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private var aiActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                aiActionButton(icon: "sparkles", label: "Auto-fill") {
                    onAutofill()
                }
                aiActionButton(icon: "arrow.up", label: WeightFormatter.incrementLabel(unit: UserService.shared.activeWorkoutWeightUnit)) {
                    // Suggest weight increase
                }
                aiActionButton(icon: "clock.arrow.circlepath", label: "Last Time") {
                    // Use last performance
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
        }
    }

    private func aiActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .textStyle(.micro).fontWeight(.medium)
            }
            .foregroundColor(Color.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accent.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Exercise Section New (with ActionRail and screenMode binding)

struct FocusModeExerciseSectionNew: View {
    let exercise: FocusModeExercise
    let isActive: Bool
    @Binding var screenMode: FocusModeScreenMode

    let onLogSet: (String, String, Double?, Int, Int?) -> Void
    let onPatchField: (String, String, String, Any) -> Void
    let onAddSet: () -> Void
    let onRemoveSet: (String) -> Void
    let onRemoveExercise: () -> Void
    let onAutofill: () -> Void
    var onShowDetails: (() -> Void)? = nil
    var onShowPerformance: (() -> Void)? = nil
    var onEditNote: (() -> Void)? = nil
    var onSwapExercise: (() -> Void)? = nil

    /// Ghost values for undone sets, resolved from last session or template prescription
    var ghostValues: [String: GhostValues] = [:]

    @State private var showRemoveConfirmation = false

    /// Derive selectedCell from screenMode for this exercise
    private var selectedCell: Binding<FocusModeGridCell?> {
        Binding(
            get: {
                if case .editingSet(let exerciseId, let setId, let cellType) = screenMode,
                   exerciseId == exercise.instanceId {
                    switch cellType {
                    case .weight: return .weight(exerciseId: exerciseId, setId: setId)
                    case .reps: return .reps(exerciseId: exerciseId, setId: setId)
                    case .rir: return .rir(exerciseId: exerciseId, setId: setId)
                    }
                }
                return nil
            },
            set: { newValue in
                if let cell = newValue {
                    let cellType: FocusModeEditCellType
                    switch cell {
                    case .weight: cellType = .weight
                    case .reps: cellType = .reps
                    case .rir: cellType = .rir
                    case .done: cellType = .weight
                    }
                    screenMode = .editingSet(exerciseId: cell.exerciseId, setId: cell.setId, cellType: cellType)
                } else {
                    screenMode = .normal
                }
            }
        )
    }

    /// Build action items for the ActionRail
    private var actionItems: [ActionItem] {
        [
            ActionItem(
                icon: "sparkles",
                label: "Auto-fill",
                priority: .coach,
                isPrimary: true,
                action: onAutofill
            ),
            ActionItem(
                icon: "arrow.up",
                label: WeightFormatter.incrementLabel(unit: UserService.shared.activeWorkoutWeightUnit),
                priority: .utility,
                isPrimary: false,
                action: { /* TODO: Suggest weight increase */ }
            ),
            ActionItem(
                icon: "clock.arrow.circlepath",
                label: "Last Time",
                priority: .utility,
                isPrimary: false,
                action: { /* TODO: Use last performance */ }
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Exercise Header
            exerciseHeader

            // Action Rail (structured AI actions)
            ActionRail(
                actions: actionItems,
                isActive: isActive,
                onMoreTap: { /* TODO: Show more actions sheet */ }
            )

            // Set Grid with warmup divider
            FocusModeSetGrid(
                exercise: exercise,
                selectedCell: selectedCell,
                onLogSet: onLogSet,
                onPatchField: onPatchField,
                onAddSet: onAddSet,
                onRemoveSet: onRemoveSet,
                onToggleAllDone: {
                    let allDone = exercise.sets.filter({ !$0.isWarmup }).allSatisfy { $0.isDone }
                    if allDone {
                        // Undo all: patch each working set to planned
                        for s in exercise.sets where !s.isWarmup {
                            onPatchField(exercise.instanceId, s.id, "status", "planned")
                        }
                    } else {
                        // Log all undone working sets, using ghost values as fallback
                        for s in exercise.sets where !s.isWarmup && !s.isDone {
                            let ghost = ghostValues[s.id]
                            let weight = s.displayWeight ?? ghost?.weight
                            let reps = s.displayReps ?? ghost?.reps ?? 10
                            let rir = s.displayRir ?? ghost?.rir
                            onLogSet(exercise.instanceId, s.id, weight, reps, rir)
                        }
                    }
                },
                ghostValues: ghostValues
            )
        }
    }

    private var exerciseHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .textStyle(.bodyStrong)
                        .foregroundColor(Color.textPrimary)

                    Text("\(exercise.completedSetsCount)/\(exercise.totalWorkingSetsCount) sets")
                        .textStyle(.caption)
                        .foregroundColor(Color.textSecondary)
                }

                Spacer()

                // Progress indicator
                if exercise.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.success)
                        .font(.system(size: 20))
                }

                // More menu
                Menu {
                    Button { onAutofill() } label: {
                        Label("Auto-fill Sets", systemImage: "sparkles")
                    }
                    if let onEditNote {
                        Button { onEditNote() } label: {
                            Label(exercise.notes != nil ? "Edit Note" : "Add Note", systemImage: "note.text")
                        }
                    }
                    if let onShowDetails {
                        Button { onShowDetails() } label: {
                            Label("Exercise Info", systemImage: "info.circle")
                        }
                    }
                    if let onShowPerformance {
                        Button { onShowPerformance() } label: {
                            Label("Performance", systemImage: "chart.line.uptrend.xyaxis")
                        }
                    }
                    if let onSwapExercise {
                        Button { onSwapExercise() } label: {
                            Label("Swap Exercise", systemImage: "arrow.triangle.swap")
                        }
                    }
                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Label("Remove Exercise", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundColor(Color.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)

            // Exercise note preview (single-line truncated)
            if let notes = exercise.notes, let onEditNote {
                Button { onEditNote() } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "note.text")
                            .font(.system(size: 11))
                            .foregroundColor(Color.textTertiary)
                        Text(notes)
                            .textStyle(.caption)
                            .foregroundColor(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, Space.xs)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .confirmationDialog("Remove \(exercise.name)?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                onRemoveExercise()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the exercise and all its sets from this workout.")
        }
    }
}

// MARK: - Grid Cell Selection

enum FocusModeGridCell: Equatable, Hashable {
    case weight(exerciseId: String, setId: String)
    case reps(exerciseId: String, setId: String)
    case rir(exerciseId: String, setId: String)
    case done(exerciseId: String, setId: String)

    var exerciseId: String {
        switch self {
        case .weight(let id, _), .reps(let id, _), .rir(let id, _), .done(let id, _):
            return id
        }
    }

    var setId: String {
        switch self {
        case .weight(_, let id), .reps(_, let id), .rir(_, let id), .done(_, let id):
            return id
        }
    }

    var isWeight: Bool {
        if case .weight = self { return true }
        return false
    }

    var isReps: Bool {
        if case .reps = self { return true }
        return false
    }

    var isRir: Bool {
        if case .rir = self { return true }
        return false
    }
}
