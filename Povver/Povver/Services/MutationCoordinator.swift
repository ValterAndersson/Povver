/**
 * MutationCoordinator.swift
 * 
 * ═══════════════════════════════════════════════════════════════════════════════
 * MUTATION COORDINATOR - Serial Queue for Focus Mode Workout Operations
 * ═══════════════════════════════════════════════════════════════════════════════
 * 
 * PURPOSE:
 * This actor is the single source of truth for mutation ordering and dependency
 * satisfaction in Focus Mode. All network mutations flow through here to prevent
 * race conditions and TARGET_NOT_FOUND errors.
 *
 * ARCHITECTURE:
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │  FocusModeWorkoutService                                                    │
 * │  ├── Applies optimistic updates to local state                              │
 * │  └── Enqueues mutations to MutationCoordinator                              │
 * │                            │                                                 │
 * │                            ▼                                                 │
 * │  ┌─────────────────────────────────────────────────────────────────────┐    │
 * │  │  MutationCoordinator (actor)                                        │    │
 * │  │  ├── pending: [QueuedMutation]     - Waiting for dependencies       │    │
 * │  │  ├── ackExercises: Set<String>     - Server-confirmed exercises     │    │
 * │  │  ├── ackSets: Set<SetKey>          - Server-confirmed sets          │    │
 * │  │  ├── sessionId: UUID               - Prevents stale callbacks       │    │
 * │  │  └── inFlight: QueuedMutation?     - Currently executing            │    │
 * │  └─────────────────────────────────────────────────────────────────────┘    │
 * │                            │                                                 │
 * │                            ▼                                                 │
 * │  Backend API (addExercise, patchActiveWorkout, logSet, etc.)                │
 * └─────────────────────────────────────────────────────────────────────────────┘
 *
 * KEY BEHAVIORS:
 * 
 * 1. DEPENDENCY ORDERING
 *    - addSet waits until parent exercise is ACK'd
 *    - patchSet/logSet wait until target set is ACK'd
 *    - Prevents "set doesn't exist" errors from race conditions
 *
 * 2. SESSION SCOPING
 *    - Each workout session has a unique sessionId (UUID)
 *    - Callbacks include sessionId; service ignores stale sessions
 *    - reset() generates new sessionId, invalidating in-flight callbacks
 *    - Prevents: start workout A → callbacks from A corrupt workout B
 *
 * 3. COALESCING (Metadata Mutations)
 *    - patchWorkoutMetadata for same field replaces pending (last-write-wins)
 *    - Prevents: rapid typing sends N requests; only last value matters
 *
 * 4. PURGE ON REMOVE
 *    - removeExercise purges all pending mutations for that exercise
 *    - removeSet purges all pending mutations for that set
 *    - Prevents: queue contains patches for deleted entities
 *
 * 5. RECONCILIATION
 *    - On TARGET_NOT_FOUND, pauses processing and triggers reconciliation
 *    - Service fetches server state, calls finishReconcile()
 *    - Resume processing with updated ACK state
 *
 * USAGE (from FocusModeWorkoutService):
 * ```swift
 * // On workout start
 * await mutationCoordinator.reset()  // Invalidate old session
 * currentSessionId = UUID()
 * 
 * // On add exercise
 * var workout = self.workout
 * workout.exercises.append(newExercise)  // Optimistic
 * self.workout = workout
 * await mutationCoordinator.enqueue(.addExercise(...))
 * 
 * // Callback handler validates sessionId
 * func handleMutationStateChange(_ change: MutationStateChange, sessionId: UUID) {
 *     guard sessionId == currentSessionId else { return }  // Ignore stale
 *     // Apply changes...
 * }
 * ```
 *
 * MUTATION TYPES:
 * - addExercise: Creates exercise with initial sets (all ACK'd together)
 * - removeExercise: Deletes exercise (purges dependents first)
 * - addSet: Adds set to exercise (depends on exercise ACK)
 * - removeSet: Deletes set (purges dependents first)
 * - patchSet: Updates set field (depends on set ACK)
 * - logSet: Marks set done (depends on set ACK, hot path)
 * - reorderExercises: Updates exercise positions (no dependencies)
 * - patchWorkoutMetadata: Updates name/start_time (coalesced)
 */

import Foundation
import UIKit

// MARK: - Key Types

/// Stable identity for a set (not string concatenation)
struct SetKey: Hashable {
    let exerciseInstanceId: String
    let setId: String
}

/// Sync state for entities
enum SyncState: Equatable {
    case synced
    case pending
    case failed(String)  // Error message
    
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
    
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Mutation Types

/// Metadata field types for coalescing (last-write-wins)
enum MetadataField: String, Equatable {
    case name = "name"
    case startTime = "start_time"
    case notes = "notes"
}

/// All mutation types that go through the coordinator
enum WorkoutMutation: Equatable {
    case addExercise(instanceId: String, exerciseId: String, name: String, position: Int, sets: [MutationSetData])
    case removeExercise(instanceId: String)
    case addSet(exerciseInstanceId: String, setId: String, setType: String, reps: Int, rir: Int, weight: Double?)
    case removeSet(exerciseInstanceId: String, setId: String)
    case patchSet(exerciseInstanceId: String, setId: String, field: String, value: AnyCodableValue)
    case reorderExercises(order: [String])
    case logSet(exerciseInstanceId: String, setId: String, weight: Double?, reps: Int, rir: Int?, isFailure: Bool?)
    /// Patch workout-level metadata (name, start_time, notes) with coalescing semantics
    case patchWorkoutMetadata(field: MetadataField, value: AnyCodableValue)
    /// Patch exercise-level metadata (notes) with coalescing semantics
    case patchExerciseField(exerciseInstanceId: String, field: MetadataField, value: AnyCodableValue)

    /// Get the exercise instance ID this mutation depends on (if any)
    var exerciseDependency: String? {
        switch self {
        case .addSet(let exId, _, _, _, _, _),
             .removeSet(let exId, _),
             .patchSet(let exId, _, _, _),
             .logSet(let exId, _, _, _, _, _),
             .patchExerciseField(let exId, _, _):
            return exId
        default:
            return nil
        }
    }
    
    /// Get the set key this mutation depends on (if any)
    var setDependency: SetKey? {
        switch self {
        case .patchSet(let exId, let setId, _, _),
             .logSet(let exId, let setId, _, _, _, _):
            return SetKey(exerciseInstanceId: exId, setId: setId)
        default:
            return nil
        }
    }
    
    /// Check if this mutation is affected by a remove exercise
    func isAffectedByRemoveExercise(_ instanceId: String) -> Bool {
        switch self {
        case .addSet(let exId, _, _, _, _, _),
             .removeSet(let exId, _),
             .patchSet(let exId, _, _, _),
             .logSet(let exId, _, _, _, _, _),
             .patchExerciseField(let exId, _, _):
            return exId == instanceId
        default:
            return false
        }
    }
    
    /// Check if this mutation is affected by a remove set
    func isAffectedByRemoveSet(_ exerciseInstanceId: String, _ setId: String) -> Bool {
        switch self {
        case .patchSet(let exId, let sId, _, _),
             .logSet(let exId, let sId, _, _, _, _):
            return exId == exerciseInstanceId && sId == setId
        default:
            return false
        }
    }
}

/// Simple Any wrapper for mutation values
enum AnyCodableValue: Equatable, Encodable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    
    var rawValue: Any {
        switch self {
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .bool(let v): return v
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
    
    static func == (lhs: AnyCodableValue, rhs: AnyCodableValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let l), .int(let r)): return l == r
        case (.double(let l), .double(let r)): return l == r
        case (.string(let l), .string(let r)): return l == r
        case (.bool(let l), .bool(let r)): return l == r
        default: return false
        }
    }
}

/// Set data for addExercise mutation
struct MutationSetData: Equatable {
    let id: String
    let setType: String
    let status: String
    let targetReps: Int?
    let targetRir: Int?
    let targetWeight: Double?
}

/// Wrapper for queued mutations with retry tracking
struct QueuedMutation: Identifiable {
    let id: String  // Idempotency key - stable across retries
    var attempt: Int
    let mutation: WorkoutMutation
    let createdAt: Date
    
    init(mutation: WorkoutMutation) {
        self.id = UUID().uuidString  // Stable idempotency key
        self.attempt = 0
        self.mutation = mutation
        self.createdAt = Date()
    }
}

// MARK: - Mutation Result

enum MutationResult {
    case success
    case networkError(Error)
    case targetNotFound
    case serverError(Error)
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Mutation Coordinator Actor

actor MutationCoordinator {
    
    // MARK: - State
    
    /// Session ID to prevent stale callbacks from corrupting new workouts
    private var sessionId: UUID = UUID()
    
    /// Acknowledged exercises (server confirmed)
    private var ackExercises: Set<String> = []
    
    /// Acknowledged sets (server confirmed)
    private var ackSets: Set<SetKey> = []
    
    /// Pending mutations queue
    private var pending: [QueuedMutation] = []
    
    /// Currently executing mutation
    private var inFlight: QueuedMutation? = nil
    
    /// Whether we're reconciling state (pauses execution)
    private var isReconciling: Bool = false
    
    /// Maximum retry attempts for network errors
    private let maxRetries = 3
    
    /// API client reference
    private let apiClient = ApiClient.shared
    
    /// Callback to update local state on success/failure (includes sessionId for staleness check)
    private var onStateChange: ((MutationStateChange, UUID) async -> Void)?
    
    /// Set the state change handler (called from service setup)
    func setStateChangeHandler(_ handler: @escaping (MutationStateChange, UUID) async -> Void) {
        self.onStateChange = handler
    }
    
    /// Current workout ID
    private var workoutId: String?
    
    /// Get current session ID (for verification in callbacks)
    func getSessionId() -> UUID {
        return sessionId
    }
    
    // MARK: - Initialization
    
    init() {}
    
    /// Set the current workout ID
    func setWorkout(_ workoutId: String) {
        self.workoutId = workoutId
        // Pre-ACK exercises that exist in the workout (loaded from server)
        // This will be called after fetching existing workout
    }
    
    /// Pre-acknowledge existing entities (from server fetch)
    func acknowledgeExisting(exerciseIds: [String], setKeys: [SetKey]) {
        ackExercises.formUnion(exerciseIds)
        ackSets.formUnion(setKeys)
    }
    
    /// Reset coordinator state (on workout end/cancel)
    /// Generates new sessionId so any in-flight callbacks are ignored
    func reset() {
        sessionId = UUID()  // Invalidate all in-flight callbacks
        ackExercises.removeAll()
        ackSets.removeAll()
        pending.removeAll()
        inFlight = nil
        isReconciling = false
        workoutId = nil
        FocusModeLogger.shared.coordinatorReset(sessionId: sessionId.uuidString)
    }
    
    // MARK: - Enqueue
    
    /// Enqueue a mutation for processing
    func enqueue(_ mutation: WorkoutMutation) async {
        // If this is a remove operation, purge dependent mutations first
        purgeDependents(for: mutation)
        
        // Coalesce metadata mutations (last-write-wins)
        coalesceMutationIfNeeded(mutation)
        
        let queued = QueuedMutation(mutation: mutation)
        pending.append(queued)
        
        AppLogger.shared.info(.work, "Enqueued: \(mutation), pending count: \(pending.count)")
        
        // Trigger processing
        await processLoop()
    }
    
    /// Coalesce metadata mutations - remove any pending patch of the same type (last-write-wins)
    private func coalesceMutationIfNeeded(_ mutation: WorkoutMutation) {
        switch mutation {
        case .patchWorkoutMetadata(let field, _):
            // Remove any pending metadata patch of the same field type
            pending.removeAll { queued in
                if case .patchWorkoutMetadata(let existingField, _) = queued.mutation {
                    if existingField == field {
                        AppLogger.shared.info(.work, "Coalesced metadata mutation for field: \(field)")
                        return true
                    }
                }
                return false
            }
        case .patchExerciseField(let exId, let field, _):
            // Remove any pending exercise field patch for same (exerciseInstanceId, field) pair
            pending.removeAll { queued in
                if case .patchExerciseField(let existingExId, let existingField, _) = queued.mutation {
                    if existingExId == exId && existingField == field {
                        AppLogger.shared.info(.work, "Coalesced exercise field mutation for \(exId).\(field)")
                        return true
                    }
                }
                return false
            }
        default:
            break
        }
    }
    
    // MARK: - Processing Loop
    
    /// Main processing loop (not recursive)
    private func processLoop() async {
        // Don't process while reconciling or if already processing
        guard !isReconciling, inFlight == nil else { return }
        
        while inFlight == nil, !isReconciling,
              let idx = pending.firstIndex(where: { canExecute($0.mutation) }) {
            
            var queued = pending.remove(at: idx)
            queued.attempt += 1
            inFlight = queued
            
            AppLogger.shared.info(.work, "Executing: \(queued.mutation), attempt: \(queued.attempt)")
            
            let result = await execute(queued)
            
            // Capture sessionId before any async work
            let capturedSessionId = sessionId
            
            if result.isSuccess {
                markAck(queued.mutation)
                await onStateChange?(.syncSuccess(queued.mutation), capturedSessionId)
            } else {
                await handleFailure(queued, result: result, sessionId: capturedSessionId)
            }
            
            inFlight = nil
        }
        
        if !pending.isEmpty {
            AppLogger.shared.info(.work, "\(pending.count) mutations waiting for dependencies")
        }
    }
    
    // MARK: - Dependency Checking
    
    /// Check if a mutation's dependencies are satisfied
    private func canExecute(_ mutation: WorkoutMutation) -> Bool {
        // Check exercise dependency
        if let exId = mutation.exerciseDependency {
            guard ackExercises.contains(exId) else {
                return false
            }
        }
        
        // Check set dependency
        if let setKey = mutation.setDependency {
            guard ackSets.contains(setKey) else {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Purge Dependents
    
    /// Remove queued mutations that depend on a removed entity
    private func purgeDependents(for mutation: WorkoutMutation) {
        switch mutation {
        case .removeExercise(let instanceId):
            pending.removeAll { $0.mutation.isAffectedByRemoveExercise(instanceId) }
            AppLogger.shared.info(.work, "Purged mutations for removed exercise")
            
        case .removeSet(let exId, let setId):
            pending.removeAll { $0.mutation.isAffectedByRemoveSet(exId, setId) }
            AppLogger.shared.info(.work, "Purged mutations for removed set")
            
        default:
            break
        }
    }
    
    // MARK: - Acknowledgment
    
    /// Mark entities as acknowledged after successful mutation
    private func markAck(_ mutation: WorkoutMutation) {
        switch mutation {
        case .addExercise(let instanceId, _, _, _, let sets):
            ackExercises.insert(instanceId)
            // Also ACK all sets in the exercise
            for set in sets {
                ackSets.insert(SetKey(exerciseInstanceId: instanceId, setId: set.id))
            }
            AppLogger.shared.info(.work, "ACK exercise with \(sets.count) sets")
            
        case .addSet(let exId, let setId, _, _, _, _):
            ackSets.insert(SetKey(exerciseInstanceId: exId, setId: setId))
            AppLogger.shared.info(.work, "ACK set")
            
        case .removeExercise(let instanceId):
            ackExercises.remove(instanceId)
            // Remove all sets for this exercise
            ackSets = ackSets.filter { $0.exerciseInstanceId != instanceId }
            
        case .removeSet(let exId, let setId):
            ackSets.remove(SetKey(exerciseInstanceId: exId, setId: setId))
            
        default:
            break
        }
    }
    
    // MARK: - Failure Handling
    
    private func handleFailure(_ queued: QueuedMutation, result: MutationResult, sessionId: UUID) async {
        switch result {
        case .networkError, .serverError:
            // Retry with backoff if under max attempts
            if queued.attempt < maxRetries {
                var retryQueued = queued
                retryQueued.attempt = queued.attempt  // Attempt already incremented
                pending.insert(retryQueued, at: 0)  // Prioritize retry
                
                // Exponential backoff
                let delay = pow(2.0, Double(queued.attempt)) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                // Max retries exceeded
                await onStateChange?(.syncFailed(queued.mutation, "Network error after \(maxRetries) attempts"), sessionId)
            }
            
        case .targetNotFound:
            // DON'T retry. Trigger reconciliation.
            AppLogger.shared.error(.work, "TARGET_NOT_FOUND - triggering reconcile")
            await triggerReconcile(sessionId: sessionId)
            await onStateChange?(.syncFailed(queued.mutation, "Entity not found on server"), sessionId)
            
        case .success:
            break  // Already handled
        }
    }
    
    // MARK: - Reconciliation
    
    private func triggerReconcile(sessionId: UUID) async {
        guard !isReconciling else { return }
        
        isReconciling = true
        AppLogger.shared.info(.work, "Starting reconciliation")
        
        // Notify service to fetch latest state
        await onStateChange?(.needsReconcile, sessionId)
        
        // Note: The service should call finishReconcile() after fetching
    }
    
    /// Called by service after fetching latest workout state
    func finishReconcile(exerciseIds: [String], setKeys: [SetKey]) async {
        // Update ack state from fresh server data
        ackExercises = Set(exerciseIds)
        ackSets = Set(setKeys)
        
        // Remove pending mutations for entities that no longer exist
        pending.removeAll { queued in
            if let exId = queued.mutation.exerciseDependency {
                if !ackExercises.contains(exId) {
                    AppLogger.shared.info(.work, "Dropping mutation for missing exercise")
                    return true
                }
            }
            if let setKey = queued.mutation.setDependency {
                if !ackSets.contains(setKey) {
                    AppLogger.shared.info(.work, "Dropping mutation for missing set")
                    return true
                }
            }
            return false
        }
        
        isReconciling = false
        AppLogger.shared.info(.work, "Reconciliation complete, resuming processing")
        
        await processLoop()
    }
    
    // MARK: - Execute Mutation
    
    private func execute(_ queued: QueuedMutation) async -> MutationResult {
        guard let workoutId = workoutId else {
            return .serverError(NSError(domain: "MutationCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "No workout ID"]))
        }
        
        do {
            switch queued.mutation {
            case .addExercise(let instanceId, let exerciseId, let name, let position, let sets):
                let request = AddExerciseRequest(
                    workoutId: workoutId,
                    instanceId: instanceId,
                    exerciseId: exerciseId,
                    name: name,
                    position: position,
                    sets: sets.map { AddExerciseSetDTO(
                        id: $0.id,
                        setType: $0.setType,
                        status: $0.status,
                        targetReps: $0.targetReps,
                        targetRir: $0.targetRir,
                        targetWeight: $0.targetWeight
                    )}
                )
                let _: AddExerciseResponse = try await apiClient.postJSON("addExercise", body: request)
                return .success
                
            case .addSet(let exId, let setId, let setType, let reps, let rir, let weight):
                let request = AddSetRequest(
                    workoutId: workoutId,
                    exerciseInstanceId: exId,
                    setId: setId,
                    setType: setType,
                    reps: reps,
                    rir: rir,
                    weight: weight,
                    idempotencyKey: queued.id
                )
                let _: PatchResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
                return .success
                
            case .patchSet(let exId, let setId, let field, let value):
                let request = PatchSetRequest(
                    workoutId: workoutId,
                    exerciseInstanceId: exId,
                    setId: setId,
                    field: field,
                    value: value,
                    idempotencyKey: queued.id
                )
                let _: PatchResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
                return .success
                
            case .removeSet(let exId, let setId):
                let request = RemoveSetRequest(
                    workoutId: workoutId,
                    exerciseInstanceId: exId,
                    setId: setId,
                    idempotencyKey: queued.id
                )
                let _: PatchResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
                return .success
                
            case .removeExercise(let instanceId):
                // TODO: Implement remove exercise endpoint
                AppLogger.shared.info(.work, "removeExercise not yet implemented")
                return .success
                
            case .reorderExercises(let order):
                let request = ReorderRequest(
                    workoutId: workoutId,
                    order: order,
                    idempotencyKey: queued.id
                )
                let _: PatchResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
                return .success
                
            case .logSet(let exId, let setId, let weight, let reps, let rir, let isFailure):
                let request = LogSetMutationRequest(
                    workoutId: workoutId,
                    exerciseInstanceId: exId,
                    setId: setId,
                    weight: weight,
                    reps: reps,
                    rir: rir,
                    isFailure: isFailure,
                    idempotencyKey: queued.id
                )
                let _: LogSetMutationResponse = try await apiClient.postJSON("logSet", body: request)
                return .success
                
            case .patchWorkoutMetadata(let field, let value):
                let request = PatchMetadataRequest(
                    workoutId: workoutId,
                    field: field.rawValue,
                    value: value,
                    idempotencyKey: queued.id
                )
                let _: PatchResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
                return .success

            case .patchExerciseField(let exId, let field, let value):
                let request = PatchExerciseFieldRequest(
                    workoutId: workoutId,
                    exerciseInstanceId: exId,
                    field: field.rawValue,
                    value: value,
                    idempotencyKey: queued.id
                )
                let _: PatchResponse = try await apiClient.postJSON("patchActiveWorkout", body: request)
                return .success
            }
        } catch {
            let nsError = error as NSError
            
            // Check for TARGET_NOT_FOUND (404)
            if nsError.code == 404 || (error.localizedDescription.contains("TARGET_NOT_FOUND")) {
                return .targetNotFound
            }
            
            // Check for network errors
            if nsError.domain == NSURLErrorDomain {
                return .networkError(error)
            }
            
            return .serverError(error)
        }
    }
}

// MARK: - State Change Callback

enum MutationStateChange {
    case syncSuccess(WorkoutMutation)
    case syncFailed(WorkoutMutation, String)
    case needsReconcile
}

// MARK: - Request/Response DTOs

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
        case name, position, sets
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
}

private struct AddExerciseResponse: Decodable {
    let success: Bool
    let exerciseInstanceId: String?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case exerciseInstanceId = "exercise_instance_id"
        case error
    }
}

private struct AddSetRequest: Encodable {
    let workoutId: String
    let exerciseInstanceId: String
    let setId: String
    let setType: String
    let reps: Int
    let rir: Int
    let weight: Double?
    let idempotencyKey: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops, cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        
        // Use properly typed structs for encoding
        let op = AddSetOp(
            op: "add_set",
            target: AddSetTarget(exerciseInstanceId: exerciseInstanceId),
            value: AddSetValue(id: setId, setType: setType, status: "planned", reps: reps, rir: rir, weight: weight)
        )
        
        try container.encode([op], forKey: .ops)
        try container.encode("user_edit", forKey: .cause)
        try container.encode("add_set_button", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}

// Typed structs for add_set operation (avoids AnyCodable encoding issues)
private struct AddSetOp: Encodable {
    let op: String
    let target: AddSetTarget
    let value: AddSetValue
}

private struct AddSetTarget: Encodable {
    let exerciseInstanceId: String
    
    enum CodingKeys: String, CodingKey {
        case exerciseInstanceId = "exercise_instance_id"
    }
}

private struct AddSetValue: Encodable {
    let id: String
    let setType: String
    let status: String
    let reps: Int
    let rir: Int
    let weight: Double?
    
    enum CodingKeys: String, CodingKey {
        case id
        case setType = "set_type"
        case status
        case reps, rir, weight
    }
}

private struct PatchSetRequest: Encodable {
    let workoutId: String
    let exerciseInstanceId: String
    let setId: String
    let field: String
    let value: AnyCodableValue
    let idempotencyKey: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops, cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        
        let op = PatchOp(
            op: "set_field",
            target: PatchTarget(exerciseInstanceId: exerciseInstanceId, setId: setId),
            field: field,
            value: value
        )
        
        try container.encode([op], forKey: .ops)
        try container.encode("user_edit", forKey: .cause)
        try container.encode("cell_edit", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}

private struct PatchOp: Encodable {
    let op: String
    let target: PatchTarget
    let field: String
    let value: AnyCodableValue
}

private struct PatchTarget: Encodable {
    let exerciseInstanceId: String
    let setId: String
    
    enum CodingKeys: String, CodingKey {
        case exerciseInstanceId = "exercise_instance_id"
        case setId = "set_id"
    }
}

private struct RemoveSetRequest: Encodable {
    let workoutId: String
    let exerciseInstanceId: String
    let setId: String
    let idempotencyKey: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops, cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        
        let op: [String: Any] = [
            "op": "remove_set",
            "target": [
                "exercise_instance_id": exerciseInstanceId,
                "set_id": setId
            ]
        ]
        
        try container.encode([AnyCodable(op)], forKey: .ops)
        try container.encode("user_edit", forKey: .cause)
        try container.encode("swipe_delete", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}

private struct ReorderRequest: Encodable {
    let workoutId: String
    let order: [String]
    let idempotencyKey: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops, cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        
        let op: [String: Any] = [
            "op": "reorder_exercises",
            "value": ["order": order]
        ]
        
        try container.encode([AnyCodable(op)], forKey: .ops)
        try container.encode("user_edit", forKey: .cause)
        try container.encode("reorder_exercises", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}

private struct PatchResponse: Decodable {
    let success: Bool
    let eventId: String?
    let totals: WorkoutTotals?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case eventId = "event_id"
        case totals
        case error
    }
}

private struct LogSetMutationRequest: Encodable {
    let workoutId: String
    let exerciseInstanceId: String
    let setId: String
    let weight: Double?
    let reps: Int
    let rir: Int?
    let isFailure: Bool?
    let idempotencyKey: String
    
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case exerciseInstanceId = "exercise_instance_id"
        case setId = "set_id"
        case values
        case isFailure = "is_failure"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)
        try container.encode(exerciseInstanceId, forKey: .exerciseInstanceId)
        try container.encode(setId, forKey: .setId)
        
        var values: [String: Any] = ["reps": reps]
        if let weight = weight { values["weight"] = weight }
        if let rir = rir { values["rir"] = rir }
        try container.encode(AnyCodable(values), forKey: .values)
        
        try container.encodeIfPresent(isFailure, forKey: .isFailure)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}

private struct LogSetMutationResponse: Decodable {
    let success: Bool
    let eventId: String?
    let totals: WorkoutTotals?
    let error: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case eventId = "event_id"
        case totals
        case error
    }
}

/// Request for patching workout-level metadata (name, start_time, notes)
private struct PatchMetadataRequest: Encodable {
    let workoutId: String
    let field: String  // "name", "start_time", or "notes"
    let value: AnyCodableValue
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops, cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)

        // Build the metadata patch op - workout-level field, no target
        let op: [String: Any] = [
            "op": "set_workout_field",
            "field": field,
            "value": value.rawValue
        ]

        try container.encode([AnyCodable(op)], forKey: .ops)
        try container.encode("user_edit", forKey: .cause)
        try container.encode("header_edit", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}

/// Request for patching exercise-level metadata (notes)
private struct PatchExerciseFieldRequest: Encodable {
    let workoutId: String
    let exerciseInstanceId: String
    let field: String  // "notes"
    let value: AnyCodableValue
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case ops, cause
        case uiSource = "ui_source"
        case idempotencyKey = "idempotency_key"
        case clientTimestamp = "client_timestamp"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutId, forKey: .workoutId)

        let op: [String: Any] = [
            "op": "set_exercise_field",
            "target": ["exercise_instance_id": exerciseInstanceId],
            "field": field,
            "value": value.rawValue
        ]

        try container.encode([AnyCodable(op)], forKey: .ops)
        try container.encode("user_edit", forKey: .cause)
        try container.encode("exercise_note_edit", forKey: .uiSource)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .clientTimestamp)
    }
}
