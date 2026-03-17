import Foundation
import SwiftUI

// SessionPreWarmer is dead code — sessions were eliminated in Phase 3c.
// All call sites have been removed. This file should be deleted.
// Kept as a stub to avoid Xcode project file desync.

@MainActor
final class SessionPreWarmer: ObservableObject {
    static let shared = SessionPreWarmer()
    private init() {}
}
