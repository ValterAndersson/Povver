import Foundation

actor IdempotencyKeyStore {
    private var recent: [String: Date] = [:]
    private let ttl: TimeInterval
    init(ttl: TimeInterval = 60) { self.ttl = ttl }
    func newKey(prefix: String = "act") -> String { "\(prefix)-\(UUID().uuidString)" }
    func remember(_ key: String) { recent[key] = Date() }
    func seen(_ key: String) -> Bool {
        cleanup(); return recent[key] != nil
    }
    private func cleanup() {
        let now = Date(); recent = recent.filter { now.timeIntervalSince($0.value) < ttl }
    }
}

// Diagnostic-only logging — no-ops in Release via AppLogger (acceptable since
// idempotency issues surface as user-visible duplicates, not silent failures).
struct Log {
    static func info(_ message: String) { AppLogger.shared.info(.work, message) }
    static func error(_ message: String) { AppLogger.shared.error(.work, message) }
}


