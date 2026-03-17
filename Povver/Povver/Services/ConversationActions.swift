import Foundation

struct ConversationActions {
    static func acceptProposal(canvasId: String, cardId: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "ACCEPT_PROPOSAL", card_id: cardId, payload: nil, by: "user", idempotency_key: UUID().uuidString))
    }
    static func rejectProposal(canvasId: String, cardId: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "REJECT_PROPOSAL", card_id: cardId, payload: nil, by: "user", idempotency_key: UUID().uuidString))
    }
    static func addInstruction(canvasId: String, text: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "ADD_INSTRUCTION", card_id: nil, payload: ["text": AnyCodable(text)], by: "user", idempotency_key: UUID().uuidString))
    }
    static func addNote(canvasId: String, text: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "ADD_NOTE", card_id: nil, payload: ["text": AnyCodable(text)], by: "user", idempotency_key: UUID().uuidString))
    }
    static func pause(canvasId: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "PAUSE", card_id: nil, payload: nil, by: "user", idempotency_key: UUID().uuidString))
    }
    static func resume(canvasId: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "RESUME", card_id: nil, payload: nil, by: "user", idempotency_key: UUID().uuidString))
    }
    static func complete(canvasId: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "COMPLETE", card_id: nil, payload: nil, by: "user", idempotency_key: UUID().uuidString))
    }
    static func undo(canvasId: String) -> ApplyActionRequestDTO {
        ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "UNDO", card_id: nil, payload: nil, by: "user", idempotency_key: UUID().uuidString))
    }
    static func logSet(canvasId: String, workoutId: String, exerciseId: String, setIndex: Int, reps: Int, rir: Int, weight: Double?) -> ApplyActionRequestDTO {
        let payload: [String: AnyCodable] = [
            "workout_id": AnyCodable(workoutId),
            "exercise_id": AnyCodable(exerciseId),
            "set_index": AnyCodable(setIndex),
            "actual": AnyCodable(["reps": reps, "rir": rir, "weight": weight ?? 0])
        ]
        return ApplyActionRequestDTO(canvasId: canvasId, expected_version: nil, action: CanvasActionDTO(type: "LOG_SET", card_id: nil, payload: payload, by: "user", idempotency_key: UUID().uuidString))
    }
}
