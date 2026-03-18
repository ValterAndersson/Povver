import Foundation

struct AgentInvokeRequest: Codable {
    let userId: String
    let conversationId: String
    let message: String
    let correlationId: String
}

enum AgentsApi {
    static func invokeAgent(_ req: AgentInvokeRequest) async throws {
        struct Empty: Decodable {}
        AppLogger.shared.info(.agent, "invokeAgent user=\(req.userId.prefix(8)) conv=\(req.conversationId.prefix(8))")
        let _: Empty = try await ApiClient.shared.postJSON("invokeCanvasOrchestrator", body: req)
    }

    /// Handle an artifact action (accept, dismiss, save_routine, start_workout, etc.)
    static func artifactAction(
        userId: String,
        conversationId: String,
        artifactId: String,
        action: String,
        day: Int? = nil
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "userId": userId,
            "conversationId": conversationId,
            "artifactId": artifactId,
            "action": action
        ]
        if let day = day {
            body["day"] = day
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "https://us-central1-myon-53d85.cloudfunctions.net/artifactAction")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        // Add Bearer auth
        if let currentUser = AuthService.shared.currentUser {
            let token = try await currentUser.getIDToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        if statusCode < 200 || statusCode >= 300 {
            let errorMessage = json["error"] as? String ?? "Artifact action failed (HTTP \(statusCode))"
            throw NSError(domain: "AgentsApi", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        return json
    }
}
