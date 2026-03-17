import Foundation
import Combine

// ChatService is dead code — sessions were eliminated in Phase 3c.
// Kept as a stub to avoid dangling references. Safe to delete.

class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published var isLoading = false
    @Published var error: Error?

    private init() {}
}
