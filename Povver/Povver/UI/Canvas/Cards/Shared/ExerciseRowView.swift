import SwiftUI

/// Unified exercise row with expandable sets grid
/// Used by both SessionPlanCard and RoutineSummaryCard
/// 
/// v1.1 Update: Uses ExerciseSection for consistent header/container styling.
/// Menu actions (info, swap, remove) are now in the trailing header menu
/// instead of a separate ExerciseActionsRow chip cluster.
public struct ExerciseRowView: View {
    let exerciseIndex: Int
    @Binding var exercises: [PlanExercise]
    @Binding var selectedCell: GridCellField?
    let isExpanded: Bool
    let isPlanningMode: Bool
    let showDivider: Bool
    
    // Callbacks
    let onToggleExpand: () -> Void
    let onSwap: (PlanExercise, ExerciseActionsRow.SwapReason) -> Void
    let onInfo: (PlanExercise) -> Void
    let onRemove: ((Int) -> Void)?  // Optional - not always available
    
    // Warmup collapse state (managed externally)
    @Binding var warmupCollapsed: Bool
    
    // Swap sheet state (for manual swap)
    @State private var showSwapSheet = false
    
    private var exercise: PlanExercise? {
        exercises[safe: exerciseIndex]
    }
    
    /// Build menu items based on available actions
    private var menuItems: [ExerciseMenuItem] {
        var items: [ExerciseMenuItem] = [.info, .swap]
        if onRemove != nil {
            items.append(.remove)
        }
        return items
    }
    
    public var body: some View {
        if let exercise = exercise {
            VStack(spacing: 0) {
                // Collapsed: Compact row with expand chevron
                if !isExpanded {
                    collapsedRow(exercise: exercise)
                } else {
                    // Expanded: ExerciseSection with SetGridView content
                    expandedSection(exercise: exercise)
                }
                
                // Divider
                if showDivider && !isExpanded {
                    Rectangle()
                        .fill(Color.separatorLine.opacity(0.5))
                        .frame(height: 1)
                        .padding(.leading, Space.md)
                }
            }
            .confirmationDialog("Swap Exercise", isPresented: $showSwapSheet, titleVisibility: .visible) {
                swapOptionsSheet(exercise: exercise)
            }
        }
    }
    
    // MARK: - Collapsed Row (tap to expand)
    
    private func collapsedRow(exercise: PlanExercise) -> some View {
        Button(action: onToggleExpand) {
            HStack(spacing: Space.sm) {
                // Exercise name and prescription
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.textPrimary)
                    
                    // Summary line
                    Text(exercise.summaryLine)
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                }
                
                Spacer()
                
                // Expand chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.textSecondary.opacity(0.5))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, Space.sm)
            .background(Color.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Expanded Section (ExerciseSection + SetGridView)
    
    private func expandedSection(exercise: PlanExercise) -> some View {
        VStack(spacing: 0) {
            // Collapse header - tappable to collapse
            Button(action: onToggleExpand) {
                HStack(spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.textPrimary)
                        
                        Text(exercise.summaryLine)
                            .font(.system(size: 13))
                            .foregroundColor(Color.textSecondary)
                    }
                    
                    Spacer()
                    
                    // Menu for actions (replaces ExerciseActionsRow chips)
                    Menu {
                        Button {
                            onInfo(exercise)
                        } label: {
                            Label("Exercise Info", systemImage: "info.circle")
                        }
                        
                        Button {
                            showSwapSheet = true
                        } label: {
                            Label("Swap Exercise", systemImage: "arrow.triangle.2.circlepath")
                        }
                        
                        if onRemove != nil {
                            Divider()
                            Button(role: .destructive) {
                                onRemove?(exerciseIndex)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    
                    // Collapse chevron
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(Color.surfaceElevated.opacity(0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            // SetGridView for inline editing (unchanged)
            SetGridView(
                sets: Binding(
                    get: { exercises[safe: exerciseIndex]?.sets ?? [] },
                    set: { newSets in
                        if exercises.indices.contains(exerciseIndex) {
                            exercises[exerciseIndex].sets = newSets
                        }
                    }
                ),
                selectedCell: $selectedCell,
                exerciseName: exercise.name,
                warmupCollapsed: warmupCollapsed,
                isPlanningMode: isPlanningMode,
                onWarmupToggle: { warmupCollapsed.toggle() },
                onAddSet: { setType in
                    addSet(type: setType)
                },
                onDeleteSet: { setIdx in
                    deleteSet(at: setIdx)
                },
                onUndoDelete: nil  // TODO: Implement undo
            )
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .stroke(Color.separatorLine, lineWidth: 0.5)
        )
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xs)
    }
    
    // MARK: - Swap Options Sheet
    
    @ViewBuilder
    private func swapOptionsSheet(exercise: PlanExercise) -> some View {
        Button("Same muscles, different equipment") {
            onSwap(exercise, .sameMuscles)
        }
        Button("Same equipment, different angle") {
            onSwap(exercise, .sameEquipment)
        }
        Button("Different movement pattern") {
            onSwap(exercise, .differentAngle)
        }
        Button("Coach's pick") {
            onSwap(exercise, .aiSuggestion)
        }
        Button("Search exercises...") {
            onSwap(exercise, .manualSearch)
        }
        Button("Cancel", role: .cancel) {}
    }
    
    // MARK: - Set Operations
    
    private func addSet(type: SetType) {
        guard exercises.indices.contains(exerciseIndex) else { return }
        
        if let lastSet = exercises[exerciseIndex].sets.last {
            let newSet = PlanSet(
                type: type,
                reps: type == .warmup ? 10 : lastSet.reps,
                weight: lastSet.weight,
                rir: type == .warmup ? nil : lastSet.rir
            )
            exercises[exerciseIndex].sets.append(newSet)
        } else {
            let newSet = PlanSet(
                type: type,
                reps: type == .warmup ? 10 : 8,
                weight: nil,
                rir: type == .warmup ? nil : 2
            )
            exercises[exerciseIndex].sets.append(newSet)
        }
    }
    
    private func deleteSet(at setIndex: Int) {
        guard exercises.indices.contains(exerciseIndex),
              exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        
        exercises[exerciseIndex].sets.remove(at: setIndex)
        selectedCell = nil
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            if let newValue = newValue, indices.contains(index) {
                self[index] = newValue
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ExerciseRowView_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State private var exercises: [PlanExercise] = [
            PlanExercise(name: "Bench Press", sets: [
                PlanSet(type: .warmup, reps: 10, weight: 40, rir: nil),
                PlanSet(type: .working, reps: 8, weight: 80, rir: 2),
                PlanSet(type: .working, reps: 8, weight: 80, rir: 2),
                PlanSet(type: .working, reps: 8, weight: 80, rir: 1)
            ])
        ]
        @State private var selectedCell: GridCellField? = nil
        @State private var isExpanded = true
        @State private var warmupCollapsed = true
        
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    ExerciseRowView(
                        exerciseIndex: 0,
                        exercises: $exercises,
                        selectedCell: $selectedCell,
                        isExpanded: isExpanded,
                        isPlanningMode: true,
                        showDivider: false,
                        onToggleExpand: { isExpanded.toggle() },
                        onSwap: { ex, reason in print("Swap \(ex.name) - \(reason)") },
                        onInfo: { ex in print("Info for \(ex.name)") },
                        onRemove: { idx in print("Remove at \(idx)") },
                        warmupCollapsed: $warmupCollapsed
                    )
                }
                .padding()
            }
            .background(Color.bg)
        }
    }
    
    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
