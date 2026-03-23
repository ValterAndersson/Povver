import Foundation
import FirebaseFirestore

class ExerciseRepository: FirestoreRepository<Exercise> {
    init() {
        super.init(collection: Firestore.firestore().collection("exercises"))
    }

    /// Override list() to add error logging, manual ID injection, and status filtering.
    /// Status is filtered client-side after decoding because documents without a `status`
    /// field would be excluded by a server-side whereField query. The decoder defaults
    /// missing status to "approved", so client-side filtering handles both cases correctly.
    override func list() async throws -> [Exercise] {
        let snapshot = try await collection.getDocuments()
        AppLogger.shared.info(.store, "Fetched \(snapshot.documents.count) exercise documents from Firestore")

        var exercises: [Exercise] = []
        var errorCount = 0

        for document in snapshot.documents {
            do {
                var exercise = try document.data(as: Exercise.self)
                // Manually inject document ID since @DocumentID may not work with custom init
                if exercise.id == nil {
                    exercise.id = document.documentID
                }
                // Filter out draft/deprecated exercises (missing status defaults to "approved")
                if exercise.status == "approved" {
                    exercises.append(exercise)
                }
            } catch {
                errorCount += 1
                if errorCount <= 5 {
                    AppLogger.shared.error(.store, "Failed to decode exercise document \(document.documentID)", error)
                }
            }
        }

        if errorCount > 0 {
            AppLogger.shared.info(.store, "Total exercise decode errors: \(errorCount) / \(snapshot.documents.count)")
        }
        AppLogger.shared.info(.store, "Successfully decoded \(exercises.count) exercises")

        return exercises
    }

    /// Override read() to add manual ID injection
    override func read(id: String) async throws -> Exercise? {
        let document = try await collection.document(id).getDocument()
        guard document.exists else { return nil }

        do {
            var exercise = try document.data(as: Exercise.self)
            if exercise.id == nil {
                exercise.id = document.documentID
            }
            return exercise
        } catch {
            AppLogger.shared.error(.store, "Failed to decode exercise \(id)", error)
            throw error
        }
    }

    func getExercisesByCategory(_ category: String) async throws -> [Exercise] {
        let snapshot = try await collection
            .whereField("category", isEqualTo: category)
            .getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: Exercise.self) }
            .filter { $0.status == "approved" }
    }

    func getExercisesByMovementType(_ type: String) async throws -> [Exercise] {
        let snapshot = try await collection
            .whereField("movement.type", isEqualTo: type)
            .getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: Exercise.self) }
            .filter { $0.status == "approved" }
    }

    func getExercisesByLevel(_ level: String) async throws -> [Exercise] {
        let snapshot = try await collection
            .whereField("metadata.level", isEqualTo: level)
            .getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: Exercise.self) }
            .filter { $0.status == "approved" }
    }

    func searchExercises(query: String) async throws -> [Exercise] {
        // Simple client-side search - get all exercises and filter
        let allExercises = try await list()

        let searchTerm = query.lowercased()
        return allExercises.filter { exercise in
            let searchableText = [
                exercise.name,
                exercise.category,
                exercise.movementType,
                exercise.level,
                exercise.equipment.joined(separator: " "),
                exercise.primaryMuscles.joined(separator: " "),
                exercise.secondaryMuscles.joined(separator: " ")
            ].joined(separator: " ").lowercased()

            return searchableText.contains(searchTerm)
        }
    }

    func getExercisesByPrimaryMuscle(_ muscle: String) async throws -> [Exercise] {
        let snapshot = try await collection
            .whereField("muscles.primary", arrayContains: muscle)
            .getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: Exercise.self) }
            .filter { $0.status == "approved" }
    }

    func getExercisesBySecondaryMuscle(_ muscle: String) async throws -> [Exercise] {
        let snapshot = try await collection
            .whereField("muscles.secondary", arrayContains: muscle)
            .getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: Exercise.self) }
            .filter { $0.status == "approved" }
    }

    func getExercisesByEquipment(_ equipment: String) async throws -> [Exercise] {
        let snapshot = try await collection
            .whereField("equipment", arrayContains: equipment)
            .getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: Exercise.self) }
            .filter { $0.status == "approved" }
    }

    /// Fetch pre-computed exercise usage stats for the given user.
    /// Returns a dictionary keyed by exercise ID for O(1) lookup during sorting.
    func fetchUsageStats(userId: String) async throws -> [String: ExerciseUsageStats] {
        let snapshot = try await Firestore.firestore()
            .collection("users").document(userId)
            .collection("exercise_usage_stats")
            .getDocuments()

        var stats: [String: ExerciseUsageStats] = [:]
        for document in snapshot.documents {
            if let stat = try? document.data(as: ExerciseUsageStats.self) {
                stats[stat.exerciseId] = stat
            }
        }
        return stats
    }
}
