import SwiftUI

/// Edit a completed workout's exercises and sets.
/// Backend recomputes all analytics on save via upsertWorkout.
struct WorkoutEditView: View {
    let workout: Workout
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var planExercises: [PlanExercise] = []
    @State private var expandedExerciseId: String? = nil
    @State private var selectedCell: GridCellField? = nil
    @State private var warmupCollapsed: [String: Bool] = [:]
    @State private var showAddExercise = false
    @State private var exerciseForSwap: PlanExercise? = nil
    @State private var selectedExerciseForInfo: PlanExercise? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    exercisesList
                        .padding(.top, Space.sm)

                    // Add exercise button
                    Button {
                        showAddExercise = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                            Text("Add Exercise")
                                .textStyle(.secondary)
                        }
                        .foregroundColor(Color.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.lg)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .background(Color.bg)
            .navigationTitle("Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        submitSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(planExercises.isEmpty)
                }
            }
            .sheet(isPresented: $showAddExercise) {
                FocusModeExerciseSearch { exercise in
                    addExercise(exercise)
                    showAddExercise = false
                }
            }
            .sheet(item: $exerciseForSwap) { exercise in
                ExerciseSwapSheet(
                    currentExercise: exercise,
                    onSwapWithAI: { _, _ in },
                    onSwapManual: { replacement in
                        handleManualSwap(exercise: exercise, with: replacement)
                    },
                    onDismiss: { exerciseForSwap = nil }
                )
            }
            .sheet(item: $selectedExerciseForInfo) { exercise in
                ExerciseDetailSheet(
                    exerciseId: exercise.exerciseId,
                    exerciseName: exercise.name,
                    onDismiss: { selectedExerciseForInfo = nil }
                )
            }
        }
        .onAppear { convertWorkoutToPlans() }
    }

    // MARK: - Exercise List

    private var exercisesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(planExercises.indices), id: \.self) { index in
                let exercise = planExercises[index]
                let isExpanded = expandedExerciseId == exercise.id

                ExerciseRowView(
                    exerciseIndex: index,
                    exercises: $planExercises,
                    selectedCell: $selectedCell,
                    isExpanded: isExpanded,
                    isPlanningMode: false,
                    showDivider: index < planExercises.count - 1,
                    onToggleExpand: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedExerciseId = isExpanded ? nil : exercise.id
                        }
                    },
                    onSwap: { ex, reason in
                        if reason == .manualSearch {
                            exerciseForSwap = ex
                        }
                    },
                    onInfo: { ex in
                        selectedExerciseForInfo = ex
                    },
                    onRemove: { exIdx in
                        withAnimation(.easeOut(duration: 0.2)) {
                            _ = planExercises.remove(at: exIdx)
                        }
                    },
                    warmupCollapsed: Binding(
                        get: { warmupCollapsed[exercise.id] ?? true },
                        set: { warmupCollapsed[exercise.id] = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Data Conversion

    private func convertWorkoutToPlans() {
        planExercises = workout.exercises.enumerated().map { index, ex in
            let sets = ex.sets.map { set in
                PlanSet(
                    id: set.id,
                    type: SetType(rawValue: set.type) ?? .working,
                    reps: set.reps,
                    weight: set.weight > 0 ? set.weight : nil,
                    rir: set.rir,
                    isCompleted: set.isCompleted
                )
            }
            return PlanExercise(
                id: ex.id,
                exerciseId: ex.exerciseId,
                name: ex.name,
                sets: sets,
                position: index
            )
        }
    }

    // MARK: - Save

    private func submitSave() {
        let exercises = planExercises.enumerated().map { index, planEx in
            UpsertExercise(
                exerciseId: planEx.exerciseId ?? "",
                name: planEx.name,
                position: index,
                sets: planEx.sets.map { set in
                    UpsertSet(
                        id: set.id,
                        reps: set.reps,
                        rir: set.rir,
                        type: set.type?.rawValue ?? "working",
                        weightKg: set.weight ?? 0,
                        isCompleted: set.isCompleted ?? true
                    )
                }
            )
        }

        let request = UpsertWorkoutRequest(
            id: workout.id,
            name: workout.name,
            startTime: workout.startTime,
            endTime: workout.endTime,
            exercises: exercises,
            sourceTemplateId: workout.sourceTemplateId,
            notes: workout.notes
        )

        let workoutId = workout.id
        BackgroundSaveService.shared.save(entityId: workoutId) {
            _ = try await FocusModeWorkoutService.shared.upsertWorkout(request)
        }

        // Track workout edit analytics
        AnalyticsService.shared.workoutHistoryEdited(workoutId: workoutId, editType: "exercises_modified")

        onSave()
        dismiss()
    }

    // MARK: - Exercise Mutations

    private func addExercise(_ exercise: Exercise) {
        let newSets = [
            PlanSet(
                id: UUID().uuidString,
                type: .working,
                reps: 10,
                weight: nil,
                rir: 2
            )
        ]
        let newExercise = PlanExercise(
            exerciseId: exercise.id,
            name: exercise.name,
            sets: newSets,
            primaryMuscles: exercise.primaryMuscles,
            equipment: exercise.equipment.first
        )
        planExercises.append(newExercise)
    }

    private func handleManualSwap(exercise: PlanExercise, with replacement: Exercise) {
        if let index = planExercises.firstIndex(where: { $0.id == exercise.id }) {
            let newExercise = PlanExercise(
                exerciseId: replacement.id,
                name: replacement.name,
                sets: exercise.sets,
                primaryMuscles: replacement.primaryMuscles,
                equipment: replacement.equipment.first
            )
            planExercises[index] = newExercise
        }
    }
}
