import SwiftUI

/// A routine draft summary card that shows all workout days in a compact view.
/// Tapping a day expands inline to show exercises from the linked session_plan card.
/// Uses shared components for consistent editing experience with SessionPlanCard.
public struct RoutineSummaryCard: View {
    private let model: CanvasCardModel
    private let routineData: RoutineSummaryData
    
    @State private var expandedDayIndex: Int? = nil
    @State private var expandedExerciseId: String? = nil
    @State private var showingActionsSheet = false
    @State private var selectedExercise: PlanExercise? = nil  // For ExerciseDetailSheet
    @State private var exerciseForSwap: PlanExercise? = nil   // For ExerciseSwapSheet
    
    // Mutable copies of exercises per workout for inline editing
    @State private var editableExercises: [String: [PlanExercise]] = [:]  // workoutId -> exercises
    @State private var selectedCell: GridCellField? = nil  // For SetGridView inline editing
    @State private var warmupCollapsed: [String: Bool] = [:]  // exerciseId -> collapsed
    
    @Environment(\.cardActionHandler) private var handleAction
    @Environment(\.canvasCards) private var allCards
    
    public init(model: CanvasCardModel, data: RoutineSummaryData) {
        self.model = model
        self.routineData = data
    }
    
    // MARK: - Computed
    
    private var statusText: String {
        switch model.status {
        case .proposed: return "Draft"
        case .accepted: return "Saved"
        case .active: return "Active"
        case .completed: return "Complete"
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
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
                .padding(Space.md)
            
            // Divider
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
            
            // Workout days list
            workoutDaysList
            
            // Actions (only for proposed/active)
            if model.status == .proposed || model.status == .active {
                Rectangle()
                    .fill(Color.separatorLine)
                    .frame(height: 1)
                
                actionButtons
                    .padding(Space.md)
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        .confirmationDialog("Routine Actions", isPresented: $showingActionsSheet, titleVisibility: .hidden) {
            routineActionsSheet
        }
        .sheet(item: $selectedExercise) { exercise in
            ExerciseDetailSheet(
                exerciseId: exercise.exerciseId,
                exerciseName: exercise.name,
                onDismiss: { selectedExercise = nil }
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
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // Mode indicator (if updating)
            if routineData.isUpdate {
                modeIndicator
            }
            
            HStack(alignment: .center, spacing: Space.sm) {
                // Routine icon
                Image(systemName: routineData.isUpdate ? "arrow.triangle.2.circlepath.circle" : "calendar.badge.clock")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(routineData.isUpdate ? Color.warning : Color.accent)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(routineData.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color.textPrimary)
                    
                    HStack(spacing: 4) {
                        Text("\(routineData.workouts.count) workouts")
                        Text("•")
                            .foregroundColor(Color.textSecondary.opacity(0.5))
                        Text("\(routineData.frequency)×/week")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(Color.textSecondary)
                }
                
                Spacer()
                
                // Status pill
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
                
                // Overflow menu
                Button { showingActionsSheet = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    /// Mode indicator pill - shows "Updating: RoutineName" for updates
    private var modeIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .medium))
            
            if let sourceName = routineData.sourceRoutineName, !sourceName.isEmpty {
                Text("Updating: \(sourceName)")
            } else {
                Text("Updating Existing Routine")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Color.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.warning.opacity(0.12))
        .clipShape(Capsule())
    }
    
    // MARK: - Workout Days List
    
    private var workoutDaysList: some View {
        VStack(spacing: 0) {
            ForEach(Array(routineData.workouts.enumerated()), id: \.element.id) { index, workout in
                VStack(spacing: 0) {
                    workoutDayRow(workout: workout, index: index)
                    
                    // Expanded exercise list
                    if expandedDayIndex == index {
                        expandedWorkoutContent(workout: workout, index: index)
                    }
                    
                    // Separator between days
                    if index < routineData.workouts.count - 1 {
                        Rectangle()
                            .fill(Color.separatorLine)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
    
    private func workoutDayRow(workout: RoutineWorkoutSummary, index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: MotionToken.medium)) {
                if expandedDayIndex == index {
                    expandedDayIndex = nil
                } else {
                    expandedDayIndex = index
                    // Initialize editable exercises when expanding
                    initializeEditableExercises(for: workout)
                }
            }
        } label: {
            HStack(spacing: Space.sm) {
                // Day info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Day \(workout.day):")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.textSecondary)
                        
                        Text(workout.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color.textPrimary)
                    }
                    
                    // Stats line
                    workoutStatsLine(workout: workout)
                }
                
                Spacer()
                
                // Expand/collapse chevron
                Image(systemName: expandedDayIndex == index ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .background(expandedDayIndex == index ? Color.surfaceElevated.opacity(0.5) : Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func workoutStatsLine(workout: RoutineWorkoutSummary) -> some View {
        let exercises = getEditableExercises(for: workout)
        let exerciseCount = workout.exerciseCount ?? exercises.count
        let setCount = exercises.reduce(0) { $0 + $1.sets.count }
        
        return HStack(spacing: Space.sm) {
            if let duration = workout.estimatedDuration {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("~\(duration) min")
                }
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
            }
            
            if exerciseCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "dumbbell")
                        .font(.system(size: 11))
                    if setCount > 0 {
                        Text("\(exerciseCount) exercises, \(setCount) sets")
                    } else {
                        Text("\(exerciseCount) exercises")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
            }
        }
    }
    
    // MARK: - Expanded Workout Content (uses shared components)
    
    @ViewBuilder
    private func expandedWorkoutContent(workout: RoutineWorkoutSummary, index: Int) -> some View {
        let workoutId = workout.id
        
        VStack(spacing: 0) {
            // Exercise list using shared ExerciseRowView
            if let exercises = editableExercises[workoutId], !exercises.isEmpty {
                ForEach(Array(exercises.indices), id: \.self) { exIndex in
                    let exercise = exercises[exIndex]
                    let isExpanded = expandedExerciseId == exercise.id
                    
                    ExerciseRowView(
                        exerciseIndex: exIndex,
                        exercises: Binding(
                            get: { editableExercises[workoutId] ?? [] },
                            set: { editableExercises[workoutId] = $0 }
                        ),
                        selectedCell: $selectedCell,
                        isExpanded: isExpanded,
                        isPlanningMode: model.status == .proposed || model.status == .accepted,
                        showDivider: exIndex < exercises.count - 1,
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedExerciseId = isExpanded ? nil : exercise.id
                            }
                        },
                        onSwap: { ex, reason in
                            handleSwapRequest(exercise: ex, reason: reason, workoutId: workoutId)
                        },
                        onInfo: { ex in
                            selectedExercise = ex
                        },
                        onRemove: { exIdx in
                            removeExercise(at: exIdx, from: workoutId)
                        },
                        warmupCollapsed: Binding(
                            get: { warmupCollapsed[exercise.id] ?? true },
                            set: { warmupCollapsed[exercise.id] = $0 }
                        )
                    )
                }
            } else {
                // No exercises placeholder
                HStack {
                    Text("No exercises")
                        .font(.system(size: 14))
                        .foregroundColor(Color.textSecondary)
                    Spacer()
                }
                .padding(Space.md)
            }
            
            // Quick actions using shared IterationActionsRow
            IterationActionsRow(
                context: .routineDay(day: workout.day, title: workout.title),
                onAdjust: { instruction in
                    handleAdjustWorkout(index: index, instruction: instruction)
                }
            )
            .padding(.horizontal, Space.md)
            .padding(.vertical, 10)
        }
        .padding(.leading, Space.lg)
        .background(Color.surfaceElevated.opacity(0.3))
    }
    
    // MARK: - Exercise Management
    
    private func initializeEditableExercises(for workout: RoutineWorkoutSummary) {
        guard editableExercises[workout.id] == nil else { return }
        editableExercises[workout.id] = getExercisesFromLinkedCard(workout)
    }
    
    private func getEditableExercises(for workout: RoutineWorkoutSummary) -> [PlanExercise] {
        editableExercises[workout.id] ?? getExercisesFromLinkedCard(workout)
    }
    
    private func getExercisesFromLinkedCard(_ workout: RoutineWorkoutSummary) -> [PlanExercise] {
        // Prefer inline blocks from artifact (SSE path embeds exercises directly)
        if let blocks = workout.blocks, !blocks.isEmpty {
            return blocks
        }

        // Try to find the linked session_plan card by cardId
        if let cardId = workout.cardId,
           let linkedCard = allCards.first(where: { $0.id == cardId }),
           case .sessionPlan(let exercises) = linkedCard.data {
            return exercises
        }

        // Fallback: look for a session_plan card with matching title
        if let matchingCard = allCards.first(where: { card in
            if case .sessionPlan = card.data,
               card.title?.lowercased() == workout.title.lowercased() {
                return true
            }
            return false
        }), case .sessionPlan(let exercises) = matchingCard.data {
            return exercises
        }

        return []
    }
    
    private func removeExercise(at index: Int, from workoutId: String) {
        _ = withAnimation(.easeOut(duration: 0.2)) {
            editableExercises[workoutId]?.remove(at: index)
        }
    }
    
    // MARK: - Swap Handling
    
    private func handleSwapRequest(exercise: PlanExercise, reason: ExerciseActionsRow.SwapReason, workoutId: String) {
        if reason == .manualSearch {
            // Open swap sheet for manual search
            exerciseForSwap = exercise
        } else {
            // AI swap - send to agent
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
                "current_plan": serializeAllWorkoutsForAgent()
            ]
        )
        handleAction(action, model)
    }
    
    private func handleManualSwap(exercise: PlanExercise, with replacement: Exercise) {
        // Find which workout contains this exercise and replace it
        for (workoutId, exercises) in editableExercises {
            if let index = exercises.firstIndex(where: { $0.id == exercise.id }) {
                // Create new PlanExercise from selected Exercise, keeping same sets
                let newExercise = PlanExercise(
                    exerciseId: replacement.id,
                    name: replacement.name,
                    sets: exercise.sets,
                    primaryMuscles: replacement.primaryMuscles,
                    equipment: replacement.equipment.first  // Exercise has [String], PlanExercise has String?
                )
                editableExercises[workoutId]?[index] = newExercise
                break
            }
        }
    }
    
    // MARK: - Adjust Handling
    
    private func handleAdjustWorkout(index: Int, instruction: String) {
        let action = CardAction(
            kind: "adjust_workout",
            label: "Adjust",
            payload: [
                "workout_index": "\(index)",
                "instruction": instruction,
                "current_plan": serializeAllWorkoutsForAgent()
            ]
        )
        handleAction(action, model)
    }
    
    // MARK: - Serialization for Agent
    
    private func serializeAllWorkoutsForAgent() -> String {
        var lines: [String] = []
        for workout in routineData.workouts {
            let exercises = getEditableExercises(for: workout)
            lines.append("Day \(workout.day) - \(workout.title):")
            for (i, ex) in exercises.enumerated() {
                lines.append("  \(i + 1). \(ex.name) — \(ex.summaryLine)")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: Space.sm) {
            // Dismiss
            Button {
                let action = CardAction(kind: "dismiss_draft", label: "Dismiss", style: .secondary)
                handleAction(action, model)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                    Text("Dismiss")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(Color.textSecondary)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
            
            // For updates: Save as New option (secondary)
            if routineData.isUpdate {
                Button {
                    var payload = serializeEditedWorkoutsForSave()
                    payload["save_as_new"] = "true"  // Override sourceIds
                    let action = CardAction(
                        kind: "save_routine",
                        label: "Save as New",
                        style: .ghost,
                        payload: payload
                    )
                    handleAction(action, model)
                } label: {
                    Text("Save as New")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(Color.textSecondary)
                        .background(Color.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            // Save/Update Routine (Primary) - includes edited exercises
            Button {
                let action = CardAction(
                    kind: "save_routine",
                    label: routineData.isUpdate ? "Update Routine" : "Save Routine",
                    style: .primary,
                    payload: serializeEditedWorkoutsForSave()
                )
                handleAction(action, model)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: routineData.isUpdate ? "arrow.triangle.2.circlepath" : "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                    Text(routineData.isUpdate ? "Update Routine" : "Save Routine")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(routineData.isUpdate ? Color.warning : Color.accent)
                .foregroundColor(.textInverse)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    private func serializeEditedWorkoutsForSave() -> [String: String] {
        // Serialize all edited workouts as JSON
        var workoutData: [[String: Any]] = []
        
        for workout in routineData.workouts {
            let exercises = getEditableExercises(for: workout)
            let exercisesData = exercises.map { ex -> [String: Any] in
                [
                    "name": ex.name,
                    "exercise_id": ex.exerciseId ?? "",
                    "sets": ex.sets.map { set -> [String: Any] in
                        [
                            "type": (set.type ?? .working).rawValue,
                            "reps": set.reps,
                            "weight": set.weight ?? NSNull(),
                            "rir": set.rir ?? NSNull()
                        ]
                    }
                ]
            }
            
            workoutData.append([
                "day": workout.day,
                "title": workout.title,
                "card_id": workout.cardId ?? "",
                "exercises": exercisesData
            ])
        }
        
        if let json = try? JSONSerialization.data(withJSONObject: workoutData),
           let jsonString = String(data: json, encoding: .utf8) {
            return ["edited_workouts": jsonString]
        }
        
        return [:]
    }
    
    // MARK: - Actions Sheet
    
    @ViewBuilder
    private var routineActionsSheet: some View {
        Button("Edit Routine Name", role: .none) {
            // TODO: Open edit sheet
        }
        
        Button("Regenerate All Workouts", role: .none) {
            let action = CardAction(
                kind: "adjust_plan",
                label: "Regenerate",
                payload: [
                    "instruction": "Regenerate this entire routine with different exercises",
                    "current_plan": serializeAllWorkoutsForAgent()
                ]
            )
            handleAction(action, model)
        }
        
        Divider()
        
        Button("Dismiss Routine", role: .destructive) {
            let action = CardAction(kind: "dismiss_draft", label: "Dismiss", style: .destructive)
            handleAction(action, model)
        }
        
        Button("Cancel", role: .cancel) {}
    }
}

// MARK: - Preview

#if DEBUG
struct RoutineSummaryCard_Previews: PreviewProvider {
    static var previews: some View {
        let sampleExercises: [PlanExercise] = [
            PlanExercise(name: "Bench Press", sets: [
                PlanSet(type: .warmup, reps: 10, weight: 40, rir: nil),
                PlanSet(type: .working, reps: 8, weight: 80, rir: 2),
                PlanSet(type: .working, reps: 8, weight: 80, rir: 2),
                PlanSet(type: .working, reps: 8, weight: 80, rir: 1)
            ]),
            PlanExercise(name: "Incline Dumbbell Press", sets: [
                PlanSet(type: .working, reps: 10, weight: 30, rir: 2),
                PlanSet(type: .working, reps: 10, weight: 30, rir: 2),
                PlanSet(type: .working, reps: 10, weight: 30, rir: 1)
            ]),
            PlanExercise(name: "Overhead Press", sets: [
                PlanSet(type: .working, reps: 10, weight: 40, rir: 2),
                PlanSet(type: .working, reps: 10, weight: 40, rir: 2),
                PlanSet(type: .working, reps: 10, weight: 40, rir: 1)
            ])
        ]
        
        let pushCard = CanvasCardModel(
            id: "card-push",
            type: .session_plan,
            status: .proposed,
            lane: .workout,
            title: "Push",
            data: .sessionPlan(exercises: sampleExercises),
            width: .full,
            actions: []
        )
        
        let sampleData = RoutineSummaryData(
            name: "Push Pull Legs",
            description: "Classic 3-day hypertrophy split",
            frequency: 6,
            workouts: [
                RoutineWorkoutSummary(day: 1, title: "Push", cardId: "card-push", estimatedDuration: 45, exerciseCount: 5),
                RoutineWorkoutSummary(day: 2, title: "Pull", cardId: "card-pull", estimatedDuration: 40, exerciseCount: 5),
                RoutineWorkoutSummary(day: 3, title: "Legs", cardId: "card-legs", estimatedDuration: 50, exerciseCount: 5),
            ],
            draftId: "draft-123",
            revision: 1
        )
        
        let model = CanvasCardModel(
            id: "test-routine",
            type: .routine_summary,
            status: .proposed,
            lane: .workout,
            title: "Push Pull Legs",
            data: .routineSummary(sampleData),
            width: .full,
            actions: [],
            meta: CardMeta(groupId: "grp-123")
        )
        
        ScrollView {
            RoutineSummaryCard(model: model, data: sampleData)
                .environment(\.canvasCards, [pushCard])
                .padding()
        }
        .background(Color.bg)
    }
}
#endif
