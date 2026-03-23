import Foundation
import FirebaseFunctions
// Archived path: Prefer direct HTTP via ApiClient for onRequest endpoints.
// Keeping limited callable use for legacy features only.

protocol CloudFunctionServiceProtocol {
    // Exercise operations
    func getExercises() async throws -> [Exercise]
    func getExercise(id: String) async throws -> Exercise
    
    // User operations
    func getUser(userId: String) async throws -> User
    func updateUser(userId: String, user: User) async throws
    
    // Template operations
    func getTemplates(userId: String) async throws -> [WorkoutTemplate]
    func getTemplate(id: String, userId: String) async throws -> WorkoutTemplate
    func createTemplate(template: WorkoutTemplate) async throws -> String
    func updateTemplate(id: String, template: WorkoutTemplate) async throws
    func deleteTemplate(id: String, userId: String) async throws
    
    // Workout operations
    func getWorkouts(userId: String) async throws -> [Workout]
    func getWorkout(id: String, userId: String) async throws -> Workout
    func createWorkout(workout: Workout) async throws -> String
    func updateWorkout(id: String, workout: Workout) async throws
}

class CloudFunctionService: CloudFunctionServiceProtocol {
    private let functions = Functions.functions(region: "us-central1")
    
    // MARK: - Exercise Operations
    
    func getExercises() async throws -> [Exercise] {
        let data = try await callFunction(name: "getExercises", data: [:])
        return try JSONDecoder().decode([Exercise].self, from: data)
    }
    
    func getExercise(id: String) async throws -> Exercise {
        let data = try await callFunction(name: "getExercise", data: ["id": id])
        return try JSONDecoder().decode(Exercise.self, from: data)
    }
    
    // MARK: - User Operations
    
    func getUser(userId: String) async throws -> User {
        let data = try await callFunction(name: "getUser", data: ["userId": userId])
        return try JSONDecoder().decode(User.self, from: data)
    }
    
    func updateUser(userId: String, user: User) async throws {
        let data = try JSONEncoder().encode(user)
        let params = ["userId": userId, "user": String(data: data, encoding: .utf8) ?? ""]
        _ = try await callFunction(name: "updateUser", data: params)
    }
    
    // MARK: - Template Operations
    
    func getTemplates(userId: String) async throws -> [WorkoutTemplate] {
        let data = try await callFunction(name: "getUserTemplates", data: ["userId": userId])
        return try JSONDecoder().decode([WorkoutTemplate].self, from: data)
    }
    
    func getTemplate(id: String, userId: String) async throws -> WorkoutTemplate {
        let data = try await callFunction(name: "getTemplate", data: ["id": id, "userId": userId])
        return try JSONDecoder().decode(WorkoutTemplate.self, from: data)
    }
    
    func createTemplate(template: WorkoutTemplate) async throws -> String {
        let data = try JSONEncoder().encode(template)
        let params = ["template": String(data: data, encoding: .utf8) ?? ""]
        let result = try await callFunction(name: "createTemplate", data: params)
        return try JSONDecoder().decode(String.self, from: result)
    }
    
    func updateTemplate(id: String, template: WorkoutTemplate) async throws {
        let data = try JSONEncoder().encode(template)
        let params = ["id": id, "template": String(data: data, encoding: .utf8) ?? ""]
        _ = try await callFunction(name: "updateTemplate", data: params)
    }
    
    func deleteTemplate(id: String, userId: String) async throws {
        let params = ["id": id, "userId": userId]
        _ = try await callFunction(name: "deleteTemplate", data: params)
    }
    
    // MARK: - Workout Operations
    
    func getWorkouts(userId: String) async throws -> [Workout] {
        let data = try await callFunction(name: "getUserWorkouts", data: ["userId": userId])
        return try JSONDecoder().decode([Workout].self, from: data)
    }
    
    func getWorkout(id: String, userId: String) async throws -> Workout {
        let data = try await callFunction(name: "getWorkout", data: ["id": id, "userId": userId])
        return try JSONDecoder().decode(Workout.self, from: data)
    }
    
    func createWorkout(workout: Workout) async throws -> String {
        let data = try JSONEncoder().encode(workout)
        let params = ["workout": String(data: data, encoding: .utf8) ?? ""]
        let result = try await callFunction(name: "createWorkout", data: params)
        return try JSONDecoder().decode(String.self, from: result)
    }
    
    func updateWorkout(id: String, workout: Workout) async throws {
        let data = try JSONEncoder().encode(workout)
        let params = ["id": id, "workout": String(data: data, encoding: .utf8) ?? ""]
        _ = try await callFunction(name: "updateWorkout", data: params)
    }
    
    // MARK: - Private Helpers
    
    private func callFunction(name: String, data: [String: Any]) async throws -> Data {
        let startTime = Date()

        // Log the callable request
        let rid = AppLogger.shared.httpReq(method: "CALLABLE", endpoint: name, body: data)

        do {
            let result = try await functions.httpsCallable(name).call(data)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let jsonData = try? JSONSerialization.data(withJSONObject: result.data) else {
                AppLogger.shared.error(.http, "failed to serialize callable result")
                throw NSError(domain: "CloudFunctionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize function result"])
            }

            // Log the response
            let responseBody: Any
            if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) {
                responseBody = jsonObject
            } else {
                responseBody = String(data: jsonData, encoding: .utf8) ?? "<binary>"
            }

            AppLogger.shared.httpRes(rid: rid, status: 200, ms: durationMs, endpoint: name, body: responseBody)

            return jsonData
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            AppLogger.shared.httpRes(rid: rid, status: -1, ms: durationMs, endpoint: name, error: error)
            throw error
        }
    }
}
