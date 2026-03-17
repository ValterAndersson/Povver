import Foundation

// =============================================================================
// MARK: - ConversationService.swift
// =============================================================================
//
// PURPOSE:
// Client for conversation-related Firebase Functions. Primary interface
// between the iOS app and the backend for artifact action mutations.
//
// KEY FIREBASE FUNCTION ENDPOINTS CALLED:
// - applyAction -> firebase_functions/functions/canvas/apply-action.js
//   The single-writer reducer for all card/artifact mutations
// - purgeCanvas -> firebase_functions/functions/canvas/bootstrap-canvas.js
//   Clears conversation workspace entries
//
// RELATED IOS FILES:
// - ConversationViewModel.swift: Uses this service for artifact actions
// - ConversationDTOs.swift: Request/response DTOs used by this service
// - ApiClient.swift: Underlying HTTP client with auth
// - ConversationRepository.swift: Firestore subscriptions
//
// =============================================================================

// MARK: - Protocol

protocol ConversationServiceProtocol {
    /// Apply a conversation action via the single-writer reducer
    func applyAction(_ req: ApplyActionRequestDTO) async throws -> ApplyActionResponseDTO

    /// Clear conversation messages/events
    func purgeConversation(userId: String, conversationId: String, dropEvents: Bool, dropState: Bool, dropWorkspace: Bool) async throws
}

extension ConversationServiceProtocol {
    func purgeConversation(userId: String, conversationId: String) async throws {
        try await purgeConversation(userId: userId, conversationId: conversationId, dropEvents: false, dropState: false, dropWorkspace: true)
    }
}

// MARK: - Implementation

final class ConversationService: ConversationServiceProtocol {

    // =========================================================================
    // MARK: applyAction
    // =========================================================================
    func applyAction(_ req: ApplyActionRequestDTO) async throws -> ApplyActionResponseDTO {
        let actionDesc = "action:\(req.action.type) card=\(req.action.card_id ?? "nil") v=\(req.expected_version ?? -1)"
        AppLogger.shared.info(.app, actionDesc)

        let res: ApplyActionResponseDTO = try await ApiClient.shared.postJSON("applyAction", body: req)

        if res.success == true, let data = res.data {
            AppLogger.shared.info(.app, "applyAction succeeded v=\(data.version ?? -1) cards=\(data.changed_cards?.count ?? 0)")
        } else if let err = res.error {
            AppLogger.shared.error(.app, "applyAction failed: \(err.code)")
        }

        return res
    }

    // =========================================================================
    // MARK: purgeConversation
    // =========================================================================
    func purgeConversation(userId: String, conversationId: String, dropEvents: Bool = false, dropState: Bool = false, dropWorkspace: Bool = true) async throws {
        struct Req: Codable {
            let userId: String
            let canvasId: String
            let dropEvents: Bool
            let dropState: Bool
            let dropWorkspace: Bool
        }
        struct Envelope: Codable { let success: Bool; let error: ActionErrorDTO? }

        let req = Req(userId: userId, canvasId: conversationId, dropEvents: dropEvents, dropState: dropState, dropWorkspace: dropWorkspace)
        AppLogger.shared.info(.app, "purgeConversation id=\(conversationId.prefix(8)) dropWorkspace=\(dropWorkspace)")
        let env: Envelope = try await ApiClient.shared.postJSON("purgeCanvas", body: req)

        if env.success {
            AppLogger.shared.info(.app, "purgeConversation success")
        } else if let err = env.error {
            AppLogger.shared.error(.app, "purgeConversation error: \(err.code)")
        }
        guard env.success else {
            let message = env.error?.message ?? "Failed to purge conversation"
            throw NSError(domain: "ConversationService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
