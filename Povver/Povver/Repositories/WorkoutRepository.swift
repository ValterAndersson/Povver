import Foundation
import FirebaseFirestore
import OSLog

class WorkoutRepository {
    private let db = Firestore.firestore()
    private let logger = Logger(subsystem: "com.povver.app", category: "WorkoutRepository")
    
    func getWorkouts(userId: String) async throws -> [Workout] {
        do {
            let snapshot = try await db.collection("users").document(userId).collection("workouts").getDocuments()
            return snapshot.documents.compactMap { doc in
                guard var workout = try? doc.data(as: Workout.self) else { return nil }
                workout.id = doc.documentID
                return workout
            }
        } catch {
            AppLogger.shared.error(.store, "Error fetching workouts", error)
            throw error
        }
    }
    
    /// Count workouts without fetching full documents. Uses Firestore count aggregation.
    func getWorkoutCount(userId: String) async throws -> Int {
        let query = db.collection("users").document(userId).collection("workouts")
        let snapshot = try await query.count.getAggregation(source: .server)
        return Int(truncating: snapshot.count)
    }

    func getWorkout(id: String, userId: String) async throws -> Workout? {
        do {
            let doc = try await db.collection("users").document(userId).collection("workouts").document(id).getDocument()
            guard doc.exists else { return nil }
            var workout = try doc.data(as: Workout.self)
            workout.id = doc.documentID
            return workout
        } catch {
            AppLogger.shared.error(.store, "Error fetching workout", error)
            throw error
        }
    }
    
    func createWorkout(userId: String, workout: Workout) async throws -> String {
        return try await retry(times: 3, delay: 0.5) { [self] in
            let ref = try self.db.collection("users").document(userId).collection("workouts").addDocument(from: workout)
            logger.debug("Workout created for user: \(userId)")
            return ref.documentID
        }
    }
    
    func updateWorkout(userId: String, id: String, workout: Workout) async throws {
        try await retry(times: 3, delay: 0.5) { [self] in
            try self.db.collection("users").document(userId).collection("workouts").document(id).setData(from: workout, merge: true)
            logger.debug("Workout updated for user: \(userId)")
        }
    }

    func deleteWorkout(userId: String, id: String) async throws {
        try await db.collection("users").document(userId).collection("workouts").document(id).delete()
        logger.debug("Workout deleted: \(id) for user: \(userId)")
    }

    /// Atomic single-field update for workout-level notes.
    /// Empty/nil deletes the field via FieldValue.delete().
    func patchWorkoutNotes(userId: String, workoutId: String, notes: String?) async throws {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = (trimmed == nil || trimmed!.isEmpty) ? FieldValue.delete() : trimmed!
        try await db.collection("users").document(userId).collection("workouts").document(workoutId)
            .updateData(["notes": value])
        logger.debug("Workout notes patched: \(workoutId) for user: \(userId)")
    }

    /// Read-modify-write for exercise-level notes (Firestore doesn't support array index updates).
    /// Race condition risk is negligible — single user editing their own historical data.
    func patchExerciseNotes(userId: String, workoutId: String, exerciseIndex: Int, notes: String?) async throws {
        let docRef = db.collection("users").document(userId).collection("workouts").document(workoutId)
        let snapshot = try await docRef.getDocument()
        guard let data = snapshot.data(),
              var exercises = data["exercises"] as? [[String: Any]],
              exerciseIndex >= 0, exerciseIndex < exercises.count else {
            throw NSError(domain: "WorkoutRepository", code: 404, userInfo: [NSLocalizedDescriptionKey: "Exercise not found at index \(exerciseIndex)"])
        }

        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, !trimmed.isEmpty {
            exercises[exerciseIndex]["notes"] = trimmed
        } else {
            exercises[exerciseIndex].removeValue(forKey: "notes")
        }

        try await docRef.updateData(["exercises": exercises])
        logger.debug("Exercise[\(exerciseIndex)] notes patched: \(workoutId) for user: \(userId)")
    }
}
