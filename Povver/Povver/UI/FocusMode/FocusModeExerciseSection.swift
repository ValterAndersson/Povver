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
    let density: ExerciseDensity
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

    /// Last session data for inline performance KPIs (best e1RM, last weight/reps)
    var lastSessionData: LastSessionExerciseData? = nil

    /// Whether this is the last exercise in the workout (for progressive haptic intensity)
    var isLastExercise: Bool = false

    /// Manual expansion override for completed exercises (tappable to expand)
    @State private var isExpandedOverride = false

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

    /// Whether to show compressed view: completed density unless manually expanded
    private var showCompressed: Bool {
        density == .completed && !isExpandedOverride
    }

    private var weightUnit: WeightUnit { UserService.shared.activeWorkoutWeightUnit }

    /// e.g. "120 kg" — total volume across completed working sets
    private var completedVolumeSummary: String {
        let totalKg = exercise.sets
            .filter { $0.isDone && !$0.isWarmup }
            .reduce(0.0) { $0 + ($1.weight ?? 0) * Double($1.reps ?? 0) }
        return WeightFormatter.formatValue(totalKg, unit: weightUnit) + " " + weightUnit.label
    }

    /// e.g. "32 reps" — total reps across completed working sets
    private var completedRepsSummary: String {
        let totalReps = exercise.sets
            .filter { $0.isDone && !$0.isWarmup }
            .reduce(0) { $0 + ($1.reps ?? 0) }
        return "\(totalReps) reps"
    }

    var body: some View {
        Group {
            if showCompressed {
                completedCompressedRow
            } else {
                fullExerciseContent
                    .opacity(density == .upcoming ? 0.6 : 1.0)
            }
        }
        .onChange(of: density) { oldDensity, newDensity in
            // Fire haptic when exercise transitions to completed
            if oldDensity != .completed && newDensity == .completed {
                HapticManager.modeToggle()
            }
            // Reset expansion override when density changes away from completed
            if newDensity != .completed {
                isExpandedOverride = false
            }
        }
    }

    /// Full exercise content (active/upcoming/expanded-completed)
    private var fullExerciseContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Exercise Header
            exerciseHeader

            // Inline performance KPIs (from last session data)
            if let kpiData = lastSessionData, isActive {
                inlineKPIs(data: kpiData)
            }

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
                ghostValues: ghostValues,
                isLastExercise: isLastExercise
            )
        }
    }

    /// Compressed summary row for completed exercises
    private var completedCompressedRow: some View {
        Button {
            withAnimation(MotionToken.snappy) {
                isExpandedOverride = true
            }
        } label: {
            HStack(spacing: 0) {
                // Emerald left-edge bar
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .revealEffect(isVisible: density == .completed)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name)
                            .textStyle(.bodyStrong)
                            .foregroundColor(Color.textPrimary)

                        HStack(spacing: Space.sm) {
                            Text("\(exercise.completedSetsCount)/\(exercise.totalWorkingSetsCount) sets")
                            Text("·")
                            Text(completedVolumeSummary)
                            Text("·")
                            Text(completedRepsSummary)
                        }
                        .textStyle(.caption)
                        .foregroundColor(Color.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.success)
                        .font(.system(size: 20))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.textTertiary)
                        .padding(.leading, Space.xs)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
            }
        }
        .buttonStyle(PlainButtonStyle())
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

                // Collapse button for manually-expanded completed exercises
                if isExpandedOverride {
                    Button {
                        withAnimation(MotionToken.snappy) {
                            isExpandedOverride = false
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.textTertiary)
                            .frame(width: 32, height: 32)
                    }
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
                        // Tier 1: immediate removal, undo via toast (no confirmation dialog)
                        onRemoveExercise()
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
    }

    // MARK: - Inline Performance KPIs

    private func inlineKPIs(data: LastSessionExerciseData) -> some View {
        let lastWeight = data.sets.last?.weight
        let lastReps = data.sets.last?.reps

        return HStack(spacing: Space.md) {
            if let e1rm = data.bestE1rm {
                kpiLabel("e1RM", value: WeightFormatter.formatValue(e1rm, unit: weightUnit))
            }
            if let w = lastWeight {
                kpiLabel("Last", value: WeightFormatter.formatValue(w, unit: weightUnit))
            }
            if let r = lastReps {
                kpiLabel("Reps", value: "\(r)")
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.xs)
    }

    private func kpiLabel(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(Color.textSecondary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.textTertiary)
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
