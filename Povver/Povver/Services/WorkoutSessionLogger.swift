import Foundation
import UIKit

/// Records every event during a workout session to a JSON file on disk.
/// Always active in both debug and release builds. After each gym session,
/// the log can be reviewed or shared to diagnose issues.
///
/// Usage:
///   WorkoutSessionLogger.shared.begin(workoutId: "...", name: "Push Day")
///   WorkoutSessionLogger.shared.log(.setLogged, details: ["weight": 80, ...])
///   WorkoutSessionLogger.shared.end(outcome: .completed)
///
/// Files are stored at:
///   <Caches>/workout_logs/<workoutId>_<date>.json
final class WorkoutSessionLogger {
    static let shared = WorkoutSessionLogger()

    // MARK: - Types

    enum EventType: String, Codable {
        // Lifecycle
        case workoutStarted = "workout_started"
        case workoutResumed = "workout_resumed"
        case workoutCompleted = "workout_completed"
        case workoutCancelled = "workout_cancelled"

        // Exercises
        case exerciseAdded = "exercise_added"
        case exerciseRemoved = "exercise_removed"
        case exerciseSwapped = "exercise_swapped"
        case exercisesReordered = "exercises_reordered"

        // Sets
        case setLogged = "set_logged"
        case setAdded = "set_added"
        case setRemoved = "set_removed"
        case fieldPatched = "field_patched"

        // Metadata
        case nameChanged = "name_changed"
        case startTimeChanged = "start_time_changed"

        // Sync
        case syncSuccess = "sync_success"
        case syncFailed = "sync_failed"
        case reconciliation = "reconciliation"

        // Errors
        case error = "error"

        // Network
        case apiCall = "api_call"
        case apiResponse = "api_response"

        // User / UI
        case appBackgrounded = "app_backgrounded"
        case appForegrounded = "app_foregrounded"
        case note = "note"
    }

    struct LogEntry: Codable {
        let timestamp: String
        let elapsedMs: Int
        let type: EventType
        let details: [String: AnyCodableValue]?
    }

    /// Wraps primitive JSON values for Codable serialization.
    enum AnyCodableValue: Codable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        init(_ value: Any) {
            switch value {
            case let s as String: self = .string(s)
            case let i as Int: self = .int(i)
            case let d as Double: self = .double(d)
            case let b as Bool: self = .bool(b)
            default: self = .string(String(describing: value))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
            case .null: try container.encodeNil()
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(String.self) { self = .string(v); return }
            if let v = try? container.decode(Int.self) { self = .int(v); return }
            if let v = try? container.decode(Double.self) { self = .double(v); return }
            if let v = try? container.decode(Bool.self) { self = .bool(v); return }
            self = .null
        }
    }

    // MARK: - State

    private var entries: [LogEntry] = []
    private var sessionStartTime: Date?
    private var currentWorkoutId: String?
    private var currentWorkoutName: String?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let queue = DispatchQueue(label: "com.povver.workout-session-logger")
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        setupLifecycleObservers()
    }

    // MARK: - Session Lifecycle

    /// Start logging a workout session. Call when workout begins or resumes.
    func begin(workoutId: String, name: String?, resumed: Bool = false) {
        queue.sync {
            self.entries = []
            self.sessionStartTime = Date()
            self.currentWorkoutId = workoutId
            self.currentWorkoutName = name
        }

        let device = UIDevice.current
        log(resumed ? .workoutResumed : .workoutStarted, details: [
            "workout_id": workoutId,
            "name": name ?? "(unnamed)",
            "device": "\(device.model) \(device.systemName) \(device.systemVersion)",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        ])
    }

    /// End the session and flush the log to disk.
    func end(outcome: EventType) {
        log(outcome)
        flush()
        queue.sync {
            self.currentWorkoutId = nil
            self.currentWorkoutName = nil
            self.sessionStartTime = nil
        }
    }

    // MARK: - Event Logging

    /// Record an event. Thread-safe; can be called from any queue.
    func log(_ type: EventType, details: [String: Any]? = nil) {
        let now = Date()
        let timestamp = isoFormatter.string(from: now)
        let elapsed: Int
        if let start = sessionStartTime {
            elapsed = Int(now.timeIntervalSince(start) * 1000)
        } else {
            elapsed = 0
        }

        let codableDetails = details?.mapValues { AnyCodableValue($0) }
        let entry = LogEntry(timestamp: timestamp, elapsedMs: elapsed, type: type, details: codableDetails)

        queue.sync {
            entries.append(entry)
        }

        // Also breadcrumb to Crashlytics for correlation
        let summary = type.rawValue
        FirebaseConfig.shared.log(summary)
    }

    // MARK: - Persistence

    /// Write current entries to disk. Called automatically on session end,
    /// app backgrounding, and periodically.
    func flush() {
        var snapshot: [LogEntry] = []
        var workoutId: String?
        queue.sync {
            snapshot = self.entries
            workoutId = self.currentWorkoutId
        }
        guard !snapshot.isEmpty, let wid = workoutId else { return }

        let dir = logDirectory()
        let dateStr = formattedDateForFilename()
        let filename = "\(wid)_\(dateStr).json"
        let fileURL = dir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            try? (fileURL as NSURL).setResourceValue(
                URLFileProtection.complete,
                forKey: .fileProtectionKey
            )
        } catch {
            AppLogger.shared.error(.work, "Failed to write workout session log", error)
        }
    }

    /// List all stored workout log files, newest first.
    func listLogs() -> [URL] {
        let dir = logDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Read and return the contents of a specific log file.
    func readLog(at url: URL) -> [LogEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LogEntry].self, from: data)
    }

    /// Delete logs older than the specified number of days (default 30).
    func pruneOldLogs(olderThanDays days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        for url in listLogs() {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private Helpers

    private func logDirectory() -> URL {
        // Use Caches — not included in iCloud/iTunes backups, appropriate for
        // diagnostic workout logs containing health-adjacent data (weights, reps).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("workout_logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: dir.path
            )
        }
        return dir
    }

    private func formattedDateForFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return df.string(from: sessionStartTime ?? Date())
    }

    private func setupLifecycleObservers() {
        let bg = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.log(.appBackgrounded)
            DispatchQueue.global(qos: .utility).async {
                self?.flush()
            }
        }

        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.log(.appForegrounded)
        }

        lifecycleObservers = [bg, fg]
    }
}
