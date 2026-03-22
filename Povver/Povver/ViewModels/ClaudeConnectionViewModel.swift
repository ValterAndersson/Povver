import Foundation

enum ClaudeConnectionState {
    case loading
    case notConnected
    case connected(lastUsedAt: Date?)
    case disabled // not premium
}

@MainActor
final class ClaudeConnectionViewModel: ObservableObject {
    @Published var state: ClaudeConnectionState = .loading
    @Published var errorMessage: String?
    @Published var isDisconnecting = false

    private let subscriptionService = SubscriptionService.shared

    func checkStatus() async {
        guard subscriptionService.isPremium else {
            state = .disabled
            return
        }

        do {
            let response: McpConnectionStatusResponse = try await ApiClient.shared.postJSON(
                "getMcpConnectionStatus",
                body: EmptyBody()
            )
            if response.data.connected {
                let lastUsed = response.data.lastUsedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                state = .connected(lastUsedAt: lastUsed)
            } else {
                state = .notConnected
            }
        } catch {
            state = .notConnected
        }
    }

    func disconnect() async {
        isDisconnecting = true
        defer { isDisconnecting = false }

        do {
            let _: McpRevokeResponse = try await ApiClient.shared.postJSON(
                "revokeMcpTokens",
                body: EmptyBody()
            )
            state = .notConnected
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Request / Response types

private struct EmptyBody: Encodable {}

private struct McpConnectionStatusData: Decodable {
    let connected: Bool
    let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case connected
        case lastUsedAt = "last_used_at"
    }
}

private struct McpConnectionStatusResponse: Decodable {
    let success: Bool
    let data: McpConnectionStatusData
}

private struct McpRevokeData: Decodable {
    let revoked: Bool
}

private struct McpRevokeResponse: Decodable {
    let success: Bool
    let data: McpRevokeData
}
