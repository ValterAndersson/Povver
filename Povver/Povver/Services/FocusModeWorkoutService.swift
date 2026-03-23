/**
 * FocusModeWorkoutService.swift
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 * FOCUS MODE WORKOUT SERVICE - Local-First Workout Execution Engine
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * PURPOSE:
 * This is the service layer for Focus Mode workout execution. It implements a
 * local-first architecture where UI changes are applied immediately and synced
 * to the backend asynchronously via MutationCoordinator.
 *
 * ARCHITECTURE:
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │  FocusModeWorkoutScreen (UI)                                                │
 * │  └── Observes: workout, isLoading, error, exerciseSyncState                 │
 * │                            │                                                 │
 * │                            │ User Actions                                    │
 * │                            ▼                                                 │
 * │  ┌─────────────────────────────────────────────────────────────────────┐    │
 * │  │  FocusModeWorkoutService (@MainActor, ObservableObject)             │    │
 * │  │  ├── workout: FocusModeWorkout?      - Local state (source of truth)│    │
 * │  │  ├── exerciseSyncState: [String: EntitySyncState]  - Per-entity UI  │    │
 * │  │  ├── currentSessionId: UUID?         - Validates callbacks          │    │
 * │  │  └── mutationCoordinator             - Handles sync ordering        │    │
 * │  └─────────────────────────────────────────────────────────────────────┘    │
 * │                            │                                                 │
 * │                            │ Optimistic Update + Enqueue                     │
 * │                            ▼                                                 │
 * │  ┌─────────────────────────────────────────────────────────────────────┐    │
 * │  │  MutationCoordinator (actor)                                        │    │
 * │  │  └── Ensures dependency ordering, retries, reconciliation           │    │
 * │  └─────────────────────────────────────────────────────────────────────┘    │
 * │                            │                                                 │
 * │                            │ Network Calls                                   │
 * │                            ▼                                                 │
 * │  Backend API (Firebase Functions)                                           │
 * └─────────────────────────────────────────────────────────────────────────────┘
 *
 * KEY PATTERNS:
 *
 * 1. OPTIMISTIC UPDATES
 *    - User action → Apply to local state immediately → Enqueue to coordinator
 *    - UI never waits for network (feels instant in the gym)
 *    - Rollback on sync failure via rollbackMutation()
 *
 * 2. SESSION SCOPING
 *    - Each workout session has a unique sessionId
 *    - Callbacks validate sessionId before applying changes
 *    - Prevents: old workout's callbacks corrupt new workout's state
 *    - Generated in startWorkout(), cleared in cancel/complete
 *
 * 3. PER-ENTITY SYNC STATE
 *    - exerciseSyncState[instanceId] tracks syncing/synced/failed
 *    - UI can show spinners on exercise cards during sync
 *    - UI can show error badges if sync failed
 *
 * 4. SELECTIVE HYDRATION (Reconciliation)
 *    - On TARGET_NOT_FOUND, coordinator triggers reconciliation
 *    - performReconciliation() fetches server state
 *    - Only updates positions and totals (server source of truth)
 *    - Preserves user's local set values (user's work)
 *
 * LATENCY REQUIREMENTS (from spec):
 * - Cell edits: Local update immediately, sync debounced 2s
 * - Set done (hot path): Local update immediately, no isSyncing flag
 * - AI inline actions: Target < 1.0–1.5s perceived
 *
 * USAGE:
 * ```swift
 * // Start workout
 * let workout = try await service.startWorkout(name: "Push Day")
 * 
 * // Add exercise (optimistic)
 * try await service.addExercise(exercise: benchPress)  // Appears immediately
 * 
 * // Log set (hot path)
 * let totals = try await service.logSet(
 *     exerciseInstanceId: "...",
 *     setId: "...",
 *     weight: 80,
 *     reps: 10,
 *     rir: 2
 * )
 * 
 * // Complete workout
 * let archivedId = try await service.completeWorkout()
 * ```
 */

import Foundation
import Combine
import UIKit
import FirebaseFirestore
import OSLog

@MainActor
class FocusModeWorkoutService: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var workout: FocusModeWorkout?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?
    
    /// Per-exercise sync state for UI indicators (spinners, error badges)
    @Published private(set) var exerciseSyncState: [String: EntitySyncState] = [:]

    /// Last session data per exercise (keyed by exerciseId) for ghost value resolution
    @Published private(set) var lastSessionData: [String: LastSessionExerciseData] = [:]

    /// Whether the current workout has changes vs its source template (Phase 3)
    @Published var hasTemplateChanges: Bool = false

    /// Snapshot of exercises at workout start for detecting changes vs template
    private var templateSnapshot: [FocusModeExercise]?

    /// Session ID to validate coordinator callbacks (prevents stale updates)
    private var currentSessionId: UUID?

    /// Tracks in-flight logSet/patchField network calls so completeWorkout() can drain them
    private var inFlightSyncCount = 0

    /// Track workout start time for first-set timing
    private var workoutStartedAt: Date?

    /// Track if first set has been logged for this workout session
    private var hasLoggedFirstSet: Bool = false

    // MARK: - Library Cache (prefetched on startup for Train/Library tabs)

    /// Cached templates for Library tab — populated by prefetchLibraryData()
    @Published private(set) var cachedTemplates: [TemplateInfo]?

    /// Cached routines for Library tab — populated by prefetchLibraryData()
    @Published private(set) var cachedRoutines: [RoutineInfo]?

    /// Cached next workout info — populated by prefetchLibraryData()
    @Published private(set) var cachedNextWorkout: NextWorkoutInfo?

    /// Guard against concurrent prefetch requests
    private var isPrefetching = false

    // MARK: - Dependencies

    private let apiClient = ApiClient.shared
    private let idempotencyHelper = IdempotencyKeyHelper.shared
    private let sessionLog = WorkoutSessionLogger.shared

    // MARK: - Undo Buffer (Tier 1 destructive actions)

    /// Represents a destructive action that can be undone within a 5-second window.
    enum UndoableAction {
        case exerciseRemoved(exercise: FocusModeExercise, index: Int, previousTotals: WorkoutTotals)
        case setRemoved(exerciseId: String, set: FocusModeSet, index: Int)
    }

    /// The most recent undoable action. Cleared on undo, new workout actions, or timeout.
    @Published private(set) var pendingUndo: UndoableAction?

    /// Deferred backend operation — executed when undo window expires without user tapping undo.
    private var deferredSync: (() async throws -> Void)?

    /// Execute and clear any pending deferred sync (used before overwriting with a new one).
    private func flushDeferredSync() async {
        guard let sync = deferredSync else { return }
        deferredSync = nil
        try? await sync()
    }

    /// Clear the pending undo without restoring (used by auto-dismiss timer).
    func clearUndo() {
        let sync = deferredSync
        pendingUndo = nil
        deferredSync = nil
        if let sync {
            Task {
                do {
                    try await sync()
                } catch {
                    AppLogger.shared.error(.work, "Deferred sync failed on clearUndo", error)
                }
            }
        }
    }

    /// Restores the most recent undoable action. Called from UndoToast tap.
    func performUndo() {
        guard let action = pendingUndo else { return }
        pendingUndo = nil
        deferredSync = nil // Cancel the deferred backend operation

        switch action {
        case .exerciseRemoved(let exercise, let index, let previousTotals):
            guard var w = workout else { return }
            let insertionIndex = min(index, w.exercises.count)
            w.exercises.insert(exercise, at: insertionIndex)
            for i in w.exercises.indices { w.exercises[i].position = i }
            w.totals = previousTotals
            workout = w
            updateHasTemplateChanges()

        case .setRemoved(let exerciseId, let set, let index):
            guard var w = workout,
                  let exIdx = w.exercises.firstIndex(where: { $0.instanceId == exerciseId }) else { return }
            let insertionIndex = min(index, w.exercises[exIdx].sets.count)
            w.exercises[exIdx].sets.insert(set, at: insertionIndex)
            if set.status == .done {
                w.totals = recalculateTotals(for: w)
            }
            workout = w
        }
    }

    // MARK: - Mutation Coordinator
    
    /// Serial mutation queue for sync ordering + dependency satisfaction
    private let mutationCoordinator = MutationCoordinator()
    
    // MARK: - Singleton (optional - can also inject)
    
    static let shared = FocusModeWorkoutService()
    
    private init() {
        setupMutationCoordinator()
    }
    
    /// Wire mutation coordinator callbacks
    private func setupMutationCoordinator() {
        // Note: The MutationCoordinator is an actor, so we set up the callback
        // using a closure that will be called from within the actor.
        // Callback now includes sessionId for staleness validation.
        Task {
            await mutationCoordinator.setStateChangeHandler { [weak self] change, sessionId in
                guard let self = self else { return }
                // Use Task to dispatch to MainActor
                Task { @MainActor [weak self] in
                    await self?.handleMutationStateChange(change, sessionId: sessionId)
                }
            }
        }
    }
    
    /// Handle mutation coordinator state changes
    /// Validates sessionId to prevent stale callbacks from affecting new workout sessions
    @MainActor
    private func handleMutationStateChange(_ change: MutationStateChange, sessionId: UUID) async {
        // Session scoping: ignore callbacks from old sessions
        guard sessionId == currentSessionId else {
            AppLogger.shared.info(.work, "Ignoring stale callback for old session")
            return
        }
        
        switch change {
        case .syncSuccess(let mutation):
            AppLogger.shared.info(.work, "Mutation synced: \(mutation)")
            sessionLog.log(.syncSuccess, details: ["mutation": String(describing: mutation)])
            // Update entity sync state on success
            updateEntitySyncState(mutation: mutation, state: .synced)

        case .syncFailed(let mutation, let error):
            AppLogger.shared.error(.work, "Mutation failed: \(mutation), error: \(error)")
            sessionLog.log(.syncFailed, details: [
                "mutation": String(describing: mutation),
                "error": error
            ])
            self.error = error
            // Update entity sync state on failure
            updateEntitySyncState(mutation: mutation, state: .failed(error))
            // Rollback optimistic state on failure
            rollbackMutation(mutation)
            
        case .needsReconcile:
            AppLogger.shared.info(.work, "Reconciliation needed - fetching latest state")
            sessionLog.log(.reconciliation, details: ["trigger": "TARGET_NOT_FOUND"])
            await performReconciliation()
        }
    }
    
    /// Update per-entity sync state for UI indicators
    private func updateEntitySyncState(mutation: WorkoutMutation, state: EntitySyncState) {
        switch mutation {
        case .addExercise(let instanceId, _, _, _, _):
            exerciseSyncState[instanceId] = state
        case .addSet(let exerciseInstanceId, _, _, _, _, _),
             .removeSet(let exerciseInstanceId, _),
             .patchSet(let exerciseInstanceId, _, _, _),
             .logSet(let exerciseInstanceId, _, _, _, _, _):
            // For set mutations, we track at the exercise level
            exerciseSyncState[exerciseInstanceId] = state
        default:
            break
        }
    }
    
    /// Mark an exercise as syncing (called before enqueue)
    private func markExerciseSyncing(_ exerciseInstanceId: String) {
        exerciseSyncState[exerciseInstanceId] = .syncing
    }
    
    /// Rollback optimistic state on sync failure
    private func rollbackMutation(_ mutation: WorkoutMutation) {
        guard var workout = workout else { return }
        
        switch mutation {
        case .addExercise(let instanceId, _, _, _, _):
            // Remove optimistically added exercise
            workout.exercises.removeAll { $0.instanceId == instanceId }
            self.workout = workout
            AppLogger.shared.info(.work, "Rolled back exercise: \(instanceId)")
            
        case .addSet(let exId, let setId, _, _, _, _):
            // Remove optimistically added set
            if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exId }) {
                workout.exercises[exIdx].sets.removeAll { $0.id == setId }
            }
            self.workout = workout
            
        default:
            // Other mutations don't have optimistic state that needs rollback
            break
        }
    }
    
    /// Perform reconciliation: fetch latest workout state from server
    /// Uses selective hydration: only updates positions and totals, not exercise/set state
    /// This preserves user's local work while correcting structural integrity
    private func performReconciliation() async {
        guard var currentWorkout = workout else { return }
        
        do {
            // Fetch latest workout state via POST (since ApiClient only supports postJSON)
            let request = GetActiveWorkoutRequest(workoutId: currentWorkout.id)
            let response: GetActiveWorkoutResponse = try await apiClient.postJSON("getActiveWorkout", body: request)
            
            if response.success, let serverData = response.data?.workout {
                // SELECTIVE HYDRATION: Only update positions and totals, not exercise/set state

                // 1. Update totals from server (source of truth)
                if let serverTotals = serverData.totals {
                    currentWorkout.totals = serverTotals
                }
                
                // 2. Build lookup of server positions by instanceId
                let serverPositions: [String: Int] = Dictionary(
                    uniqueKeysWithValues: (serverData.exercises ?? []).map { ($0.instanceId, $0.position) }
                )
                
                // 3. Update positions for exercises that exist on server
                for i in currentWorkout.exercises.indices {
                    let instanceId = currentWorkout.exercises[i].instanceId
                    if let serverPosition = serverPositions[instanceId] {
                        currentWorkout.exercises[i].position = serverPosition
                    }
                }
                
                // 4. Remove exercises that don't exist on server (deleted)
                let serverExerciseIds = Set((serverData.exercises ?? []).map { $0.instanceId })
                currentWorkout.exercises.removeAll { !serverExerciseIds.contains($0.instanceId) }
                
                // 5. Sort by position to match server order
                currentWorkout.exercises.sort { $0.position < $1.position }
                
                self.workout = currentWorkout
                
                // Build set keys from updated workout
                let exerciseIds = currentWorkout.exercises.map { $0.instanceId }
                let setKeys = currentWorkout.exercises.flatMap { ex in
                    ex.sets.map { SetKey(exerciseInstanceId: ex.instanceId, setId: $0.id) }
                }
                
                // Complete reconciliation
                await mutationCoordinator.finishReconcile(exerciseIds: exerciseIds, setKeys: setKeys)
                
                AppLogger.shared.info(.work, "Reconciliation complete (selective hydration)")
            }
        } catch {
            AppLogger.shared.error(.work, "Reconciliation failed", error)
            self.error = "Failed to sync with server"
        }
    }
    
    /// Full state refresh from server — merges new exercises added externally
    /// (e.g., by the workout coach agent) while preserving local set state.
    func refreshFromServer() async {
        guard let currentWorkout = workout else { return }

        do {
            let request = GetActiveWorkoutRequest(workoutId: currentWorkout.id)
            let response: GetActiveWorkoutResponse = try await apiClient.postJSON("getActiveWorkout", body: request)

            guard response.success, let serverData = response.data?.workout else { return }

            var merged = currentWorkout

            // Build lookup of local exercises by instanceId
            let localIds = Set(merged.exercises.map { $0.instanceId })
            let serverExercises = serverData.exercises ?? []
            let serverIds = Set(serverExercises.map { $0.instanceId })

            // Build server exercise lookup
            let serverExerciseLookup = Dictionary(uniqueKeysWithValues: serverExercises.map { ($0.instanceId, $0) })

            // Remove exercises that no longer exist on server
            merged.exercises.removeAll { !serverIds.contains($0.instanceId) }

            // Update existing exercises: sync planned set values from server
            // (agent may have modified weight/reps via prescribe_set)
            for i in merged.exercises.indices {
                let instanceId = merged.exercises[i].instanceId
                guard let serverEx = serverExerciseLookup[instanceId] else { continue }

                // Update position from server
                merged.exercises[i].position = serverEx.position

                // Build server set lookup
                let serverSets = Dictionary(uniqueKeysWithValues: (serverEx.sets ?? []).map { ($0.id, $0) })

                for j in merged.exercises[i].sets.indices {
                    let setId = merged.exercises[i].sets[j].id
                    guard let serverSet = serverSets[setId] else { continue }

                    // Only update planned sets — don't overwrite user-completed sets
                    if merged.exercises[i].sets[j].status == .planned {
                        let serverWeight = serverSet.targetWeight ?? serverSet.weight
                        let serverReps = serverSet.targetReps ?? serverSet.reps
                        let serverRir = serverSet.targetRir ?? serverSet.rir
                        merged.exercises[i].sets[j].targetWeight = serverWeight
                        merged.exercises[i].sets[j].targetReps = serverReps
                        merged.exercises[i].sets[j].targetRir = serverRir
                        merged.exercises[i].sets[j].weight = serverSet.weight
                        merged.exercises[i].sets[j].reps = serverSet.reps
                        merged.exercises[i].sets[j].rir = serverSet.rir
                    }
                }

                // Add sets from server that don't exist locally
                let localSetIds = Set(merged.exercises[i].sets.map { $0.id })
                for serverSetDto in serverEx.sets ?? [] where !localSetIds.contains(serverSetDto.id) {
                    merged.exercises[i].sets.append(FocusModeSet(
                        id: serverSetDto.id,
                        setType: FocusModeSetType(rawValue: serverSetDto.setType ?? "working") ?? .working,
                        status: FocusModeSetStatus(rawValue: serverSetDto.status ?? "planned") ?? .planned,
                        targetWeight: serverSetDto.targetWeight ?? serverSetDto.weight,
                        targetReps: serverSetDto.targetReps ?? serverSetDto.reps,
                        targetRir: serverSetDto.targetRir ?? serverSetDto.rir,
                        weight: serverSetDto.weight,
                        reps: serverSetDto.reps,
                        rir: serverSetDto.rir
                    ))
                }

                // Remove sets that no longer exist on server
                let serverSetIds = Set((serverEx.sets ?? []).map { $0.id })
                merged.exercises[i].sets.removeAll { !serverSetIds.contains($0.id) }
            }

            // Add exercises from server that don't exist locally (agent-added)
            for exDto in serverExercises where !localIds.contains(exDto.instanceId) {
                let sets = (exDto.sets ?? []).map { setDto -> FocusModeSet in
                    FocusModeSet(
                        id: setDto.id,
                        setType: FocusModeSetType(rawValue: setDto.setType ?? "working") ?? .working,
                        status: FocusModeSetStatus(rawValue: setDto.status ?? "planned") ?? .planned,
                        targetWeight: setDto.targetWeight ?? setDto.weight,
                        targetReps: setDto.targetReps ?? setDto.reps,
                        targetRir: setDto.targetRir ?? setDto.rir,
                        weight: setDto.weight,
                        reps: setDto.reps,
                        rir: setDto.rir
                    )
                }
                merged.exercises.append(FocusModeExercise(
                    instanceId: exDto.instanceId,
                    exerciseId: exDto.exerciseId,
                    name: exDto.name,
                    position: exDto.position,
                    sets: sets
                ))
            }

            // Update totals from server
            if let serverTotals = serverData.totals {
                merged.totals = serverTotals
            }

            // Sort by position
            merged.exercises.sort { $0.position < $1.position }

            self.workout = merged
        } catch {
            AppLogger.shared.error(.work, "refreshFromServer failed", error)
        }
    }

    // MARK: - Workout Lifecycle

    /// Load existing active workout (for resume)
    /// Get current active workout (for resume gate)
    /// Returns nil if no in_progress workout exists
    func getActiveWorkout() async throws -> FocusModeWorkout? {
        let response: GetActiveWorkoutNewResponse = try await apiClient.postJSON("getActiveWorkout", body: EmptyRequest())
        
        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to get active workout")
        }
        
        guard let workoutData = response.workout else {
            return nil
        }
        
        // Parse workout from response
        let workout = FocusModeWorkout(from: workoutData)
        self.workout = workout

        sessionLog.begin(workoutId: workout.id, name: workout.name, resumed: true)

        // Reset coordinator for this session
        await mutationCoordinator.reset()
        currentSessionId = await mutationCoordinator.getSessionId()

        return workout
    }
    
    /// Start workout from plan (for Canvas session_plan start action)
    func startWorkoutFromPlan(plan: [[String: Any]]) async throws -> FocusModeWorkout {
        return try await startWorkout(
            name: nil,
            sourceTemplateId: nil,
            sourceRoutineId: nil,
            plan: plan
        )
    }
    
    /// Extended startWorkout that accepts plan parameter
    func startWorkout(
        name: String? = nil,
        sourceTemplateId: String? = nil,
        sourceRoutineId: String? = nil,
        plan: [[String: Any]]? = nil
    ) async throws -> FocusModeWorkout {
        isLoading = true
        defer { isLoading = false }
        
        // Reset coordinator and get its session ID
        await mutationCoordinator.reset()
        currentSessionId = await mutationCoordinator.getSessionId()
        FocusModeLogger.shared.sessionReset(newSessionId: currentSessionId!.uuidString)
        
        let request = StartActiveWorkoutExtendedRequest(
            name: name,
            sourceTemplateId: sourceTemplateId,
            sourceRoutineId: sourceRoutineId,
            plan: plan
        )
        
        let response: StartActiveWorkoutNewResponse = try await apiClient.postJSON("startActiveWorkout", body: request)
        
        guard response.success else {
            throw FocusModeError.startFailed(response.error ?? "Unknown error")
        }
        
        // Check if this was a resume
        if response.resumed {
            AppLogger.shared.info(.work, "Resumed existing workout \(response.workoutId ?? "unknown")")
        }
        
        // Parse workout from response
        let parsedWorkout = FocusModeWorkout(fromNewResponse: response)
        self.workout = parsedWorkout

        // Capture template snapshot for change detection (Phase 3)
        if sourceTemplateId != nil {
            self.templateSnapshot = parsedWorkout.exercises
        } else {
            self.templateSnapshot = nil
        }
        self.hasTemplateChanges = false

        sessionLog.begin(
            workoutId: parsedWorkout.id,
            name: parsedWorkout.name,
            resumed: response.resumed
        )

        // Track workout start time for first-set detection
        workoutStartedAt = Date()
        hasLoggedFirstSet = false

        // Determine analytics source
        let analyticsSource: AnalyticsWorkoutSource = sourceRoutineId != nil ? .nextScheduled : (sourceTemplateId != nil ? .template : .empty)
        AnalyticsService.shared.workoutStarted(
            source: analyticsSource,
            workoutId: parsedWorkout.id,
            templateId: sourceTemplateId,
            routineId: sourceRoutineId,
            plannedExerciseCount: parsedWorkout.exercises.count
        )
        AnalyticsService.shared.recordWorkoutStarted()

        return parsedWorkout
    }

    // MARK: - Log Set (Hot Path)
    
    /// Mark a set as done - this is the PRIMARY action in focus mode
    /// Must feel instant - apply locally first, sync async (no global isSyncing flag)
    func logSet(
        exerciseInstanceId: String,
        setId: String,
        weight: Double?,
        reps: Int,
        rir: Int?,
        isFailure: Bool? = nil
    ) async throws -> WorkoutTotals {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        sessionLog.log(.setLogged, details: [
            "exercise": exerciseInstanceId,
            "set": setId,
            "weight": weight ?? 0,
            "reps": reps,
            "rir": rir ?? -1,
            "isFailure": isFailure ?? false
        ])

        // Track first set logged for time-to-first-set analytics
        if !hasLoggedFirstSet {
            hasLoggedFirstSet = true
            let secondsToFirst = Int(Date().timeIntervalSince(workoutStartedAt ?? Date()))
            AnalyticsService.shared.workoutFirstSetLogged(workoutId: workout.id, secondsToFirstSet: secondsToFirst)
        }

        // 1. Apply optimistically to local state (coordinator handles dependency ordering)
        applyLogSetLocally(exerciseInstanceId: exerciseInstanceId, setId: setId, weight: weight, reps: reps, rir: rir, isFailure: isFailure)
        
        // 2. Generate idempotency key
        let idempotencyKey = idempotencyHelper.generate(
            context: "logSet",
            exerciseId: exerciseInstanceId,
            setId: setId
        )
        
        // 3. Build request
        let request = LogSetRequest(
            workoutId: workout.id,
            exerciseInstanceId: exerciseInstanceId,
            setId: setId,
            values: LogSetRequest.SetValues(weight: weight, reps: reps, rir: rir),
            isFailure: isFailure,
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        // 4. Sync to backend (no isSyncing flag - hot path stays fully responsive)
        inFlightSyncCount += 1
        defer { inFlightSyncCount -= 1 }
        do {
            let response: LogSetResponse = try await apiClient.postJSON("logSet", body: request)

            if response.success, let totals = response.totals {
                // Update totals and version from server (source of truth)
                self.workout?.totals = totals
                if let version = response.version { self.workout?.version = version }
                return totals
            } else {
                throw FocusModeError.syncFailed(response.error ?? "Unknown error")
            }
        } catch {
            // Log sync failure but don't rollback local state
            // User can continue working offline
            AppLogger.shared.error(.work, "logSet sync failed", error)
            sessionLog.log(.syncFailed, details: ["op": "logSet", "error": error.localizedDescription])
            FirebaseConfig.shared.recordError(error, context: ["op": "logSet"])
            self.error = "Set sync failed - tap to retry"
            // Don't throw - let user continue workout
            // Return local totals computed from self.workout
            return computeLocalTotals()
        }
    }
    
    // MARK: - Patch Active Workout
    
    /// Edit a field value (weight, reps, rir, etc.)
    func patchField(
        exerciseInstanceId: String,
        setId: String,
        field: String,
        value: Any
    ) async throws -> WorkoutTotals {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        sessionLog.log(.fieldPatched, details: [
            "exercise": exerciseInstanceId,
            "set": setId,
            "field": field,
            "value": value
        ])

        // 1. Apply optimistically
        applyPatchLocally(exerciseInstanceId: exerciseInstanceId, setId: setId, field: field, value: value)
        
        // 2. Generate idempotency key
        let idempotencyKey = idempotencyHelper.generate(
            context: "patch",
            exerciseId: exerciseInstanceId,
            setId: setId,
            field: field
        )
        
        // 3. Build request
        let op = PatchOperationDTO(
            op: "set_field",
            target: PatchTargetDTO(exerciseInstanceId: exerciseInstanceId, setId: setId),
            field: field,
            value: AnyCodable(value)
        )
        
        let request = PatchActiveWorkoutRequest(
            workoutId: workout.id,
            ops: [op],
            cause: "user_edit",
            uiSource: "cell_edit",
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date()),
            aiScope: nil
        )
        
        // 4. Sync to backend (debounced in production)
        inFlightSyncCount += 1
        defer { inFlightSyncCount -= 1 }
        return try await syncPatch(request)
    }
    
    /// Add a new set to an exercise
    func addSet(
        exerciseInstanceId: String,
        setType: FocusModeSetType = .working,
        weight: Double? = nil,
        reps: Int = 10,
        rir: Int? = 2
    ) async throws -> WorkoutTotals {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        let newSetId = UUID().uuidString

        sessionLog.log(.setAdded, details: [
            "exercise": exerciseInstanceId,
            "setId": newSetId,
            "type": setType.rawValue
        ])

        // 1. Apply optimistically
        let newSet = FocusModeSet(
            id: newSetId,
            setType: setType,
            status: .planned,
            targetWeight: weight,
            targetReps: reps,
            targetRir: rir
        )
        addSetLocally(exerciseInstanceId: exerciseInstanceId, set: newSet)
        
        // 2. Build request - use reps/rir/weight (not target_*) per backend schema
        let idempotencyKey = idempotencyHelper.generate(context: "addSet", setId: newSetId)
        
        // Use typed struct to ensure proper JSON encoding
        let addSetValue = AddSetValueDTO(
            id: newSetId,
            setType: setType.rawValue,
            status: "planned",
            reps: reps,
            rir: rir ?? 2,
            weight: weight  // Nullable for bodyweight
        )
        
        let request = AddSetPatchRequest(
            workoutId: workout.id,
            op: AddSetOperationDTO(
                op: "add_set",
                target: PatchTargetDTO(exerciseInstanceId: exerciseInstanceId, setId: nil),
                value: addSetValue
            ),
            cause: "user_edit",
            uiSource: "add_set_button",
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        return try await syncAddSetPatch(request)
    }
    
    /// Add a new exercise to the workout
    /// Uses optimistic updates for instant feedback - coordinator handles sync and rollback
    func addExercise(
        exercise: Exercise,
        withSets initialSets: [FocusModeSet]? = nil
    ) async throws {
        guard let workout = workout,
              let exerciseId = exercise.id else {
            throw FocusModeError.noActiveWorkout
        }

        let newInstanceId = UUID().uuidString
        let defaultSets = initialSets ?? [
            FocusModeSet(
                id: UUID().uuidString,
                setType: .working,
                status: .planned,
                targetReps: 10,
                targetRir: 2
            )
        ]

        let newExercise = FocusModeExercise(
            instanceId: newInstanceId,
            exerciseId: exerciseId,
            name: exercise.name,
            position: workout.exercises.count,
            sets: defaultSets
        )

        sessionLog.log(.exerciseAdded, details: [
            "instanceId": newInstanceId,
            "exerciseId": exerciseId,
            "name": exercise.name,
            "sets": defaultSets.count
        ])

        // 1. Apply optimistically - exercise appears immediately
        var updatedWorkout = workout
        updatedWorkout.exercises.append(newExercise)
        self.workout = updatedWorkout
        updateHasTemplateChanges()

        // Haptic feedback immediately on tap
        HapticManager.modeToggle()

        AppLogger.shared.info(.work, "Optimistically added exercise: \(newInstanceId) with sets: \(defaultSets.map { $0.id })")

        // 2. Build mutation for coordinator
        let mutationSets = defaultSets.map { set in
            MutationSetData(
                id: set.id,
                setType: set.setType.rawValue,
                status: set.status.rawValue,
                targetReps: set.targetReps,
                targetRir: set.targetRir,
                targetWeight: set.targetWeight
            )
        }

        // 3. Mark as syncing for UI indicator
        markExerciseSyncing(newInstanceId)

        // 4. Enqueue to coordinator (fire-and-forget, coordinator handles sync/rollback)
        await mutationCoordinator.setWorkout(workout.id)
        await mutationCoordinator.enqueue(.addExercise(
            instanceId: newInstanceId,
            exerciseId: exerciseId,
            name: exercise.name,
            position: newExercise.position,
            sets: mutationSets
        ))

        // 5. Fire analytics event
        AnalyticsService.shared.exerciseAdded(workoutId: workout.id, source: .search)
    }
    
    /// Remove a set from an exercise
    func removeSet(
        exerciseInstanceId: String,
        setId: String
    ) async throws -> WorkoutTotals {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }

        sessionLog.log(.setRemoved, details: [
            "exercise": exerciseInstanceId,
            "setId": setId
        ])

        // 0. Capture undo state before removal
        if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }),
           let setIdx = workout.exercises[exIdx].sets.firstIndex(where: { $0.id == setId }) {
            let removedSet = workout.exercises[exIdx].sets[setIdx]
            pendingUndo = .setRemoved(exerciseId: exerciseInstanceId, set: removedSet, index: setIdx)
        }

        // 1. Apply optimistically
        removeSetLocally(exerciseInstanceId: exerciseInstanceId, setId: setId)
        
        // 2. Build request
        let idempotencyKey = idempotencyHelper.generate(context: "removeSet", setId: setId)
        
        let op = PatchOperationDTO(
            op: "remove_set",
            target: PatchTargetDTO(exerciseInstanceId: exerciseInstanceId, setId: setId),
            field: nil,
            value: nil
        )
        
        let request = PatchActiveWorkoutRequest(
            workoutId: workout.id,
            ops: [op],
            cause: "user_edit",
            uiSource: "swipe_delete",
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date()),
            aiScope: nil
        )
        
        // Execute any pending deferred sync before overwriting
        await flushDeferredSync()

        // Defer backend sync until undo window expires
        deferredSync = { [weak self] in
            let _ = try await self?.syncPatch(request)
        }
        // Return optimistic totals from local state
        return self.workout?.totals ?? workout.totals
    }

    /// Remove an exercise from the workout
    func removeExercise(exerciseInstanceId: String) async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }

        // 1. Capture rollback state BEFORE removal
        guard let removedIndex = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) else {
            return
        }
        let removedExercise = workout.exercises[removedIndex]
        let previousTotals = workout.totals

        sessionLog.log(.exerciseRemoved, details: [
            "instanceId": exerciseInstanceId,
            "name": removedExercise.name
        ])

        // 2. Apply optimistically - remove exercise immediately
        var updatedWorkout = workout
        updatedWorkout.exercises.remove(at: removedIndex)

        // Update positions
        for i in updatedWorkout.exercises.indices {
            updatedWorkout.exercises[i].position = i
        }

        // Recalculate totals
        updatedWorkout.totals = recalculateTotals(for: updatedWorkout)

        self.workout = updatedWorkout
        updateHasTemplateChanges()

        // Store undo state (Tier 1: immediate removal + undo toast, no haptic)
        pendingUndo = .exerciseRemoved(exercise: removedExercise, index: removedIndex, previousTotals: previousTotals)

        AppLogger.shared.info(.work, "Optimistically removed exercise: \(exerciseInstanceId)")

        // 3. Fire analytics event
        AnalyticsService.shared.exerciseRemoved(workoutId: workout.id)

        // 4. Build and send request
        let idempotencyKey = idempotencyHelper.generate(context: "removeExercise", exerciseId: exerciseInstanceId)

        let op = PatchOperationDTO(
            op: "remove_exercise",
            target: PatchTargetDTO(exerciseInstanceId: exerciseInstanceId, setId: nil),
            field: nil,
            value: nil
        )

        let request = PatchActiveWorkoutRequest(
            workoutId: workout.id,
            ops: [op],
            cause: "user_edit",
            uiSource: "menu_delete",
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date()),
            aiScope: nil
        )

        // Execute any pending deferred sync before overwriting
        await flushDeferredSync()

        // Defer backend sync until undo window expires
        deferredSync = { [weak self] in
            do {
                let _ = try await self?.syncPatch(request)
                AppLogger.shared.info(.work, "removeExercise synced to backend")
            } catch {
                AppLogger.shared.error(.work, "removeExercise deferred sync failed", error)
            }
        }
    }
    
    /// Swap an exercise in the active workout for a different one
    /// Uses optimistic updates — exercise swaps instantly in UI, syncs to backend
    func swapExercise(
        exerciseInstanceId: String,
        newExerciseId: String,
        newExerciseName: String,
        reason: String = "user_swap"
    ) async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }

        guard let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) else {
            throw FocusModeError.syncFailed("Exercise not found")
        }

        let originalExercise = workout.exercises[exIdx]

        sessionLog.log(.exerciseSwapped, details: [
            "instanceId": exerciseInstanceId,
            "fromExerciseId": originalExercise.exerciseId,
            "fromName": originalExercise.name,
            "toExerciseId": newExerciseId,
            "toName": newExerciseName
        ])

        // 1. Apply optimistically — swap exercise_id and name, keep sets/position/instanceId
        var updatedWorkout = workout
        updatedWorkout.exercises[exIdx].exerciseId = newExerciseId
        updatedWorkout.exercises[exIdx].name = newExerciseName
        self.workout = updatedWorkout
        updateHasTemplateChanges()

        HapticManager.modeToggle()

        // 2. Fire analytics event
        AnalyticsService.shared.exerciseSwapped(workoutId: workout.id, source: .menu)

        // 3. Mark as syncing
        markExerciseSyncing(exerciseInstanceId)

        // 4. Call swap-exercise endpoint directly (not through mutation coordinator)
        let request = SwapExerciseRequest(
            workoutId: workout.id,
            fromExerciseId: exerciseInstanceId,
            toExerciseId: newExerciseId,
            reason: reason
        )

        do {
            let response: SwapExerciseResponse = try await apiClient.postJSON("swapExercise", body: request)
            exerciseSyncState[exerciseInstanceId] = .synced
            if !response.success {
                // Rollback
                var rollback = self.workout ?? updatedWorkout
                if let idx = rollback.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) {
                    rollback.exercises[idx].exerciseId = originalExercise.exerciseId
                    rollback.exercises[idx].name = originalExercise.name
                }
                self.workout = rollback
                self.error = response.error ?? "Failed to swap exercise"
                throw FocusModeError.syncFailed(response.error ?? "Swap failed")
            }
        } catch let error as FocusModeError {
            throw error
        } catch {
            // Network/decode error — rollback
            exerciseSyncState[exerciseInstanceId] = .synced
            var rollback = self.workout ?? updatedWorkout
            if let idx = rollback.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) {
                rollback.exercises[idx].exerciseId = originalExercise.exerciseId
                rollback.exercises[idx].name = originalExercise.name
            }
            self.workout = rollback
            self.error = "Failed to swap exercise"
            throw error
        }
    }

    // MARK: - Workout Lifecycle Actions

    /// Cancel (discard) the active workout
    func cancelWorkout() async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        let request = CancelWorkoutRequest(workoutId: workout.id)
        
        isLoading = true
        defer { isLoading = false }
        
        let response: CancelWorkoutResponse = try await apiClient.postJSON("cancelActiveWorkout", body: request)
        
        if response.success {
            sessionLog.end(outcome: .workoutCancelled)
            let durationMin = Int(Date().timeIntervalSince(workout.startTime) / 60)
            let setsCompleted = workout.exercises.reduce(0) { $0 + $1.sets.filter { $0.isDone }.count }
            let totalSets = workout.exercises.reduce(0) { $0 + $1.sets.count }
            AnalyticsService.shared.workoutCancelled(
                workoutId: workout.id,
                durationMin: durationMin,
                setsCompleted: setsCompleted,
                totalSets: totalSets
            )
            // Reset coordinator to clear pending mutations and invalidate callbacks
            await mutationCoordinator.reset()
            currentSessionId = nil
            self.templateSnapshot = nil
            self.hasTemplateChanges = false
            self.workout = nil  // Clear local state
        } else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to cancel workout")
        }
    }
    
    /// Complete (finish) the active workout
    func completeWorkout() async throws -> String {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }

        // Drain any in-flight logSet/patchField calls before completing.
        // Task.sleep yields the MainActor, letting pending defer blocks decrement the counter.
        var drainAttempts = 0
        let maxDrainAttempts = 600  // 30 seconds at 50ms intervals
        while inFlightSyncCount > 0 && drainAttempts < maxDrainAttempts {
            try? await Task.sleep(nanoseconds: 50_000_000)
            drainAttempts += 1
        }
        if inFlightSyncCount > 0 {
            throw FocusModeError.syncTimeout
        }

        let request = CompleteWorkoutRequest(workoutId: workout.id)

        isLoading = true
        defer { isLoading = false }
        
        let response: CompleteWorkoutResponse = try await apiClient.postJSON("completeActiveWorkout", body: request)
        
        if response.success {
            let archivedId = response.workoutId ?? workout.id
            sessionLog.log(.workoutCompleted, details: [
                "archivedId": archivedId,
                "exercises": self.workout?.exercises.count ?? 0,
                "totalSets": self.workout?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
            ])
            sessionLog.end(outcome: .workoutCompleted)
            let durationMin = Int(Date().timeIntervalSince(workout.startTime) / 60)
            let exerciseCount = workout.exercises.count
            let setCount = workout.exercises.reduce(0) { $0 + $1.sets.filter { $0.isDone }.count }
            let totalSets = workout.exercises.reduce(0) { $0 + $1.sets.count }
            let source: AnalyticsWorkoutSource = workout.sourceRoutineId != nil ? .nextScheduled : (workout.sourceTemplateId != nil ? .template : .empty)
            AnalyticsService.shared.workoutCompleted(WorkoutCompletedParams(
                workoutId: archivedId,
                durationMin: durationMin,
                exerciseCount: exerciseCount,
                totalSets: totalSets,
                setsCompleted: setCount,
                source: source,
                templateId: workout.sourceTemplateId,
                routineId: workout.sourceRoutineId
            ))
            AnalyticsService.shared.recordLastWorkoutDate()
            AnalyticsService.shared.recordWorkoutDuration(durationMin)
            AnalyticsService.shared.recordWorkoutSource(source)
            // Reset coordinator to clear pending mutations and invalidate callbacks
            await mutationCoordinator.reset()
            currentSessionId = nil
            self.templateSnapshot = nil
            self.hasTemplateChanges = false
            self.workout = nil  // Clear local state
            invalidateLibraryCache()
            return archivedId
        } else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to complete workout")
        }
    }

    /// Save current workout modifications back to the source template
    /// Uses hybrid approach: actuals for done sets, targets for planned sets, skip skipped sets
    func saveChangesToTemplate() async {
        guard let workout = workout,
              let templateId = workout.sourceTemplateId else { return }

        // Map current exercises to template format
        let templateExercises: [[String: Any]] = workout.exercises.enumerated().map { index, exercise in
            let sets: [[String: Any]] = exercise.sets.compactMap { set in
                guard set.status != .skipped else { return nil }
                let isDone = set.status == .done
                let repsValue: Int = isDone ? (set.reps ?? set.targetReps ?? 0) : (set.targetReps ?? 0)
                let weightValue: Double = isDone ? (set.weight ?? set.targetWeight ?? 0) : (set.targetWeight ?? 0)
                var setDict: [String: Any] = [
                    "id": set.id,
                    "type": set.setType.rawValue,
                    "reps": repsValue,
                    "weight": weightValue
                ]
                let rir = isDone ? set.rir : set.targetRir
                if let rir { setDict["rir"] = rir }
                return setDict
            }
            return [
                "id": UUID().uuidString,
                "exercise_id": exercise.exerciseId,
                "name": exercise.name,
                "position": index,
                "sets": sets
            ] as [String: Any]
        }

        let patch: [String: Any] = [
            "exercises": templateExercises
        ]

        do {
            try await patchTemplate(templateId: templateId, patch: patch, changeSource: "workout_save", workoutId: workout.id)
        } catch {
            // Non-blocking — workout completion should not be affected
            AppLogger.shared.error(.work, "Failed to update template", error)
            self.error = "Template could not be updated"
        }
    }

    /// Compute local totals from self.workout (fallback when sync fails)
    private func computeLocalTotals() -> WorkoutTotals {
        guard let workout = workout else {
            return WorkoutTotals()
        }

        var totalVolume: Double = 0
        var completedSets = 0
        var totalReps = 0

        for exercise in workout.exercises {
            for set in exercise.sets {
                if set.isDone {
                    completedSets += 1
                    if let weight = set.displayWeight, let reps = set.displayReps {
                        totalVolume += weight * Double(reps)
                        totalReps += reps
                    }
                }
            }
        }

        return WorkoutTotals(
            sets: completedSets,
            reps: totalReps,
            volume: totalVolume
        )
    }

    /// Update the workout name with optimistic updates and coordinator sync
    func updateWorkoutName(_ name: String) async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        // Validate: name cannot be empty
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw FocusModeError.syncFailed("Workout name cannot be empty")
        }
        
        sessionLog.log(.nameChanged, details: ["name": trimmedName])

        // Optimistically update local state
        self.workout?.name = trimmedName

        // Enqueue to coordinator with coalescing (last-write-wins)
        await mutationCoordinator.setWorkout(workout.id)
        await mutationCoordinator.enqueue(.patchWorkoutMetadata(
            field: .name,
            value: .string(trimmedName)
        ))
    }
    
    /// Update the workout notes with optimistic updates and coordinator sync
    func updateWorkoutNotes(_ notes: String?) async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }

        // Normalize: empty/whitespace-only → nil
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed

        // Optimistically update local state
        self.workout?.notes = normalizedNotes

        // Enqueue to coordinator with coalescing (last-write-wins)
        // Backend normalizes empty string to null
        await mutationCoordinator.setWorkout(workout.id)
        await mutationCoordinator.enqueue(.patchWorkoutMetadata(
            field: .notes,
            value: .string(normalizedNotes ?? "")
        ))
    }

    /// Update exercise-level notes with optimistic updates and coordinator sync
    func updateExerciseNotes(exerciseInstanceId: String, notes: String?) async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }

        // Normalize: empty/whitespace-only → nil
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed

        // Optimistically update local state
        if let idx = self.workout?.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) {
            self.workout?.exercises[idx].notes = normalizedNotes
        }

        // Enqueue to coordinator with coalescing (last-write-wins)
        await mutationCoordinator.setWorkout(workout.id)
        await mutationCoordinator.enqueue(.patchExerciseField(
            exerciseInstanceId: exerciseInstanceId,
            field: .notes,
            value: .string(normalizedNotes ?? "")
        ))
    }

    /// Update the workout start time (adjusts timer) with validation and coordinator sync
    func updateStartTime(_ newStartTime: Date) async throws {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        // Validate: start time cannot be in the future
        guard newStartTime <= Date() else {
            throw FocusModeError.syncFailed("Start time cannot be in the future")
        }
        
        // Validate: start time cannot be more than 24 hours ago
        let maxPastTime: TimeInterval = 24 * 60 * 60  // 24 hours
        guard Date().timeIntervalSince(newStartTime) <= maxPastTime else {
            throw FocusModeError.syncFailed("Start time cannot be more than 24 hours ago")
        }
        
        sessionLog.log(.startTimeChanged, details: ["newStartTime": newStartTime.description])

        // Optimistically update local state
        self.workout?.startTime = newStartTime

        // Convert to ISO8601 string for backend
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoString = isoFormatter.string(from: newStartTime)
        
        // Enqueue to coordinator with coalescing (last-write-wins)
        await mutationCoordinator.setWorkout(workout.id)
        await mutationCoordinator.enqueue(.patchWorkoutMetadata(
            field: .startTime,
            value: .string(isoString)
        ))
    }
    
    /// Reorder exercises and sync to backend
    func reorderExercises(from source: IndexSet, to destination: Int) {
        guard var workout = workout else { return }
        
        workout.exercises.move(fromOffsets: source, toOffset: destination)
        
        // Update positions to match new order
        for (index, _) in workout.exercises.enumerated() {
            workout.exercises[index].position = index
        }
        
        self.workout = workout
        
        // Get new order as array of instance IDs
        let newOrder = workout.exercises.map { $0.instanceId }

        sessionLog.log(.exercisesReordered, details: [
            "order": newOrder.joined(separator: ",")
        ])

        // Fire analytics event
        AnalyticsService.shared.exerciseReordered(workoutId: workout.id)

        // Sync to backend (fire and forget - don't block UI)
        Task {
            await syncReorderToBackend(workoutId: workout.id, order: newOrder)
        }

        AppLogger.shared.info(.work, "Reordered exercises: \(newOrder)")
    }
    
    /// Sync exercise reorder to backend
    private func syncReorderToBackend(workoutId: String, order: [String]) async {
        let idempotencyKey = idempotencyHelper.generate(context: "reorder", exerciseId: order.joined(separator: "-"))
        
        let request = ReorderExercisesRequest(
            workoutId: workoutId,
            order: order,
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        do {
            let _: PatchActiveWorkoutResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
            AppLogger.shared.info(.work, "Reorder synced to backend")
        } catch {
            AppLogger.shared.error(.work, "Reorder sync failed", error)
            // Don't rollback - local state is source of truth during session
            // Order will be preserved when workout is completed
        }
    }
    
    // MARK: - AI Actions
    
    /// Autofill exercise with AI prescription
    func autofillExercise(
        exerciseInstanceId: String,
        updates: [AutofillSetUpdate],
        additions: [AutofillSetAddition]
    ) async throws -> WorkoutTotals {
        guard let workout = workout else {
            throw FocusModeError.noActiveWorkout
        }
        
        let idempotencyKey = idempotencyHelper.generate(context: "autofill", exerciseId: exerciseInstanceId)
        
        let request = AutofillExerciseRequest(
            workoutId: workout.id,
            exerciseInstanceId: exerciseInstanceId,
            updates: updates,
            additions: additions,
            idempotencyKey: idempotencyKey,
            clientTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        let response: AutofillExerciseResponse = try await apiClient.postJSON("autofillExercise", body: request)
        
        if response.success, let totals = response.totals {
            // Apply updates locally
            applyAutofillLocally(exerciseInstanceId: exerciseInstanceId, updates: updates, additions: additions)
            self.workout?.totals = totals
            if let version = response.version { self.workout?.version = version }
            return totals
        } else {
            throw FocusModeError.autofillFailed(response.error ?? "Unknown error")
        }
    }
    
    // MARK: - Private Helpers
    
    private func syncPatch(_ request: PatchActiveWorkoutRequest) async throws -> WorkoutTotals {
        let response: PatchActiveWorkoutResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)

        if response.success, let totals = response.totals {
            self.workout?.totals = totals
            if let version = response.version { self.workout?.version = version }
            return totals
        } else {
            throw FocusModeError.syncFailed(response.error ?? "Unknown error")
        }
    }

    private func syncAddSetPatch(_ request: AddSetPatchRequest) async throws -> WorkoutTotals {
        let response: PatchActiveWorkoutResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)

        if response.success, let totals = response.totals {
            self.workout?.totals = totals
            if let version = response.version { self.workout?.version = version }
            return totals
        } else {
            throw FocusModeError.syncFailed(response.error ?? "Unknown error")
        }
    }
    
    // MARK: - Template Change Detection

    /// Compare current workout exercises against the snapshot taken at start
    /// Called after exercise mutations (swap, add, remove, weight change)
    private func updateHasTemplateChanges() {
        guard let snapshot = templateSnapshot,
              let currentExercises = workout?.exercises else {
            hasTemplateChanges = false
            return
        }

        // Different exercise count
        if currentExercises.count != snapshot.count {
            hasTemplateChanges = true
            return
        }

        // Compare exercise IDs at each position
        for (current, original) in zip(currentExercises, snapshot) {
            if current.exerciseId != original.exerciseId {
                hasTemplateChanges = true
                return
            }
            // Different set count
            if current.sets.count != original.sets.count {
                hasTemplateChanges = true
                return
            }
            // Compare set weights
            for (cs, os) in zip(current.sets, original.sets) {
                if cs.weight != os.weight || cs.targetWeight != os.targetWeight {
                    hasTemplateChanges = true
                    return
                }
                if cs.reps != os.reps || cs.targetReps != os.targetReps {
                    hasTemplateChanges = true
                    return
                }
            }
        }

        hasTemplateChanges = false
    }

    // MARK: - Optimistic Updates

    private func applyLogSetLocally(
        exerciseInstanceId: String,
        setId: String,
        weight: Double?,
        reps: Int,
        rir: Int?,
        isFailure: Bool?
    ) {
        guard var workout = workout else { return }
        
        if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }),
           let setIdx = workout.exercises[exIdx].sets.firstIndex(where: { $0.id == setId }) {
            
            // Track if this is a new completion (for incrementing totals)
            let wasPlanned = workout.exercises[exIdx].sets[setIdx].status == .planned
            
            workout.exercises[exIdx].sets[setIdx].status = .done
            workout.exercises[exIdx].sets[setIdx].weight = weight
            workout.exercises[exIdx].sets[setIdx].reps = reps
            workout.exercises[exIdx].sets[setIdx].rir = rir
            if let isFailure = isFailure {
                workout.exercises[exIdx].sets[setIdx].tags = FocusModeSetTags(isFailure: isFailure)
            }
            
            // Recalculate totals locally for immediate UI feedback
            if wasPlanned {
                workout.totals = recalculateTotals(for: workout)
            }

            self.workout = workout
            updateHasTemplateChanges()
        }
    }

    /// Recalculate workout totals from current state
    private func recalculateTotals(for workout: FocusModeWorkout) -> WorkoutTotals {
        var totalSets = 0
        var totalReps = 0
        var totalVolume: Double = 0
        
        for exercise in workout.exercises {
            for set in exercise.sets where set.status == .done {
                totalSets += 1
                let setReps = set.reps ?? 0
                totalReps += setReps
                totalVolume += (set.weight ?? 0) * Double(setReps)
            }
        }
        
        return WorkoutTotals(sets: totalSets, reps: totalReps, volume: totalVolume)
    }
    
    private func applyPatchLocally(
        exerciseInstanceId: String,
        setId: String,
        field: String,
        value: Any
    ) {
        guard var workout = workout else { return }
        
        if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }),
           let setIdx = workout.exercises[exIdx].sets.firstIndex(where: { $0.id == setId }) {
            
            let currentSet = workout.exercises[exIdx].sets[setIdx]
            let previousStatus = currentSet.status
            var needsTotalsRecalc = false
            
            switch field {
            case "weight":
                if let doubleValue = value as? Double {
                    if workout.exercises[exIdx].sets[setIdx].isPlanned {
                        workout.exercises[exIdx].sets[setIdx].targetWeight = doubleValue
                    } else {
                        workout.exercises[exIdx].sets[setIdx].weight = doubleValue
                        // Recalc if weight changed on a done set
                        if currentSet.isDone { needsTotalsRecalc = true }
                    }
                }
            case "reps":
                if let intValue = value as? Int {
                    if workout.exercises[exIdx].sets[setIdx].isPlanned {
                        workout.exercises[exIdx].sets[setIdx].targetReps = intValue
                    } else {
                        workout.exercises[exIdx].sets[setIdx].reps = intValue
                        // Recalc if reps changed on a done set
                        if currentSet.isDone { needsTotalsRecalc = true }
                    }
                }
            case "rir":
                if let intValue = value as? Int {
                    if workout.exercises[exIdx].sets[setIdx].isPlanned {
                        workout.exercises[exIdx].sets[setIdx].targetRir = intValue
                    } else {
                        workout.exercises[exIdx].sets[setIdx].rir = intValue
                    }
                }
            case "status":
                if let stringValue = value as? String,
                   let newStatus = FocusModeSetStatus(rawValue: stringValue) {
                    workout.exercises[exIdx].sets[setIdx].status = newStatus
                    
                    // Handle undo: when reverting to planned, clear actuals only (keep targets)
                    if previousStatus == .done && newStatus == .planned {
                        workout.exercises[exIdx].sets[setIdx].weight = nil
                        workout.exercises[exIdx].sets[setIdx].reps = nil
                        workout.exercises[exIdx].sets[setIdx].rir = nil
                        workout.exercises[exIdx].sets[setIdx].tags?.isFailure = nil
                    }
                    
                    // Recalc totals on any status transition involving done
                    if previousStatus == .done || newStatus == .done {
                        needsTotalsRecalc = true
                    }
                }
            case "set_type":
                if let stringValue = value as? String,
                   let setType = FocusModeSetType(rawValue: stringValue) {
                    workout.exercises[exIdx].sets[setIdx].setType = setType
                }
            case "tags.is_failure":
                if let boolValue = value as? Bool {
                    if workout.exercises[exIdx].sets[setIdx].tags == nil {
                        workout.exercises[exIdx].sets[setIdx].tags = FocusModeSetTags(isFailure: boolValue)
                    } else {
                        workout.exercises[exIdx].sets[setIdx].tags?.isFailure = boolValue
                    }
                }
            default:
                break
            }
            
            // Recalculate totals if needed
            if needsTotalsRecalc {
                workout.totals = recalculateTotals(for: workout)
            }
            
            self.workout = workout
        }
    }
    
    private func addSetLocally(exerciseInstanceId: String, set: FocusModeSet) {
        guard var workout = workout else { return }
        
        if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) {
            workout.exercises[exIdx].sets.append(set)
            self.workout = workout
        }
    }
    
    private func removeSetLocally(exerciseInstanceId: String, setId: String) {
        guard var workout = workout else { return }
        
        if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) {
            // Check if the removed set was completed (affects totals)
            let wasCompleted = workout.exercises[exIdx].sets.first(where: { $0.id == setId })?.status == .done
            
            workout.exercises[exIdx].sets.removeAll { $0.id == setId }
            
            // Recalculate totals if a completed set was removed
            if wasCompleted {
                workout.totals = recalculateTotals(for: workout)
            }
            
            self.workout = workout
        }
    }
    
    private func applyAutofillLocally(
        exerciseInstanceId: String,
        updates: [AutofillSetUpdate],
        additions: [AutofillSetAddition]
    ) {
        guard var workout = workout else { return }
        
        if let exIdx = workout.exercises.firstIndex(where: { $0.instanceId == exerciseInstanceId }) {
            for update in updates {
                if let setIdx = workout.exercises[exIdx].sets.firstIndex(where: { $0.id == update.setId }) {
                    if let weight = update.weight { workout.exercises[exIdx].sets[setIdx].targetWeight = weight }
                    if let reps = update.reps { workout.exercises[exIdx].sets[setIdx].targetReps = reps }
                    if let rir = update.rir { workout.exercises[exIdx].sets[setIdx].targetRir = rir }
                }
            }
            
            for addition in additions {
                let newSet = FocusModeSet(
                    id: addition.id,
                    setType: FocusModeSetType(rawValue: addition.setType) ?? .working,
                    status: .planned,
                    targetWeight: addition.weight,
                    targetReps: addition.reps,
                    targetRir: addition.rir
                )
                workout.exercises[exIdx].sets.append(newSet)
            }
            
            self.workout = workout
        }
    }
    
    // MARK: - Template & Routine Methods
    
    /// Lightweight template info for picker
    struct TemplateInfo: Identifiable {
        let id: String
        let name: String
        let exerciseCount: Int
        let setCount: Int
        
        init(from dict: [String: Any]) {
            self.id = dict["id"] as? String ?? ""
            self.name = dict["name"] as? String ?? "Untitled"
            
            // Count exercises and sets
            if let exercises = dict["exercises"] as? [[String: Any]] {
                self.exerciseCount = exercises.count
                self.setCount = exercises.reduce(0) { sum, ex in
                    sum + ((ex["sets"] as? [[String: Any]])?.count ?? 0)
                }
            } else {
                self.exerciseCount = 0
                self.setCount = 0
            }
        }
    }
    
    /// Lightweight routine info for list display
    struct RoutineInfo: Identifiable {
        let id: String
        let name: String
        let workoutCount: Int
        let isActive: Bool
        
        init(from dict: [String: Any]) {
            self.id = dict["id"] as? String ?? ""
            self.name = dict["name"] as? String ?? "Untitled Routine"
            
            // Count templates as workouts - API returns template_ids array
            if let templateIds = dict["template_ids"] as? [String] {
                self.workoutCount = templateIds.count
            } else if let templates = dict["templates"] as? [[String: Any]] {
                self.workoutCount = templates.count
            } else if let templateCount = dict["template_count"] as? Int {
                self.workoutCount = templateCount
            } else {
                self.workoutCount = 0
            }
            
            self.isActive = dict["is_active"] as? Bool ?? false
        }
    }
    
    /// Next workout info from routine cursor
    struct NextWorkoutInfo {
        let template: TemplateInfo?
        let routineId: String?       // Required for cursor advancement
        let routineName: String?
        let templateIndex: Int
        let templateCount: Int
        let reason: String?  // "no_active_routine", "empty_routine", etc.
        
        var hasNextWorkout: Bool { template != nil }
    }
    
    /// Fetch all user templates for picker
    func getUserTemplates() async throws -> [TemplateInfo] {
        let request = GetUserTemplatesRequest()
        let response: GetUserTemplatesResponse = try await apiClient.postJSON("getUserTemplates", body: request)
        
        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to get templates")
        }
        
        return response.items.map { TemplateInfo(from: $0) }
    }
    
    /// Fetch a single template by ID with full exercise details
    func getTemplate(id: String) async throws -> WorkoutTemplate? {
        let request = GetTemplateRequest(templateId: id)
        let response: GetTemplateResponse = try await apiClient.postJSON("getTemplate", body: request)
        
        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to get template")
        }
        
        return response.template
    }
    
    /// Fetch next workout from routine rotation
    func getNextWorkout() async throws -> NextWorkoutInfo {
        let request = EmptyRequest()
        let response: GetNextWorkoutResponse = try await apiClient.postJSON("getNextWorkout", body: request)
        
        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to get next workout")
        }
        
        let template: TemplateInfo? = response.template.map { TemplateInfo(from: $0) }
        
        return NextWorkoutInfo(
            template: template,
            routineId: response.routine?["id"] as? String,  // P0-2 Fix: Extract routine ID for cursor advancement
            routineName: response.routine?["name"] as? String,
            templateIndex: response.templateIndex ?? 0,
            templateCount: response.templateCount ?? 0,
            reason: response.reason
        )
    }
    
    // MARK: - Library Editing Methods

    /// Patch an existing template (name, description, exercises)
    /// Server recomputes analytics via Firestore trigger when exercises change
    /// Optional metadata fields (changeSource, workoutId, recommendationId) are sent as
    /// top-level request body fields for changelog attribution in patch-template.js
    func patchTemplate(templateId: String, patch: [String: Any], changeSource: String? = nil, workoutId: String? = nil, recommendationId: String? = nil) async throws {
        let request = PatchTemplateRequest(templateId: templateId, patch: patch, changeSource: changeSource, workoutId: workoutId, recommendationId: recommendationId)
        let response: PatchTemplateResponse = try await apiClient.postJSON("patchTemplate", body: request)

        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to patch template")
        }
        invalidateLibraryCache()
    }

    /// Fetch a single routine by ID with full details
    func getRoutine(id: String) async throws -> Routine {
        let request = GetRoutineRequest(routineId: id)
        let response: GetRoutineResponse = try await apiClient.postJSON("getRoutine", body: request)

        guard response.success, let routine = response.routine else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to get routine")
        }

        return routine
    }

    /// Patch an existing routine (name, description, frequency, template_ids)
    func patchRoutine(routineId: String, patch: [String: Any]) async throws {
        let request = PatchRoutineRequest(routineId: routineId, patch: patch)
        let response: PatchRoutineResponse = try await apiClient.postJSON("patchRoutine", body: request)

        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to patch routine")
        }
        invalidateLibraryCache()
    }

    /// Delete a template by ID
    func deleteTemplate(templateId: String) async throws {
        let request = DeleteTemplateRequest(templateId: templateId)
        let response: DeleteEntityResponse = try await apiClient.postJSON("deleteTemplate", body: request)

        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to delete template")
        }
        invalidateLibraryCache()
    }

    /// Delete a routine by ID
    func deleteRoutine(routineId: String) async throws {
        let request = DeleteRoutineRequest(routineId: routineId)
        let response: DeleteEntityResponse = try await apiClient.postJSON("deleteRoutine", body: request)

        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to delete routine")
        }
        invalidateLibraryCache()
    }

    /// Upsert a completed workout (create or update)
    /// Backend recomputes all analytics, set_facts, and series inline
    func upsertWorkout(_ request: UpsertWorkoutRequest) async throws -> String {
        let response: UpsertWorkoutResponse = try await apiClient.postJSON("upsertWorkout", body: request)

        guard response.success, let workoutId = response.workoutId else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to upsert workout")
        }

        return workoutId
    }

    /// Fetch all user routines for Library
    func getUserRoutines() async throws -> [RoutineInfo] {
        let request = EmptyRequest()
        let response: GetUserRoutinesResponse = try await apiClient.postJSON("getUserRoutines", body: request)
        
        guard response.success else {
            throw FocusModeError.syncFailed(response.error ?? "Failed to get routines")
        }
        
        return response.items.map { RoutineInfo(from: $0) }
    }

    // MARK: - Library Prefetch

    /// Prefetch all data needed by Train and Library tabs.
    /// Called from RootView on auth completion — runs templates, routines,
    /// next workout, and active workout check all in parallel.
    func prefetchLibraryData() async {
        guard !isPrefetching else { return }
        isPrefetching = true
        defer { isPrefetching = false }

        async let templates = getUserTemplates()
        async let routines = getUserRoutines()
        async let nextWorkout: NextWorkoutInfo? = {
            do { return try await self.getNextWorkout() }
            catch { return nil }
        }()
        let hasWorkout = workout != nil
        async let activeWorkout: FocusModeWorkout? = {
            // Only check if we don't already have a workout loaded
            guard !hasWorkout else { return nil }
            do { return try await self.getActiveWorkout() }
            catch { return nil }
        }()

        do {
            let (t, r) = try await (templates, routines)
            self.cachedTemplates = t
            self.cachedRoutines = r
        } catch {
            // Prefetch failure is non-fatal — views will fetch on demand
            AppLogger.shared.error(.work, "Library prefetch failed", error)
        }

        // These are independent — store results even if library fetch failed
        self.cachedNextWorkout = await nextWorkout
        // activeWorkout side-effects (setting self.workout) happen inside getActiveWorkout()
        _ = await activeWorkout
    }

    /// Invalidate cached library data after mutations that change templates/routines.
    func invalidateLibraryCache() {
        cachedTemplates = nil
        cachedRoutines = nil
        cachedNextWorkout = nil
    }

    // MARK: - Last Session Data (Ghost Values)

    private nonisolated static let ghostLogger = Logger(subsystem: "com.povver.app", category: "GhostValues")

    /// Fetch last session data for all exercises in the current workout.
    /// Queries the set_facts Firestore subcollection grouped by exercise.
    /// Called after workout start to populate ghost values for undone sets.
    func fetchLastSessionData() async {
        guard let workout, let userId = AuthService.shared.currentUser?.uid else { return }

        let exerciseIds = Set(workout.exercises.map { $0.exerciseId })
        var result: [String: LastSessionExerciseData] = [:]
        let db = Firestore.firestore()

        // Fetch last session sets for each unique exercise from set_facts.
        // set_facts are ordered by workout_date desc, so first N non-warmup results
        // for each exercise represent the most recent session.
        await withTaskGroup(of: (String, LastSessionExerciseData?).self) { group in
            for exerciseId in exerciseIds {
                group.addTask {
                    do {
                        let snapshot = try await db.collection("users")
                            .document(userId)
                            .collection("set_facts")
                            .whereField("exercise_id", isEqualTo: exerciseId)
                            .whereField("is_warmup", isEqualTo: false)
                            .order(by: "workout_date", descending: true)
                            .limit(to: 20) // Enough sets for one session
                            .getDocuments()

                        guard !snapshot.documents.isEmpty else { return (exerciseId, nil) }

                        // Group by workout_id and take only the most recent workout's sets
                        var firstWorkoutId: String?
                        var sets: [LastSessionSetData] = []

                        for doc in snapshot.documents {
                            let data = doc.data()
                            let workoutId = data["workout_id"] as? String ?? ""
                            if firstWorkoutId == nil { firstWorkoutId = workoutId }
                            guard workoutId == firstWorkoutId else { break }

                            let setIndex = data["set_index"] as? Int
                            let weight = data["weight_kg"] as? Double
                            let reps = data["reps"] as? Int
                            let rir = data["rir"] as? Int
                            sets.append(LastSessionSetData(setIndex: setIndex, weight: weight, reps: reps, rir: rir))
                        }

                        // Sort by set_index to ensure correct ordering
                        // (Firestore query is ordered by workout_date, not set_index)
                        let sortedSets = sets.sorted { ($0.setIndex ?? Int.max) < ($1.setIndex ?? Int.max) }
                        return (exerciseId, sortedSets.isEmpty ? nil : LastSessionExerciseData(sets: sortedSets))
                    } catch {
                        Self.ghostLogger.warning("Failed to fetch last session for exercise \(exerciseId): \(error.localizedDescription)")
                        return (exerciseId, nil)
                    }
                }
            }

            for await (exerciseId, data) in group {
                if let data { result[exerciseId] = data }
            }
        }

        if result.isEmpty && !exerciseIds.isEmpty {
            Self.ghostLogger.error("Failed to fetch last session data for all exercises")
        }

        self.lastSessionData = result
    }
}

// MARK: - Template & Routine DTOs

private struct GetUserTemplatesRequest: Encodable {}

private struct GetUserTemplatesResponse: Decodable {
    let success: Bool
    let items: [[String: Any]]
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    private struct DataWrapper: Decodable {
        let items: [AnyCodableDict]?
        let count: Int?
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // API returns { data: { items: [...] }, success: true }
        // Decode items from nested data wrapper
        if let dataWrapper = try container.decodeIfPresent(DataWrapper.self, forKey: .data),
           let itemsData = dataWrapper.items {
            self.items = itemsData.map { $0.dict }
        } else {
            self.items = []
        }
    }
}

private struct GetNextWorkoutResponse: Decodable {
    let success: Bool
    let template: [String: Any]?
    let routine: [String: Any]?
    let templateIndex: Int?
    let templateCount: Int?
    let reason: String?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    private struct DataWrapper: Decodable {
        let template: AnyCodableDict?
        let routine: AnyCodableDict?
        let templateIndex: Int?
        let templateCount: Int?
        let selectionMethod: String?
        let reason: String?
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // API returns { data: { template, routine, templateIndex, ... }, success: true }
        if let dataWrapper = try container.decodeIfPresent(DataWrapper.self, forKey: .data) {
            self.template = dataWrapper.template?.dict
            self.routine = dataWrapper.routine?.dict
            self.templateIndex = dataWrapper.templateIndex
            self.templateCount = dataWrapper.templateCount
            self.reason = dataWrapper.reason
        } else {
            self.template = nil
            self.routine = nil
            self.templateIndex = nil
            self.templateCount = nil
            self.reason = nil
        }
    }
}

/// Helper to decode arbitrary JSON dictionaries
private struct AnyCodableDict: Decodable {
    let dict: [String: Any]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let jsonData = try container.decode([String: AnyCodable].self)
        self.dict = jsonData.mapValues { $0.value }
    }
}

private struct GetUserRoutinesResponse: Decodable {
    let success: Bool
    let items: [[String: Any]]
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    private struct DataWrapper: Decodable {
        let items: [AnyCodableDict]?  // API returns "items" not "routines"
        let count: Int?
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // API returns { data: { items: [...], count: N }, success: true }
        if let dataWrapper = try container.decodeIfPresent(DataWrapper.self, forKey: .data),
           let itemsData = dataWrapper.items {
            self.items = itemsData.map { $0.dict }
        } else {
            self.items = []
        }
    }
}

// MARK: - Library Editing DTOs

private struct PatchTemplateRequest: Encodable {
    let templateId: String
    let patch: [String: Any]
    let changeSource: String?
    let workoutId: String?
    let recommendationId: String?

    enum CodingKeys: String, CodingKey {
        case templateId
        case patch
        case changeSource = "change_source"
        case workoutId = "workout_id"
        case recommendationId = "recommendation_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(templateId, forKey: .templateId)
        try container.encode(AnyCodable(patch), forKey: .patch)
        try container.encodeIfPresent(changeSource, forKey: .changeSource)
        try container.encodeIfPresent(workoutId, forKey: .workoutId)
        try container.encodeIfPresent(recommendationId, forKey: .recommendationId)
    }
}

private struct PatchTemplateResponse: Decodable {
    let success: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, data, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

private struct GetRoutineRequest: Encodable {
    let routineId: String
}

private struct GetRoutineResponse: Decodable {
    let success: Bool
    let routine: Routine?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, data, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        // API returns { success: true, data: { ...routine fields... } }
        self.routine = try container.decodeIfPresent(Routine.self, forKey: .data)
    }
}

private struct PatchRoutineRequest: Encodable {
    let routineId: String
    let patch: [String: Any]

    enum CodingKeys: String, CodingKey {
        case routineId
        case patch
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routineId, forKey: .routineId)
        try container.encode(AnyCodable(patch), forKey: .patch)
    }
}

private struct PatchRoutineResponse: Decodable {
    let success: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, data, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Delete DTOs

private struct DeleteTemplateRequest: Encodable {
    let templateId: String
}

private struct DeleteRoutineRequest: Encodable {
    let routineId: String
}

private struct DeleteEntityResponse: Decodable {
    let success: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, data, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

private struct UpsertWorkoutResponse: Decodable {
    let success: Bool
    let workoutId: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, data, error
    }

    private struct DataWrapper: Decodable {
        let workoutId: String?

        enum CodingKeys: String, CodingKey {
            case workoutId = "workout_id"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        if let data = try container.decodeIfPresent(DataWrapper.self, forKey: .data) {
            self.workoutId = data.workoutId
        } else {
            self.workoutId = nil
        }
    }
}

// MARK: - Request/Response DTOs

private struct StartActiveWorkoutRequest: Encodable {
    let name: String?
    let sourceTemplateId: String?
    let sourceRoutineId: String?
    let exercises: [ExerciseDTO]?
    
    enum CodingKeys: String, CodingKey {
        case name
        case sourceTemplateId = "source_template_id"
        case sourceRoutineId = "source_routine_id"
        case exercises
    }
}

/// The server wraps the workout data in a "data" object
private struct StartActiveWorkoutResponse: Decodable {
    let success: Bool
    let data: StartActiveWorkoutData?
    let error: String?
    
    // Convenience accessors that unwrap from data
    var workoutId: String? { data?.workoutId ?? data?.activeWorkoutDoc?.id }
    var userId: String? { data?.activeWorkoutDoc?.userId }
    var name: String? { data?.activeWorkoutDoc?.name }
    var status: String? { data?.activeWorkoutDoc?.status }
    var exercises: [ExerciseDTO]? { nil } // Parse from activeWorkoutDoc if needed
    var totals: WorkoutTotals? { data?.activeWorkoutDoc?.totals }
    var sourceTemplateId: String? { data?.activeWorkoutDoc?.sourceTemplateId }
    var sourceRoutineId: String? { data?.activeWorkoutDoc?.sourceRoutineId }
    var startTime: String? { nil } // Firebase timestamps don't serialize as strings
    var endTime: String? { nil }
    var createdAt: String? { nil }
    var updatedAt: String? { nil }
}

private struct StartActiveWorkoutData: Decodable {
    let workoutId: String?
    let activeWorkoutDoc: StartActiveWorkoutDocDTO?
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case activeWorkoutDoc = "active_workout_doc"
    }
}

private struct StartActiveWorkoutDocDTO: Decodable {
    let id: String?
    let userId: String?
    let name: String?
    let status: String?
    let totals: WorkoutTotals?
    let sourceTemplateId: String?
    let sourceRoutineId: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case status
        case totals
        case sourceTemplateId = "source_template_id"
        case sourceRoutineId = "source_routine_id"
    }
}

private struct ExerciseDTO: Codable {
    let instanceId: String
    let exerciseId: String
    let name: String
    let position: Int
    let sets: [SetDTO]
    
    enum CodingKeys: String, CodingKey {
        case instanceId = "instance_id"
        case exerciseId = "exercise_id"
        case name
        case position
        case sets
    }
    
    init(from exercise: FocusModeExercise) {
        self.instanceId = exercise.instanceId
        self.exerciseId = exercise.exerciseId
        self.name = exercise.name
        self.position = exercise.position
        self.sets = exercise.sets.map { SetDTO(from: $0) }
    }
}

private struct SetDTO: Codable {
    let id: String
    let setType: String
    let status: String
    let weight: Double?
    let reps: Int?
    let rir: Int?
    
    enum CodingKeys: String, CodingKey {
        case id
        case setType = "set_type"
        case status
        case weight
        case reps
        case rir
    }
    
    init(from set: FocusModeSet) {
        self.id = set.id
        self.setType = set.setType.rawValue
        self.status = set.status.rawValue
        self.weight = set.targetWeight ?? set.weight
        self.reps = set.targetReps ?? set.reps
        self.rir = set.targetRir ?? set.rir
    }
}

private struct PatchOperationDTO: Encodable {
    let op: String
    let target: PatchTargetDTO
    let field: String?
    let value: AnyCodable?
}

// MARK: - Add Set Operation DTOs

/// Typed DTO for add_set operation to ensure proper JSON encoding
private struct AddSetOperationDTO: Encodable {
    let op: String
    let target: PatchTargetDTO
    let value: AddSetValueDTO
}

/// Typed value for add_set (matches backend Zod schema exactly)
private struct AddSetValueDTO: Encodable {
    let id: String
    let setType: String
    let status: String
    let reps: Int
    let rir: Int
    let weight: Double?  // Nullable for bodyweight
    
    enum CodingKeys: String, CodingKey {
        case id
        case setType = "set_type"
        case status
        case reps
        case rir
        case weight
    }
}

private struct PatchTargetDTO: Encodable {
    let exerciseInstanceId: String
    let setId: String?
    
    enum CodingKeys: String, CodingKey {
        case exerciseInstanceId = "exercise_instance_id"
        case setId = "set_id"
    }
}

private struct PatchActiveWorkoutRequest: Encodable {
    let workoutId: String
    let ops: [PatchOperationDTO]
    let cause: String
    let uiSource: String
    let idempotencyKey: String
    let clientTimestamp: String
    let aiScope: AIScopeDTO?
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops
        case cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
        case aiScope = "ai_scope"
    }
}

private struct AIScopeDTO: Encodable {
    let exerciseInstanceId: String
    
    enum CodingKeys: String, CodingKey {
        case exerciseInstanceId = "exercise_instance_id"
    }
}

private struct PatchActiveWorkoutResponse: Decodable {
    let success: Bool
    let eventId: String?
    let totals: WorkoutTotals?
    let version: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }

    private struct DataWrapper: Decodable {
        let success: Bool?
        let eventId: String?
        let totals: WorkoutTotals?
        let version: Int?

        enum CodingKeys: String, CodingKey {
            case success
            case eventId = "event_id"
            case totals
            case version
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Get top-level success
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)

        // Try to decode from nested data wrapper (new response format)
        if let data = try container.decodeIfPresent(DataWrapper.self, forKey: .data) {
            self.eventId = data.eventId
            self.totals = data.totals
            self.version = data.version
        } else {
            self.eventId = nil
            self.totals = nil
            self.version = nil
        }
    }
}

/// Specialized request for add_set to ensure proper encoding (wraps single op in array)
private struct AddSetPatchRequest: Encodable {
    let workoutId: String
    let op: AddSetOperationDTO
    let cause: String
    let uiSource: String
    let idempotencyKey: String
    let clientTimestamp: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops
        case cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        try container.encode([op], forKey: .ops)  // Wrap single op in array
        try container.encode(cause, forKey: .cause)
        try container.encode(uiSource, forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(clientTimestamp, forKey: .clientTimestamp)
    }
}

// MARK: - Cancel/Complete DTOs

private struct CancelWorkoutRequest: Encodable {
    let workoutId: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
    }
}

private struct CancelWorkoutResponse: Decodable {
    let success: Bool
    let error: String?
    
    // Handle nested data structure
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

private struct CompleteWorkoutRequest: Encodable {
    let workoutId: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
    }
}

private struct CompleteWorkoutResponse: Decodable {
    let success: Bool
    let workoutId: String?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    private struct DataWrapper: Decodable {
        let workoutId: String?
        
        enum CodingKeys: String, CodingKey {
            case workoutId = "workout_id"
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        if let data = try container.decodeIfPresent(DataWrapper.self, forKey: .data) {
            self.workoutId = data.workoutId
        } else {
            self.workoutId = nil
        }
    }
}

// MARK: - Reorder Exercises DTOs

private struct ReorderExercisesRequest: Encodable {
    let workoutId: String
    let order: [String]
    let idempotencyKey: String
    let clientTimestamp: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops
        case cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        
        // Build the reorder_exercises op
        let op = ReorderOpDTO(order: order)
        try container.encode([op], forKey: .ops)
        
        try container.encode("user_edit", forKey: .cause)
        try container.encode("reorder_exercises", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(clientTimestamp, forKey: .clientTimestamp)
    }
}

// MARK: - Swap Exercise DTOs

private struct SwapExerciseRequest: Encodable {
    let workoutId: String
    let fromExerciseId: String
    let toExerciseId: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case fromExerciseId = "from_exercise_id"
        case toExerciseId = "to_exercise_id"
        case reason
    }
}

private struct SwapExerciseResponse: Decodable {
    let success: Bool
    let error: String?
}

private struct ReorderOpDTO: Encodable {
    let op = "reorder_exercises"
    let order: [String]
    
    enum CodingKeys: String, CodingKey {
        case op
        case value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(op, forKey: .op)
        try container.encode(["order": order], forKey: .value)
    }
}

// MARK: - Add Exercise DTOs

private struct AddExerciseRequest: Encodable {
    let workoutId: String
    let instanceId: String
    let exerciseId: String
    let name: String
    let position: Int
    let sets: [AddExerciseSetDTO]
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case instanceId = "instance_id"
        case exerciseId = "exercise_id"
        case name
        case position
        case sets
    }
}

private struct AddExerciseSetDTO: Encodable {
    let id: String
    let setType: String
    let status: String
    let targetReps: Int?
    let targetRir: Int?
    let targetWeight: Double?
    
    enum CodingKeys: String, CodingKey {
        case id
        case setType = "set_type"
        case status
        case targetReps = "target_reps"
        case targetRir = "target_rir"
        case targetWeight = "target_weight"
    }
    
    init(from set: FocusModeSet) {
        self.id = set.id
        self.setType = set.setType.rawValue
        self.status = set.status.rawValue
        self.targetReps = set.targetReps
        self.targetRir = set.targetRir
        self.targetWeight = set.targetWeight
    }
}

private struct AddExerciseResponse: Decodable {
    let success: Bool
    let exerciseInstanceId: String?
    let totals: WorkoutTotals?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case exerciseInstanceId = "exercise_instance_id"
        case totals
        case error
    }
}

// MARK: - Get Active Workout DTOs (for reconciliation)

private struct GetActiveWorkoutRequest: Encodable {
    let workoutId: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
    }
}

private struct GetActiveWorkoutResponse: Decodable {
    let success: Bool
    let data: GetActiveWorkoutResponseData?
    let error: String?
}

/// Intermediate wrapper — ok() wraps handler output as { success, data: { success, workout } }
private struct GetActiveWorkoutResponseData: Decodable {
    let workout: GetActiveWorkoutData?
}

private struct GetActiveWorkoutData: Decodable {
    let id: String
    let userId: String?
    let name: String?
    let status: String?
    let exercises: [GetActiveWorkoutExerciseDTO]?
    let totals: WorkoutTotals?
    let version: Int?
    let startTime: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case status
        case exercises
        case totals
        case version
        case startTime = "start_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        exercises = try container.decodeIfPresent([GetActiveWorkoutExerciseDTO].self, forKey: .exercises)
        totals = try container.decodeIfPresent(WorkoutTotals.self, forKey: .totals)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        // start_time may be a String (ISO8601) or a Firestore Timestamp dict — decode flexibly
        startTime = try? container.decodeIfPresent(String.self, forKey: .startTime)
    }
}

private struct GetActiveWorkoutExerciseDTO: Decodable {
    let instanceId: String
    let exerciseId: String
    let name: String
    let position: Int
    let sets: [GetActiveWorkoutSetDTO]?
    
    enum CodingKeys: String, CodingKey {
        case instanceId = "instance_id"
        case exerciseId = "exercise_id"
        case name
        case position
        case sets
    }
}

private struct GetActiveWorkoutSetDTO: Decodable {
    let id: String
    let setType: String?
    let status: String?
    let targetWeight: Double?
    let targetReps: Int?
    let targetRir: Int?
    let weight: Double?
    let reps: Int?
    let rir: Int?
    
    enum CodingKeys: String, CodingKey {
        case id
        case setType = "set_type"
        case status
        case targetWeight = "target_weight"
        case targetReps = "target_reps"
        case targetRir = "target_rir"
        case weight, reps, rir
    }
}

// MARK: - Extensions for DTO conversion

extension FocusModeWorkout {
    /// Initialize from GetActiveWorkoutData (used in reconciliation)
    fileprivate init(from data: GetActiveWorkoutData) {
        let exercises = (data.exercises ?? []).map { exDto -> FocusModeExercise in
            let sets = (exDto.sets ?? []).map { setDto -> FocusModeSet in
                FocusModeSet(
                    id: setDto.id,
                    setType: FocusModeSetType(rawValue: setDto.setType ?? "working") ?? .working,
                    status: FocusModeSetStatus(rawValue: setDto.status ?? "planned") ?? .planned,
                    targetWeight: setDto.targetWeight,
                    targetReps: setDto.targetReps,
                    targetRir: setDto.targetRir,
                    weight: setDto.weight,
                    reps: setDto.reps,
                    rir: setDto.rir
                )
            }
            return FocusModeExercise(
                instanceId: exDto.instanceId,
                exerciseId: exDto.exerciseId,
                name: exDto.name,
                position: exDto.position,
                sets: sets
            )
        }
        
        let status = FocusModeWorkout.WorkoutStatus(rawValue: data.status ?? "in_progress") ?? .inProgress
        let startTime = parseISO8601Date(data.startTime) ?? Date()
        
        self.init(
            id: data.id,
            userId: data.userId ?? "",
            status: status,
            sourceTemplateId: nil,
            sourceRoutineId: nil,
            name: data.name,
            exercises: exercises,
            totals: data.totals ?? WorkoutTotals(),
            version: data.version ?? 0,
            startTime: startTime,
            endTime: nil,
            createdAt: Date(),
            updatedAt: nil
        )
    }
}

extension FocusModeExercise {
    fileprivate init(from dto: ExerciseDTO) {
        self.init(
            instanceId: dto.instanceId,
            exerciseId: dto.exerciseId,
            name: dto.name,
            position: dto.position,
            sets: dto.sets.map { FocusModeSet(from: $0) }
        )
    }
}

extension FocusModeSet {
    fileprivate init(from dto: SetDTO) {
        self.init(
            id: dto.id,
            setType: FocusModeSetType(rawValue: dto.setType) ?? .working,
            status: FocusModeSetStatus(rawValue: dto.status) ?? .planned,
            targetWeight: dto.weight,
            targetReps: dto.reps,
            targetRir: dto.rir,
            weight: dto.weight,
            reps: dto.reps,
            rir: dto.rir
        )
    }
}

// MARK: - Entity Sync State (for UI indicators)

/// Sync state for individual entities (exercises, sets)
enum EntitySyncState: Equatable {
    case synced
    case syncing
    case failed(String)
    
    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
    
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
    
    var errorMessage: String? {
        if case .failed(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Errors

enum FocusModeError: LocalizedError {
    case noActiveWorkout
    case startFailed(String)
    case syncFailed(String)
    case autofillFailed(String)
    case invalidResponse
    case syncTimeout

    var errorDescription: String? {
        switch self {
        case .noActiveWorkout:
            return "No active workout"
        case .startFailed(let msg):
            return "Failed to start workout: \(msg)"
        case .syncFailed(let msg):
            return "Sync failed: \(msg)"
        case .autofillFailed(let msg):
            return "Autofill failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from server"
        case .syncTimeout:
            return "Sets still syncing, please try again"
        }
    }
}

// MARK: - Idempotency Helper

class IdempotencyKeyHelper {
    static let shared = IdempotencyKeyHelper()
    
    private init() {}
    
    func generate(context: String, exerciseId: String? = nil, setId: String? = nil, field: String? = nil) -> String {
        let components = [context, exerciseId, setId, field].compactMap { $0 }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return "\(components.joined(separator: "-"))-\(timestamp)"
    }
}

// MARK: - New Response DTOs (for updated backend)

/// Empty request for endpoints that don't need parameters
private struct EmptyRequest: Encodable {}

/// Response for getActiveWorkout with new format
private struct GetActiveWorkoutNewResponse: Decodable {
    let success: Bool
    let workout: GetActiveWorkoutData?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    private struct DataWrapper: Decodable {
        let workout: GetActiveWorkoutData?
        let success: Bool?
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // API returns { data: { workout, success }, success: true }
        if let dataWrapper = try container.decodeIfPresent(DataWrapper.self, forKey: .data) {
            self.workout = dataWrapper.workout
        } else {
            self.workout = nil
        }
    }
}

/// Extended request that accepts plan parameter
private struct StartActiveWorkoutExtendedRequest: Encodable {
    let name: String?
    let sourceTemplateId: String?
    let sourceRoutineId: String?
    let plan: [[String: Any]]?
    
    enum CodingKeys: String, CodingKey {
        case name
        case sourceTemplateId = "template_id"
        case sourceRoutineId = "source_routine_id"
        case plan
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(sourceTemplateId, forKey: .sourceTemplateId)
        try container.encodeIfPresent(sourceRoutineId, forKey: .sourceRoutineId)
        
        // Encode plan as { blocks: [...] } if present
        if let plan = plan {
            let planWrapper: [String: Any] = ["blocks": plan]
            try container.encode(AnyCodable(planWrapper), forKey: .plan)
        }
    }
}

/// Response for startActiveWorkout with new consistent format
private struct StartActiveWorkoutNewResponse: Decodable {
    let success: Bool
    let workoutId: String?
    let workout: StartActiveWorkoutWorkoutData?
    let resumed: Bool
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    private struct DataWrapper: Decodable {
        let workoutId: String?
        let workout: StartActiveWorkoutWorkoutData?
        let resumed: Bool?
        let success: Bool?
        
        enum CodingKeys: String, CodingKey {
            case workoutId = "workout_id"
            case workout
            case resumed
            case success
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // API returns { data: { workout, workout_id, resumed }, success: true }
        if let dataWrapper = try container.decodeIfPresent(DataWrapper.self, forKey: .data) {
            self.workoutId = dataWrapper.workoutId
            self.workout = dataWrapper.workout
            self.resumed = dataWrapper.resumed ?? false
        } else {
            self.workoutId = nil
            self.workout = nil
            self.resumed = false
        }
    }
}

private struct StartActiveWorkoutWorkoutData: Decodable {
    let id: String
    let userId: String?
    let name: String?
    let status: String?
    let exercises: [GetActiveWorkoutExerciseDTO]?
    let totals: WorkoutTotals?
    let version: Int?
    let sourceTemplateId: String?
    let sourceRoutineId: String?
    let startTime: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case status
        case exercises
        case totals
        case version
        case sourceTemplateId = "source_template_id"
        case sourceRoutineId = "source_routine_id"
        case startTime = "start_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.userId = try container.decodeIfPresent(String.self, forKey: .userId)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.exercises = try container.decodeIfPresent([GetActiveWorkoutExerciseDTO].self, forKey: .exercises)
        self.totals = try container.decodeIfPresent(WorkoutTotals.self, forKey: .totals)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.sourceTemplateId = try container.decodeIfPresent(String.self, forKey: .sourceTemplateId)
        self.sourceRoutineId = try container.decodeIfPresent(String.self, forKey: .sourceRoutineId)
        
        // Handle start_time as either ISO8601 string or Firestore timestamp dictionary
        if let isoString = try? container.decode(String.self, forKey: .startTime) {
            self.startTime = parseISO8601Date(isoString)
        } else if let firestoreTimestamp = try? container.decode(FirestoreTimestamp.self, forKey: .startTime) {
            self.startTime = firestoreTimestamp.date
        } else {
            self.startTime = nil
        }
    }
}

/// Firestore timestamp format: { _seconds: Int, _nanoseconds: Int }
private struct FirestoreTimestamp: Decodable {
    let seconds: Int
    let nanoseconds: Int
    
    enum CodingKeys: String, CodingKey {
        case seconds = "_seconds"
        case nanoseconds = "_nanoseconds"
    }
    
    var date: Date {
        let timeInterval = TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000
        return Date(timeIntervalSince1970: timeInterval)
    }
}

extension FocusModeWorkout {
    /// Initialize from new response format
    fileprivate init(fromNewResponse response: StartActiveWorkoutNewResponse) {
        let workoutData = response.workout
        let exercises = (workoutData?.exercises ?? []).map { exDto -> FocusModeExercise in
            let sets = (exDto.sets ?? []).map { setDto -> FocusModeSet in
                FocusModeSet(
                    id: setDto.id,
                    setType: FocusModeSetType(rawValue: setDto.setType ?? "working") ?? .working,
                    status: FocusModeSetStatus(rawValue: setDto.status ?? "planned") ?? .planned,
                    targetWeight: setDto.targetWeight ?? setDto.weight,
                    targetReps: setDto.targetReps ?? setDto.reps,
                    targetRir: setDto.targetRir ?? setDto.rir,
                    weight: setDto.weight,
                    reps: setDto.reps,
                    rir: setDto.rir
                )
            }
            return FocusModeExercise(
                instanceId: exDto.instanceId,
                exerciseId: exDto.exerciseId,
                name: exDto.name,
                position: exDto.position,
                sets: sets
            )
        }
        
        let status = FocusModeWorkout.WorkoutStatus(rawValue: workoutData?.status ?? "in_progress") ?? .inProgress
        let startTime = workoutData?.startTime ?? Date()  // Already Date? from decoder
        
        self.init(
            id: response.workoutId ?? workoutData?.id ?? UUID().uuidString,
            userId: workoutData?.userId ?? "",
            status: status,
            sourceTemplateId: workoutData?.sourceTemplateId,
            sourceRoutineId: workoutData?.sourceRoutineId,
            name: workoutData?.name,
            exercises: exercises,
            totals: workoutData?.totals ?? WorkoutTotals(),
            version: workoutData?.version ?? 0,
            startTime: startTime,
            endTime: nil,
            createdAt: Date(),
            updatedAt: nil
        )
    }
}

// MARK: - Get Template DTOs

private struct GetTemplateRequest: Encodable {
    let templateId: String
    
    enum CodingKeys: String, CodingKey {
        case templateId = "template_id"
    }
}

private struct GetTemplateResponse: Decodable {
    let success: Bool
    let template: WorkoutTemplate?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case data
        case error
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        
        // API returns { success: true, data: {...template fields directly...} }
        // The template IS the data, not nested under data.template
        self.template = try container.decodeIfPresent(WorkoutTemplate.self, forKey: .data)
    }
}

// MARK: - Date Parsing Helper

/// Parse ISO8601 date strings from server (supports multiple formats)
private func parseISO8601Date(_ string: String?) -> Date? {
    guard let string = string else { return nil }
    
    // Try standard ISO8601 formatter first
    let iso8601 = ISO8601DateFormatter()
    iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso8601.date(from: string) {
        return date
    }
    
    // Try without fractional seconds
    iso8601.formatOptions = [.withInternetDateTime]
    if let date = iso8601.date(from: string) {
        return date
    }
    
    // Try Firebase timestamp format (common alternative)
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    if let date = dateFormatter.date(from: string) {
        return date
    }
    
    return nil
}
