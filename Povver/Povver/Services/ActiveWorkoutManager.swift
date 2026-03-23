import Foundation
import Combine
import FirebaseFirestore

// MARK: - UserService for user preferences
class UserService: ObservableObject {
    static let shared = UserService()

    @Published var weightUnit: WeightUnit = .kg {
        didSet { activeWorkoutWeightUnit = weightUnit }
    }
    @Published var heightUnit: HeightUnit = .cm
    @Published var activeWorkoutWeightUnit: WeightUnit = .kg

    private let userRepository = UserRepository()
    private var authCancellable: AnyCancellable?

    private init() {
        loadUserPreferences()

        // Retry when auth becomes available (covers app restart where
        // Firebase Auth hasn't initialized yet during init)
        authCancellable = AuthService.shared.$currentUser
            .dropFirst()
            .compactMap { $0 }
            .first()
            .sink { [weak self] _ in
                self?.loadUserPreferences()
            }
    }

    private func loadUserPreferences() {
        guard let userId = AuthService.shared.currentUser?.uid else {
            AppLogger.shared.info(.work, "loadUserPreferences — no auth, skipping")
            return
        }

        Task {
            do {
                let db = Firestore.firestore()
                let attrDoc = try await db.collection("users").document(userId)
                    .collection("user_attributes").document(userId).getDocument()
                let data = attrDoc.data() ?? [:]
                let weightFormat = data["weight_format"] as? String
                let heightFormat = data["height_format"] as? String
                AppLogger.shared.info(.work, "loadUserPreferences — preferences loaded")

                await MainActor.run {
                    self.weightUnit = WeightUnit(firestoreFormat: weightFormat)
                    self.heightUnit = HeightUnit(firestoreFormat: heightFormat)
                    AppLogger.shared.info(.work, "loadUserPreferences — units applied")
                }
            } catch {
                // Don't reset to defaults — keep whatever was previously loaded.
                // Resetting here would clobber a just-saved preference if the
                // reload Firestore read hits a transient network error.
                AppLogger.shared.error(.store, "Failed to load user preferences: \(error)")
            }
        }
    }

    /// Reload preferences from Firestore (fire-and-forget, used after writes)
    func reloadPreferences() {
        loadUserPreferences()
    }

    /// Await-able preference load — guarantees values are fresh before returning.
    @MainActor
    func ensurePreferencesLoaded() async {
        guard let userId = AuthService.shared.currentUser?.uid else {
            AppLogger.shared.info(.work, "ensurePreferencesLoaded — no auth, skipping")
            return
        }
        do {
            let db = Firestore.firestore()
            let attrDoc = try await db.collection("users").document(userId)
                .collection("user_attributes").document(userId).getDocument()
            let data = attrDoc.data() ?? [:]
            let weightFormat = data["weight_format"] as? String
            let heightFormat = data["height_format"] as? String
            AppLogger.shared.info(.work, "ensurePreferencesLoaded — preferences loaded")
            self.weightUnit = WeightUnit(firestoreFormat: weightFormat)
            self.heightUnit = HeightUnit(firestoreFormat: heightFormat)
            AppLogger.shared.info(.work, "ensurePreferencesLoaded — units applied")
        } catch {
            AppLogger.shared.error(.store, "Failed to load user preferences: \(error)")
        }
    }

    /// Snapshot weight unit for active workout (called when workout starts)
    func snapshotForWorkout() {
        activeWorkoutWeightUnit = weightUnit
    }
}

class ActiveWorkoutManager: ObservableObject {
    static let shared = ActiveWorkoutManager()
    
    @Published private(set) var activeWorkout: ActiveWorkout?
    @Published private(set) var isWorkoutActive: Bool = false
    @Published private(set) var sensorStatus: SensorStatus = .noSensors
    @Published private(set) var workoutDuration: TimeInterval = 0
    
    // Navigation tracking
    @Published private(set) var isMinimized: Bool = false
    @Published private(set) var hasNavigatedAway: Bool = false
    @Published var navigationDestination: NavigationDestination?
    
    // Performance optimization - batch UI updates
    private var pendingUpdates: [() -> Void] = []
    private var updateTimer: Timer?
    
    // Workout timing
    private var workoutTimer: Timer?
    
    // Sensor data streaming (future)
    private var sensorDataBuffer: [SensorSample] = []
    
    private init() {}
    
    // MARK: - Workout Lifecycle
    func startWorkout(from template: WorkoutTemplate? = nil) {
        Task {
            // Ensure preferences are loaded before snapshotting weight unit
            await UserService.shared.ensurePreferencesLoaded()
            UserService.shared.snapshotForWorkout()

            let workout = await createActiveWorkout(from: template)
            await MainActor.run {
                self.activeWorkout = workout
                self.isWorkoutActive = true
                self.startWorkoutTimer()
                self.checkSensorStatus()
            }
        }
    }
    
    func resumeWorkout(_ workout: ActiveWorkout) {
        Task {
            await UserService.shared.ensurePreferencesLoaded()
            UserService.shared.snapshotForWorkout()

            await MainActor.run {
                self.activeWorkout = workout
                self.isWorkoutActive = true
                self.startWorkoutTimer()
                self.checkSensorStatus()
            }
        }
    }
    
    func updateStartTime(_ newStartTime: Date) {
        guard var workout = activeWorkout else { return }
        workout.startTime = newStartTime
        
        DispatchQueue.main.async { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    func cancelWorkout() {
        stopWorkoutTimer()
        clearSensorData()
        
        DispatchQueue.main.async { [weak self] in
            self?.activeWorkout = nil
            self?.isWorkoutActive = false
            self?.workoutDuration = 0
            
            // Set navigation destination based on user behavior
            if self?.hasNavigatedAway == true {
                // User will return to where they were
                self?.navigationDestination = .stayInCurrentView
            } else {
                // User stayed in workout, return to workouts list
                self?.navigationDestination = .workouts
            }
            
            // Don't reset navigation state yet - let handleNavigationComplete() do it
            self?.isMinimized = false
            self?.hasNavigatedAway = false
        }
    }
    
    func completeWorkout() async throws -> String? {
        guard var workout = activeWorkout else { 
            AppLogger.shared.error(.work, "No active workout to complete")
            return nil 
        }
        
        // Set end time
        workout.endTime = Date()
        
        // Get current user ID
        guard let currentUserId = getCurrentUserId() else {
            AppLogger.shared.error(.work, "No current user ID available")
            throw WorkoutError.noUserID
        }
        
        // Set user ID if not already set
        if workout.userId.isEmpty {
            workout.userId = currentUserId
        }
        
        do {
            // Save to Firestore
            let workoutId = try await saveWorkout(workout)
            AppLogger.shared.info(.work, "Workout saved successfully")
            
            // All UI updates must happen on main thread
            await MainActor.run {
                // Set navigation destination based on user behavior
                if self.hasNavigatedAway {
                    // User will return to where they were after summary
                    self.navigationDestination = .stayInCurrentView
                } else {
                    // User stayed in workout, go to dashboard after summary
                    self.navigationDestination = .dashboard
                }
                
                // Stop timing but keep the workout data until summary is dismissed
                self.stopWorkoutTimer()
                self.clearSensorData()
                
                // Don't clear activeWorkout and isWorkoutActive yet!
                // This will be done when the summary is dismissed
            }
            
            return workoutId
        } catch {
            AppLogger.shared.error(.work, "Error saving workout", error)
            throw error
        }
    }
    
    // New method to clear workout data after summary is dismissed
    func clearCompletedWorkout() {
        DispatchQueue.main.async { [weak self] in
            self?.activeWorkout = nil
            self?.isWorkoutActive = false
            self?.workoutDuration = 0
        }
    }
    
    // MARK: - Exercise Management
    func addExercise(_ exercise: Exercise, at position: Int? = nil) {
        guard var workout = activeWorkout,
              let exerciseId = exercise.id else { return }

        let activeExercise = ActiveExercise(
            id: UUID().uuidString,
            exerciseId: exerciseId,
            name: exercise.name,
            position: position ?? workout.exercises.count,
            sets: []
        )
        
        if let position = position {
            workout.exercises.insert(activeExercise, at: position)
            // Update positions for subsequent exercises
            updateExercisePositions(&workout.exercises)
        } else {
            workout.exercises.append(activeExercise)
        }
        
        batchUpdate { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    func updateExercise(_ exercise: ActiveExercise) {
        guard var workout = activeWorkout else { return }
        if let idx = workout.exercises.firstIndex(where: { $0.id == exercise.id }) {
            workout.exercises[idx] = exercise
            batchUpdate { [weak self] in
                self?.activeWorkout = workout
            }
        }
    }
    
    func removeExercise(id: String) {
        guard var workout = activeWorkout else { return }
        workout.exercises.removeAll { $0.id == id }
        updateExercisePositions(&workout.exercises)
        batchUpdate { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    func moveExercise(fromOffsets: IndexSet, toOffset: Int) {
        guard var workout = activeWorkout else { return }
        
        // Manual implementation since we're not using List
        let indices = Array(fromOffsets).sorted(by: >)
        var exercises = workout.exercises
        
        for index in indices {
            if index < exercises.count {
                let item = exercises.remove(at: index)
                let newIndex = toOffset > index ? toOffset - 1 : toOffset
                exercises.insert(item, at: min(newIndex, exercises.count))
            }
        }
        
        workout.exercises = exercises
        updateExercisePositions(&workout.exercises)
        
        DispatchQueue.main.async { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    func moveExercise(from: Int, to: Int) {
        guard var workout = activeWorkout else { return }
        guard from < workout.exercises.count && to < workout.exercises.count else { return }
        
        let exercise = workout.exercises.remove(at: from)
        workout.exercises.insert(exercise, at: to)
        updateExercisePositions(&workout.exercises)
        
        DispatchQueue.main.async { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    // MARK: - Set Management (Performance Optimized)
    func addSet(toExerciseId: String, reps: Int = 0, weight: Double = 0, rir: Int? = nil, type: String = "Working Set") {
        guard var workout = activeWorkout else { return }
        guard let idx = workout.exercises.firstIndex(where: { $0.id == toExerciseId }) else { return }
        
        let newSet = ActiveSet(
            id: UUID().uuidString,
            reps: reps,
            rir: rir,
            type: type,
            weight: weight,
            isCompleted: false
        )
        
        workout.exercises[idx].sets.append(newSet)
        batchUpdate { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    func updateSet(exerciseId: String, set: ActiveSet) {
        guard var workout = activeWorkout else { return }
        guard let exIdx = workout.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        if let setIdx = workout.exercises[exIdx].sets.firstIndex(where: { $0.id == set.id }) {
            workout.exercises[exIdx].sets[setIdx] = set
            batchUpdate { [weak self] in
                self?.activeWorkout = workout
            }
        }
    }
    
    func removeSet(exerciseId: String, setId: String) {
        guard var workout = activeWorkout else { return }
        guard let exIdx = workout.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        workout.exercises[exIdx].sets.removeAll { $0.id == setId }
        batchUpdate { [weak self] in
            self?.activeWorkout = workout
        }
    }
    
    // MARK: - Template Integration
    private func createActiveWorkout(from template: WorkoutTemplate?) async -> ActiveWorkout {
        let currentUserId = getCurrentUserId() ?? ""
        
        let workout = ActiveWorkout(
            id: UUID().uuidString,
            userId: currentUserId,
            sourceTemplateId: template?.id,
            createdAt: Date(),
            startTime: Date(),
            endTime: nil,
            notes: nil,
            exercises: []
        )
        
        // If template provided, prefill exercises and sets
        if let template = template {
            return await prefillFromTemplate(workout: workout, template: template)
        }
        
        return workout
    }
    
    private func prefillFromTemplate(workout: ActiveWorkout, template: WorkoutTemplate) async -> ActiveWorkout {
        var updatedWorkout = workout
        
        // Load exercises to get actual names - need to run on MainActor for @MainActor class
        let exercisesViewModel = await MainActor.run { ExercisesViewModel() }
        await exercisesViewModel.loadExercises()
        let exercises = await MainActor.run { exercisesViewModel.exercises }
        
        updatedWorkout.exercises = template.exercises.map { templateExercise in
            // Find the actual exercise to get the name
            let exerciseName = exercises.first { $0.id == templateExercise.exerciseId }?.name ?? "Unknown Exercise"
            
            return ActiveExercise(
                id: UUID().uuidString,
                exerciseId: templateExercise.exerciseId,
                name: exerciseName,
                position: templateExercise.position,
                sets: templateExercise.sets.map { templateSet in
                    ActiveSet(
                        id: UUID().uuidString,
                        reps: templateSet.reps,
                        rir: templateSet.rir,
                        type: templateSet.type,
                        weight: templateSet.weight,
                        isCompleted: false
                    )
                }
            )
        }
        
        return updatedWorkout
    }
    
    // MARK: - User Management
    private func getCurrentUserId() -> String? {
        // Get current user ID from AuthService
        return AuthService.shared.currentUser?.uid
    }
    
    // MARK: - Performance Optimization
    private func batchUpdate(_ update: @escaping () -> Void) {
        pendingUpdates.append(update)
        
        // Debounce updates to prevent UI lag
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: false) { [weak self] _ in
            self?.flushPendingUpdates()
        }
    }
    
    private func flushPendingUpdates() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for update in self.pendingUpdates {
                update()
            }
            self.pendingUpdates.removeAll()
        }
    }
    
    // MARK: - Sensor Integration (Future)
    private func checkSensorStatus() {
        // Check if sensors are paired and available
        // For now, default to no sensors
        sensorStatus = .noSensors
    }
    
    func addSensorSample(_ sample: SensorSample) {
        sensorDataBuffer.append(sample)
        
        // Batch sensor data for performance
        if sensorDataBuffer.count >= 100 {
            flushSensorData()
        }
    }
    
    private func flushSensorData() {
        // Process and potentially upload sensor data
        // Clear buffer
        sensorDataBuffer.removeAll()
    }
    
    private func clearSensorData() {
        sensorDataBuffer.removeAll()
    }
    
    // MARK: - Timing
    private func startWorkoutTimer() {
        workoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let workout = self.activeWorkout else { return }
            self.workoutDuration = Date().timeIntervalSince(workout.startTime)
        }
    }
    
    private func stopWorkoutTimer() {
        workoutTimer?.invalidate()
        workoutTimer = nil
    }
    
    // MARK: - Persistence
    private func saveWorkout(_ workout: ActiveWorkout) async throws -> String {
        // Convert ActiveWorkout to Workout format for Firestore
        let firestoreWorkout = try await convertToFirestoreFormat(workout)
        
        // Save using WorkoutRepository
        let repository = WorkoutRepository()
        return try await repository.createWorkout(userId: workout.userId, workout: firestoreWorkout)
    }
    
    private func convertToFirestoreFormat(_ activeWorkout: ActiveWorkout) async throws -> Workout {
        let userService = UserService.shared
        let weightFormat = userService.activeWorkoutWeightUnit.firestoreFormat
        
        var workoutExercises: [WorkoutExercise] = []
        var workoutTotalSets = 0
        var workoutTotalReps = 0
        var workoutTotalWeight = 0.0
        var workoutWeightPerMuscleGroup: [String: Double] = [:]
        var workoutWeightPerMuscle: [String: Double] = [:]
        var workoutRepsPerMuscleGroup: [String: Double] = [:]
        var workoutRepsPerMuscle: [String: Double] = [:]
        var workoutSetsPerMuscleGroup: [String: Int] = [:]
        var workoutSetsPerMuscle: [String: Int] = [:]
        
        for activeExercise in activeWorkout.exercises {
            let exerciseAnalytics = try await calculateExerciseAnalytics(
                activeExercise: activeExercise,
                weightFormat: weightFormat
            )
            
            let workoutExercise = WorkoutExercise(
                id: activeExercise.id,
                exerciseId: activeExercise.exerciseId,
                name: activeExercise.name,
                position: activeExercise.position,
                sets: activeExercise.sets.map { activeSet in
                    WorkoutExerciseSet(
                        id: activeSet.id,
                        reps: activeSet.reps,
                        rir: activeSet.rir,
                        type: activeSet.type,
                        weight: activeSet.weight,
                        isCompleted: activeSet.isCompleted
                    )
                },
                analytics: exerciseAnalytics
            )
            
            workoutExercises.append(workoutExercise)
            
            // Accumulate workout totals
            workoutTotalSets += exerciseAnalytics.totalSets
            workoutTotalReps += exerciseAnalytics.totalReps
            workoutTotalWeight += exerciseAnalytics.totalWeight
            
            // Accumulate muscle group metrics
            for (muscleGroup, weight) in exerciseAnalytics.weightPerMuscleGroup {
                workoutWeightPerMuscleGroup[muscleGroup, default: 0] += weight
            }
            for (muscleGroup, reps) in exerciseAnalytics.repsPerMuscleGroup {
                workoutRepsPerMuscleGroup[muscleGroup, default: 0] += reps
            }
            for (muscleGroup, sets) in exerciseAnalytics.setsPerMuscleGroup {
                workoutSetsPerMuscleGroup[muscleGroup, default: 0] += sets
            }
            
            // Accumulate individual muscle metrics
            for (muscle, weight) in exerciseAnalytics.weightPerMuscle {
                workoutWeightPerMuscle[muscle, default: 0] += weight
            }
            for (muscle, reps) in exerciseAnalytics.repsPerMuscle {
                workoutRepsPerMuscle[muscle, default: 0] += reps
            }
            for (muscle, sets) in exerciseAnalytics.setsPerMuscle {
                workoutSetsPerMuscle[muscle, default: 0] += sets
            }
        }
        
        // Calculate workout analytics
        let workoutAnalytics = WorkoutAnalytics(
            totalSets: workoutTotalSets,
            totalReps: workoutTotalReps,
            totalWeight: workoutTotalWeight,
            weightFormat: weightFormat,
            avgRepsPerSet: workoutTotalSets > 0 ? Double(workoutTotalReps) / Double(workoutTotalSets) : 0,
            avgWeightPerSet: workoutTotalSets > 0 ? workoutTotalWeight / Double(workoutTotalSets) : 0,
            avgWeightPerRep: workoutTotalReps > 0 ? workoutTotalWeight / Double(workoutTotalReps) : 0,
            weightPerMuscleGroup: workoutWeightPerMuscleGroup,
            weightPerMuscle: workoutWeightPerMuscle,
            repsPerMuscleGroup: workoutRepsPerMuscleGroup,
            repsPerMuscle: workoutRepsPerMuscle,
            setsPerMuscleGroup: workoutSetsPerMuscleGroup,
            setsPerMuscle: workoutSetsPerMuscle
        )
        
        return Workout(
            id: activeWorkout.id,
            userId: activeWorkout.userId,
            sourceTemplateId: activeWorkout.sourceTemplateId,
            createdAt: activeWorkout.createdAt,
            startTime: activeWorkout.startTime,
            endTime: activeWorkout.endTime ?? Date(),
            exercises: workoutExercises,
            notes: activeWorkout.notes,
            analytics: workoutAnalytics
        )
    }
    
    // MARK: - Analytics Calculation
    private func calculateExerciseAnalytics(activeExercise: ActiveExercise, weightFormat: String) async throws -> ExerciseAnalytics {
        // Filter for only working sets (exclude warm-up sets)
        let workingSets = activeExercise.sets.filter { set in
            set.isCompleted && isWorkingSet(setType: set.type)
        }
        
        let totalSets = workingSets.count
        let totalReps = workingSets.reduce(0) { $0 + $1.reps }
        let totalWeight = workingSets.reduce(0) { $0 + ($1.weight * Double($1.reps)) }
        
        let avgRepsPerSet = totalSets > 0 ? Double(totalReps) / Double(totalSets) : 0
        let avgWeightPerSet = totalSets > 0 ? totalWeight / Double(totalSets) : 0
        let avgWeightPerRep = totalReps > 0 ? totalWeight / Double(totalReps) : 0
        
        // Get exercise data for muscle calculations
        let muscleMetrics = try await calculateMuscleMetrics(
            exerciseId: activeExercise.exerciseId,
            workingSets: workingSets
        )
        
        return ExerciseAnalytics(
            totalSets: totalSets,
            totalReps: totalReps,
            totalWeight: totalWeight,
            weightFormat: weightFormat,
            avgRepsPerSet: avgRepsPerSet,
            avgWeightPerSet: avgWeightPerSet,
            avgWeightPerRep: avgWeightPerRep,
            weightPerMuscleGroup: muscleMetrics.weightPerMuscleGroup,
            weightPerMuscle: muscleMetrics.weightPerMuscle,
            repsPerMuscleGroup: muscleMetrics.repsPerMuscleGroup,
            repsPerMuscle: muscleMetrics.repsPerMuscle,
            setsPerMuscleGroup: muscleMetrics.setsPerMuscleGroup,
            setsPerMuscle: muscleMetrics.setsPerMuscle
        )
    }
    
    private func isWorkingSet(setType: String) -> Bool {
        let workingSetTypes = ["working set", "drop-set", "failure set", "drop set", "failure"]
        return workingSetTypes.contains(setType.lowercased())
    }
    
    private struct MuscleMetrics {
        let weightPerMuscleGroup: [String: Double]
        let weightPerMuscle: [String: Double]
        let repsPerMuscleGroup: [String: Double]
        let repsPerMuscle: [String: Double]
        let setsPerMuscleGroup: [String: Int]
        let setsPerMuscle: [String: Int]
    }
    
    private func calculateMuscleMetrics(exerciseId: String, workingSets: [ActiveSet]) async throws -> MuscleMetrics {
        let exerciseRepository = ExerciseRepository()
        
        // Calculate totals from working sets
        let totalWeight = workingSets.reduce(0) { $0 + ($1.weight * Double($1.reps)) }
        let totalReps = workingSets.reduce(0) { $0 + $1.reps }
        let totalSets = workingSets.count
        
        var weightPerMuscleGroup: [String: Double] = [:]
        var weightPerMuscle: [String: Double] = [:]
        var repsPerMuscleGroup: [String: Double] = [:]
        var repsPerMuscle: [String: Double] = [:]
        var setsPerMuscleGroup: [String: Int] = [:]
        var setsPerMuscle: [String: Int] = [:]
        
        do {
            guard let exercise = try await exerciseRepository.read(id: exerciseId) else {
                AppLogger.shared.error(.work, "Exercise not found for analytics")
                return MuscleMetrics(
                    weightPerMuscleGroup: [:], weightPerMuscle: [:],
                    repsPerMuscleGroup: [:], repsPerMuscle: [:],
                    setsPerMuscleGroup: [:], setsPerMuscle: [:]
                )
            }
            
            let muscleCategories = exercise.muscleCategories
            let muscleContributions = exercise.muscleContributions
            let allMuscles = exercise.primaryMuscles + exercise.secondaryMuscles
            
            // Calculate metrics per muscle group (categories)
            if !muscleCategories.isEmpty {
                for category in muscleCategories {
                    // Sets: Each working set counts as 1 for each muscle group
                    setsPerMuscleGroup[category] = totalSets
                    
                    // Weight & Reps: Equal distribution among categories for now
                    // (In the future, could be enhanced with category-specific contributions)
                    let categoryWeight = totalWeight / Double(muscleCategories.count)
                    let categoryReps = Double(totalReps) / Double(muscleCategories.count)
                    
                    weightPerMuscleGroup[category] = categoryWeight
                    repsPerMuscleGroup[category] = categoryReps
                }
            }
            
            // Calculate metrics per individual muscle
            if !muscleContributions.isEmpty {
                // Use contribution percentages for weight and reps
                for (muscle, contribution) in muscleContributions {
                    weightPerMuscle[muscle] = totalWeight * contribution
                    repsPerMuscle[muscle] = Double(totalReps) * contribution
                    setsPerMuscle[muscle] = totalSets // Each set counts as 1 full set
                }
            } else {
                // Fallback: distribute equally among primary and secondary muscles
                if !allMuscles.isEmpty {
                    let weightPerMuscleFallback = totalWeight / Double(allMuscles.count)
                    let repsPerMuscleFallback = Double(totalReps) / Double(allMuscles.count)
                    
                    for muscle in allMuscles {
                        weightPerMuscle[muscle] = weightPerMuscleFallback
                        repsPerMuscle[muscle] = repsPerMuscleFallback
                        setsPerMuscle[muscle] = totalSets
                    }
                }
            }
        } catch {
            AppLogger.shared.error(.work, "Error fetching exercise data for analytics", error)
        }
        
        return MuscleMetrics(
            weightPerMuscleGroup: weightPerMuscleGroup,
            weightPerMuscle: weightPerMuscle,
            repsPerMuscleGroup: repsPerMuscleGroup,
            repsPerMuscle: repsPerMuscle,
            setsPerMuscleGroup: setsPerMuscleGroup,
            setsPerMuscle: setsPerMuscle
        )
    }
    
    // MARK: - Helper Methods
    private func updateExercisePositions(_ exercises: inout [ActiveExercise]) {
        for (index, _) in exercises.enumerated() {
            exercises[index].position = index
        }
    }
    
    // MARK: - Navigation Management
    func setMinimized(_ minimized: Bool) {
        isMinimized = minimized
        if minimized {
            // User is minimizing - they might navigate away
            hasNavigatedAway = true
        }
    }
    
    func handleNavigationComplete() {
        // Called after navigation is complete to reset state
        resetNavigationState()
    }
    
    private func resetNavigationState() {
        isMinimized = false
        hasNavigatedAway = false
        navigationDestination = nil
    }
}

// MARK: - Supporting Types
enum NavigationDestination {
    case workouts
    case dashboard
    case stayInCurrentView
}

enum SensorStatus {
    case noSensors
    case sensorsAvailable(Int)
    case sensorsConnected(Int)
    case sensorsDisconnected
}

struct SensorSample {
    let timestamp: Date
    let accelerometer: (x: Double, y: Double, z: Double)
    let gyroscope: (x: Double, y: Double, z: Double)
    let heartRate: Double?
}

enum WorkoutError: Error {
    case noUserID
    case saveFailed
    
    var localizedDescription: String {
        switch self {
        case .noUserID:
            return "No user logged in"
        case .saveFailed:
            return "Failed to save workout"
        }
    }
}
