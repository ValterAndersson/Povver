import SwiftUI

/// A coaching-first workout plan display.
/// Uses shared components for consistent editing experience with RoutineSummaryCard.
public struct SessionPlanCard: View {
    private let model: CanvasCardModel
    @State private var editableExercises: [PlanExercise] = []
    @State private var exerciseForDetail: PlanExercise? = nil
    @State private var exerciseForSwap: PlanExercise? = nil  // For ExerciseSwapSheet
    @State private var showingActionsSheet = false
    @State private var expandedExerciseId: String? = nil
    @State private var warmupCollapsed: [String: Bool] = [:]
    @State private var selectedCell: GridCellField? = nil
    
    @Environment(\.cardActionHandler) private var handleAction
    
    public init(model: CanvasCardModel) {
        self.model = model
    }
    
    // MARK: - Computed
    
    private var totalSets: Int {
        editableExercises.reduce(0) { $0 + $1.setCount }
    }
    
    private var estimatedMinutes: Int {
        max(20, totalSets * 2 + 5)
    }
    
    private var focusSummary: String? {
        let muscles = editableExercises.compactMap { $0.primaryMuscles }.flatMap { $0 }
        let counts = Dictionary(grouping: muscles, by: { $0 }).mapValues { $0.count }
        if let top = counts.max(by: { $0.value < $1.value })?.key {
            return "\(top.capitalized) biased"
        }
        return nil
    }
    
    private var statusText: String {
        switch model.status {
        case .proposed: return "Proposed"
        case .accepted: return "Ready"
        case .active: return "In Progress"
        case .completed: return "Done"
        case .rejected: return "Dismissed"
        case .expired: return "Expired"
        }
    }
    
    private var statusColor: Color {
        switch model.status {
        case .proposed: return Color.accent
        case .accepted, .completed: return Color.success
        case .active: return Color.warning
        case .rejected, .expired: return Color.textSecondary
        }
    }
    
    // MARK: - Body
    
    public var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Title with inline status
            titleRow
            
            // Summary line
            summaryLine
            
            // Iteration actions using shared component
            if model.status == .proposed {
                IterationActionsRow(
                    context: .workout,
                    onAdjust: { instruction in
                        fireAdjustment(instruction)
                    }
                )
            }
            
            // Divider
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
            
            // Exercise list using shared ExerciseRowView
            exerciseList
            
            // Primary action
            if model.status == .proposed {
                acceptButton
            }
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        .onAppear {
            if case .sessionPlan(let exercises) = model.data {
                editableExercises = exercises
            }
        }
        .onChange(of: model.data) { _, newData in
            if case .sessionPlan(let exercises) = newData {
                editableExercises = exercises
            }
        }
        .sheet(item: $exerciseForDetail) { exercise in
            ExerciseDetailSheet(
                exerciseId: exercise.exerciseId,
                exerciseName: exercise.name,
                onDismiss: { exerciseForDetail = nil }
            )
        }
        .sheet(item: $exerciseForSwap) { exercise in
            ExerciseSwapSheet(
                currentExercise: exercise,
                onSwapWithAI: { reason, instruction in
                    handleAISwap(exercise: exercise, reason: reason, instruction: instruction)
                },
                onSwapManual: { replacement in
                    handleManualSwap(exercise: exercise, with: replacement)
                },
                onDismiss: { exerciseForSwap = nil }
            )
        }
        .confirmationDialog("Plan Actions", isPresented: $showingActionsSheet, titleVisibility: .hidden) {
            planActionsSheet
        }
    }
    
    // MARK: - Title Row
    
    private var titleRow: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .center, spacing: Space.sm) {
                Text(model.title ?? "Workout")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.textPrimary)
                
                // Status pill
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
                
                Spacer()
                
                Button { showingActionsSheet = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            if let coachNotes = model.meta?.notes, !coachNotes.isEmpty {
                Text(coachNotes)
                    .font(.system(size: 13))
                    .foregroundColor(Color.textSecondary)
                    .lineLimit(1)
            }
        }
    }
    
    // MARK: - Summary Line
    
    private var summaryLine: some View {
        HStack(spacing: Space.sm) {
            summaryPill("\(editableExercises.count) exercises")
            summaryPill("\(totalSets) sets")
            summaryPill("~\(estimatedMinutes) min")
            if let focus = focusSummary {
                summaryPill(focus)
            }
        }
    }
    
    private func summaryPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color.textSecondary)
    }
    
    // MARK: - Exercise List (using shared ExerciseRowView)
    
    private var exerciseList: some View {
        VStack(spacing: 0) {
            ForEach(Array(editableExercises.indices), id: \.self) { index in
                let exercise = editableExercises[index]
                let isExpanded = expandedExerciseId == exercise.id
                
                ExerciseRowView(
                    exerciseIndex: index,
                    exercises: $editableExercises,
                    selectedCell: $selectedCell,
                    isExpanded: isExpanded,
                    isPlanningMode: model.status == .proposed || model.status == .accepted,
                    showDivider: index < editableExercises.count - 1,
                    onToggleExpand: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            expandedExerciseId = isExpanded ? nil : exercise.id
                        }
                    },
                    onSwap: { ex, reason in
                        handleSwapRequest(exercise: ex, reason: reason)
                    },
                    onInfo: { ex in
                        exerciseForDetail = ex
                    },
                    onRemove: { exIdx in
                        removeExercise(at: exIdx)
                    },
                    warmupCollapsed: Binding(
                        get: { warmupCollapsed[exercise.id] ?? true },
                        set: { warmupCollapsed[exercise.id] = $0 }
                    )
                )
            }
        }
    }
    
    // MARK: - Swap Handling
    
    private func handleSwapRequest(exercise: PlanExercise, reason: ExerciseActionsRow.SwapReason) {
        if reason == .manualSearch {
            exerciseForSwap = exercise
        } else {
            let (instruction, _) = ExerciseActionsRow.buildSwapInstruction(
                exercise: exercise,
                reason: reason
            )
            handleAISwap(exercise: exercise, reason: reason, instruction: instruction)
        }
    }
    
    private func handleAISwap(exercise: PlanExercise, reason: ExerciseActionsRow.SwapReason, instruction: String) {
        let action = CardAction(
            kind: "swap_exercise",
            label: "Swap",
            payload: [
                "instruction": instruction,
                "exercise_name": exercise.name,
                "swap_reason": reason.rawValue,
                "current_plan": serializePlanForAgent()
            ]
        )
        handleAction(action, model)
    }
    
    private func handleManualSwap(exercise: PlanExercise, with replacement: Exercise) {
        if let index = editableExercises.firstIndex(where: { $0.id == exercise.id }) {
            let newExercise = PlanExercise(
                exerciseId: replacement.id,
                name: replacement.name,
                sets: exercise.sets,
                primaryMuscles: replacement.primaryMuscles,
                equipment: replacement.equipment.first  // Exercise has [String], PlanExercise has String?
            )
            editableExercises[index] = newExercise
        }
    }
    
    private func removeExercise(at index: Int) {
        _ = withAnimation(.easeOut(duration: 0.2)) {
            editableExercises.remove(at: index)
        }
    }
    
    // MARK: - Action Buttons
    
    private var acceptButton: some View {
        HStack(spacing: Space.sm) {
            // Save as Template (Secondary)
            Button {
                let action = CardAction(kind: "save_as_template", label: "Save as Template", style: .secondary, payload: serializePlan())
                handleAction(action, model)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                    Text("Save Template")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(Color.accent)
                .background(Color.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
            
            // Start Workout (Primary)
            Button {
                let action = CardAction(kind: "accept_plan", label: "Accept", style: .primary, payload: serializePlan())
                handleAction(action, model)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start Workout")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accent)
                .foregroundColor(.textInverse)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - Plan Actions Sheet
    
    @ViewBuilder
    private var planActionsSheet: some View {
        Button("Dismiss Plan", role: .destructive) {
            let action = CardAction(kind: "dismiss", label: "Dismiss", style: .destructive)
            handleAction(action, model)
        }
        Button("Report Issue", role: .none) {
            // TODO: Implement feedback
        }
        Button("Cancel", role: .cancel) {}
    }
    
    // MARK: - Actions
    
    private func fireAdjustment(_ instruction: String) {
        let action = CardAction(
            kind: "adjust_plan",
            label: instruction,
            payload: [
                "instruction": instruction,
                "current_plan": serializePlanForAgent()
            ]
        )
        handleAction(action, model)
    }
    
    private func serializePlan() -> [String: String] {
        guard let data = try? JSONEncoder().encode(editableExercises),
              let json = String(data: data, encoding: .utf8) else { return [:] }
        return ["exercises_json": json]
    }
    
    private func serializePlanForAgent() -> String {
        editableExercises.enumerated().map { i, ex in
            "\(i + 1). \(ex.name) — \(ex.summaryLine)"
        }.joined(separator: "\n")
    }
}
