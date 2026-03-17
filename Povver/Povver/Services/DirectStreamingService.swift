import Foundation
import Combine

// =============================================================================
// MARK: - DirectStreamingService.swift
// =============================================================================
//
// PURPOSE:
// SSE (Server-Sent Events) streaming client for real-time agent communication.
// Streams messages to the Agent Engine and receives streaming responses with
// tool calls, thinking steps, and text output.
//
// ARCHITECTURE CONTEXT:
// ┌─────────────────┐       ┌─────────────────────────────┐       ┌────────────────────┐
// │ iOS App         │       │ Firebase Functions          │       │ Agent Engine       │
// │                 │       │                             │       │ (Vertex AI)        │
// │ DirectStreaming │──SSE─►│ streamAgentNormalized       │──────►│ CanvasOrchestrator │
// │ Service         │◄─────│ (stream-agent-normalized.js)│◄──────│ (orchestrator.py)  │
// └─────────────────┘       └─────────────────────────────┘       └────────────────────┘
//
// KEY ENDPOINTS CALLED:
// - streamAgentNormalized → firebase_functions/functions/strengthos/stream-agent-normalized.js
//   SSE endpoint that normalizes Agent Engine events into structured stream
//
// STREAM EVENT FLOW:
// 1. User sends message → ConversationViewModel.sendMessage()
// 2. ConversationViewModel calls DirectStreamingService.streamQuery()
// 3. DirectStreamingService POSTs to streamAgentNormalized with SSE Accept header
// 4. Firebase Function proxies to Agent Engine and normalizes events
// 5. Agent Engine emits _pipeline events (router, planner, critic) for CoT visibility
// 6. Agent calls tools which emit _display metadata (see response_helpers.py)
// 7. Firebase extracts _pipeline/_display and emits structured SSE events
// 8. DirectStreamingService parses SSE → StreamEvent objects
// 9. ConversationViewModel.handleIncomingStreamEvent() forwards to ThinkingProcessState
// 10. ThinkingBubble renders Gemini-style collapsible thought process
//
// EVENT TYPES RECEIVED:
// - pipeline: CoT visibility (router, planner, critic steps)
// - thinking: Agent is reasoning
// - thought: Thought completion
// - toolRunning: Agent is calling a tool (with name)
// - toolComplete: Tool completed (with result)
// - text_delta: Partial text chunk from agent
// - text_commit: Final committed text
// - agentResponse: Complete agent response
// - error: Error from agent
// - done: Stream complete
//
// RELATED IOS FILES:
// - ChatService.swift: Manages chat sessions, uses this for streaming
// - ConversationViewModel.swift: Uses streamQuery, forwards events to ThinkingProcessState
// - ThinkingProcessState.swift: Groups events into phases (Planning → Gathering → Building)
// - ThinkingBubble.swift: Gemini-style collapsible thought process UI
// - StreamEvent.swift (Models): Event data model (9-event contract)
// - WorkspaceTimelineView.swift: Timeline with ThinkingBubble at top
//
// RELATED AGENT FILES:
// - adk_agent/canvas_orchestrator/app/agents/orchestrator.py: Routes to agents
// - adk_agent/canvas_orchestrator/app/libs/tools_common/response_helpers.py: _display
//
// =============================================================================

/// Service for direct streaming communication with the Agent Engine API
class DirectStreamingService: ObservableObject {
    static let shared = DirectStreamingService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30       // 30s to establish connection
        config.timeoutIntervalForResource = 300     // 5min max for SSE streams
        config.waitsForConnectivity = true           // Wait for network instead of failing immediately
        return URLSession(configuration: config)
    }()
    
    // MARK: - Public Methods

    /// Query the agent with streaming response (AsyncSequence)
    func streamQuery(
        userId: String,
        conversationId: String,
        message: String,
        correlationId: String,
        workoutId: String? = nil,
        timeoutSeconds: Int = 300
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let streamStartTime = Date()
                var eventCount = 0

                do {
                    // Start pipeline logging (new focused logger)
                    AgentPipelineLogger.startRequest(
                        correlationId: correlationId,
                        canvasId: conversationId,
                        sessionId: nil,
                        message: message
                    )

                    // Get Firebase ID token
                    guard let currentUser = AuthService.shared.currentUser else {
                        AgentPipelineLogger.failRequest(error: "Not authenticated", afterMs: 0)
                        continuation.finish(throwing: StreamingError.notAuthenticated)
                        return
                    }

                    // Premium gate: client-side check using cached subscription state.
                    // Server-side gate in stream-agent-normalized.js provides the authoritative check.
                    if await !SubscriptionService.shared.isPremium {
                        AgentPipelineLogger.failRequest(error: "Premium required", afterMs: 0)
                        continuation.finish(throwing: StreamingError.premiumRequired)
                        return
                    }

                    let idToken = try await currentUser.getIDToken()

                    // Use streamAgentNormalized endpoint
                    let url = URL(string: "https://us-central1-myon-53d85.cloudfunctions.net/streamAgentNormalized")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let body: [String: Any] = [
                        "userId": userId,
                        "conversationId": conversationId,
                        "message": message,
                        "correlationId": correlationId,
                        "workoutId": workoutId as Any
                    ].compactMapValues { $0 }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Stream the response
                    let (asyncBytes, response) = try await session.bytes(for: request)

                    // Launch timeout task to cancel stream after timeout period
                    let timeoutTask = Task {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                        session.invalidateAndCancel()
                    }
                    defer { timeoutTask.cancel() }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(domain: "DirectStreamingService", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
                    }
                    
                    if httpResponse.statusCode != 200 {
                        AgentPipelineLogger.shared.pipelineStep(.error, "HTTP \(httpResponse.statusCode)")
                        throw NSError(domain: "DirectStreamingService", code: httpResponse.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
                    }
                    
                    // Parse SSE stream
                    for try await line in asyncBytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            
                            if jsonStr == "[DONE]" {
                                let durationMs = Int(Date().timeIntervalSince(streamStartTime) * 1000)
                                AgentPipelineLogger.endRequest(totalMs: durationMs, toolCount: nil)
                                continuation.finish()
                                break
                            }
                            
                            if let data = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                
                                // Parse content with proper AnyCodable handling
                                // For error events, the server sends { "error": { "code": ..., "message": ... } }
                                // instead of "content", so map "error" into content for uniform downstream handling.
                                var contentDict: [String: AnyCodable]? = nil
                                if let rawContent = json["content"] as? [String: Any] {
                                    contentDict = rawContent.mapValues { AnyCodable($0) }
                                } else if let rawError = json["error"] as? [String: Any] {
                                    contentDict = rawError.mapValues { AnyCodable($0) }
                                }
                                
                                var metadataDict: [String: AnyCodable]? = nil
                                if let rawMeta = json["metadata"] as? [String: Any] {
                                    metadataDict = rawMeta.mapValues { AnyCodable($0) }
                                }
                                
                                // Parse the event
                                let event = StreamEvent(
                                    type: json["type"] as? String ?? "unknown",
                                    agent: json["agent"] as? String,
                                    content: contentDict,
                                    timestamp: json["timestamp"] as? Double,
                                    metadata: metadataDict
                                )
                                
                                eventCount += 1
                                
                                // Log with new focused pipeline logger
                                var contentForLog: [String: Any] = [:]
                                if let rawContent = json["content"] as? [String: Any] {
                                    contentForLog = rawContent
                                }
                                var metaForLog: [String: Any] = [:]
                                if let rawMeta = json["metadata"] as? [String: Any] {
                                    metaForLog = rawMeta
                                }
                                AgentPipelineLogger.event(
                                    type: event.type,
                                    content: contentForLog.isEmpty ? nil : contentForLog,
                                    agent: event.agent,
                                    metadata: metaForLog.isEmpty ? nil : metaForLog
                                )
                                
                                continuation.yield(event)
                            }
                        }
                    }
                    
                    let durationMs = Int(Date().timeIntervalSince(streamStartTime) * 1000)
                    AgentPipelineLogger.endRequest(totalMs: durationMs, toolCount: nil)
                    continuation.finish()
                    
                } catch {
                    let durationMs = Int(Date().timeIntervalSince(streamStartTime) * 1000)
                    AgentPipelineLogger.failRequest(error: error.localizedDescription, afterMs: durationMs)
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    /// Split incoming text into a commit-safe prefix and a kept suffix.
    /// Ensures we do not flush half list markers or half code fences, and normalizes bullets.
    private static func segmentAndSanitizeMarkdown(_ incoming: String, allowPartial: Bool = false) -> (commit: String, keep: String) {
        if incoming.isEmpty { return ("", "") }

        // Normalize unwanted bullets, headings, and stray characters early
        var text = incoming
            .replacingOccurrences(of: "\u{2022}", with: "-") // •
            .replacingOccurrences(of: "\u{2023}", with: "-") // ‣
            .replacingOccurrences(of: "\t* ", with: "- ")
            .replacingOccurrences(of: "\r", with: "")

        // Drop markdown headings to avoid giant section titles mid-stream
        let noHeadings = text
            .components(separatedBy: "\n")
            .filter { ln in
                let t = ln.trimmingCharacters(in: .whitespaces)
                return !(t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### "))
            }
            .joined(separator: "\n")
        text = noHeadings

        // If we allow partial at stream end, just return normalized content
        if allowPartial { return (text, "") }

        // Heuristics: commit up to the last safe boundary
        // Safe boundaries: paragraph break, end of sentence, start of new list item
        let delimiters = ["\n\n", ". ", "! ", "? ", "\n- ", "\n* ", "\n1. "]
        var cutIndex: String.Index? = nil

        for delim in delimiters {
            if let range = text.range(of: delim, options: [.backwards]) {
                cutIndex = range.upperBound
                break
            }
        }

        // Avoid flushing when inside an open code fence (odd number of ```)
        let fenceCount = text.components(separatedBy: "```").count - 1
        let isFenceOpen = fenceCount % 2 == 1

        if let idx = cutIndex {
            let commit = String(text[..<idx])
            if isFenceOpen {
                // Keep everything if fence is open
                return ("", text)
            }
            let keep = String(text[idx...])
            return (commit, keep)
        }

        // If nothing safe found, be conservative: don't flush yet
        return ("", text)
    }

    // Fingerprint small chunks to drop exact duplicates without CryptoKit
    private static func fingerprint(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let sample = String(trimmed.suffix(128)).lowercased()
        var hash: UInt64 = 5381
        for u in sample.unicodeScalars { hash = ((hash << 5) &+ hash) &+ UInt64(u.value) }
        return String(hash)
    }

    // Drop additions that already appear at the end of the base text
    private static func dedupeTrailing(base: String, addition: String, lastTail: String, minLen: Int = 6) -> String {
        let add = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if add.isEmpty { return "" }
        let tail = lastTail.isEmpty ? String(base.suffix(200)) : lastTail
        if !tail.isEmpty && (tail.hasSuffix(add) || tail.contains(add)) { return "" }
        // Also avoid re-adding if base already contains the addition near the end
        let window = String(base.suffix(800))
        if window.contains(add) && add.count >= minLen { return "" }
        return addition
    }

    // If base ends with a letter/number and addition starts with a letter (no leading space), insert a space
    private static func ensureJoinSpacing(base: String, addition: String) -> String {
        guard let last = base.unicodeScalars.last else { return addition }
        guard let first = addition.unicodeScalars.first else { return addition }
        let ws = CharacterSet.whitespacesAndNewlines
        let letters = CharacterSet.letters
        if !ws.contains(last) && letters.contains(first) {
            return " " + addition
        }
        return addition
    }

    // Remove filler phrases at the start of paragraphs
    private static func cleanLeadingFiller(_ text: String) -> String {
        let fillers = ["Okay, ", "Of course, ", "Sure, ", "Got it, ", "Alright, "]
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var ln = line
            for f in fillers {
                if ln.hasPrefix(f) { ln = String(ln.dropFirst(f.count)) }
            }
            return ln
        }
        // Collapse double spaces created by removals
        return lines.joined(separator: "\n").replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - Private Methods

    private func parseStreamingEvent(_ line: String) -> [String: Any]? {
        // Remove "data: " prefix if present
        let jsonString = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
        
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        return json
    }
    
    /// Format function arguments for display
    private func formatFunctionArgs(_ args: [String: Any]?) -> String {
        guard let args = args, !args.isEmpty else { return "" }
        
        // Extract key arguments for display
        var displayParts: [String] = []
        
        // Common argument patterns - avoid showing user_id
        if let startDate = args["start_date"] as? String {
            displayParts.append("from \(formatDate(startDate))")
        }
        if let endDate = args["end_date"] as? String {
            displayParts.append("to \(formatDate(endDate))")
        }
        if let limit = args["limit"] {
            displayParts.append("limit: \(limit)")
        }
        if let muscleGroups = args["muscle_groups"] as? String {
            displayParts.append("for \(muscleGroups)")
        }
        if let equipment = args["equipment"] as? String {
            displayParts.append("using \(equipment)")
        }
        if let query = args["query"] as? String {
            displayParts.append("\"\(query)\"")
        }
        if args["template_id"] != nil {
            displayParts.append("template")
        }
        if args["workout_id"] != nil {
            displayParts.append("workout")
        }
        if args["routine_id"] != nil {
            displayParts.append("routine")
        }
        
        // If we have display parts, format them nicely
        if !displayParts.isEmpty {
            return " \(displayParts.joined(separator: ", "))"
        }
        
        // Otherwise, return empty string (no args display)
        return ""
    }
    
    /// Format ISO date string for display
    private func formatDate(_ isoString: String) -> String {
        // Parse ISO date string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: isoString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .short
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        
        // Fallback: try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .short
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        
        // If parsing fails, return a shortened version
        return String(isoString.prefix(10))
    }
    
    private func getHumanReadableFunctionName(_ name: String) -> String {
        switch name {
        // User management
        case "get_user": return "Loading user profile"
        case "get_user_preferences": return "Loading preferences"
        case "update_user": return "Updating user profile"
        case "update_user_preferences": return "Updating preferences"
        case "get_my_user_id": return "Checking user session"
        
        // Exercise database
        case "list_exercises": return "Browsing exercises"
        case "search_exercises": return "Searching exercises"
        case "get_exercise": return "Getting exercise details"
        
        // Workout tracking
        case "get_user_workouts": return "Loading workout history"
        case "get_workout": return "Getting workout details"
        
        // Template management
        case "get_user_templates": return "Fetching templates"
        case "get_template": return "Loading template"
        case "create_template": return "Creating new template"
        case "update_template": return "Updating template"
        case "delete_template": return "Deleting template"
        
        // Routine management
        case "get_user_routines": return "Loading routines"
        case "get_active_routine": return "Checking active routine"
        case "get_routine": return "Loading routine details"
        case "create_routine": return "Creating routine"
        case "update_routine": return "Updating routine"
        case "delete_routine": return "Deleting routine"
        case "set_active_routine": return "Activating routine"
        
        // Exercise admin
        case "upsert_exercise": return "Saving exercise"
        case "approve_exercise": return "Approving exercise"

        // Active workout
        case "propose_session": return "Proposing session"
        case "start_active_workout": return "Starting workout"
        case "get_active_workout": return "Loading active workout"
        case "prescribe_set": return "Prescribing set"
        case "log_set": return "Logging set"
        case "score_set": return "Scoring set"
        case "add_exercise": return "Adding exercise"
        case "swap_exercise": return "Swapping exercise"
        case "complete_active_workout": return "Completing workout"
        case "cancel_active_workout": return "Cancelling workout"
        case "note_active_workout": return "Adding note"

        // Memory management
        case "store_important_fact": return "Saving important information"
        case "get_important_facts": return "Recalling saved information"
        
        default: return "Processing"
        }
    }
    
    private func getHumanReadableFunctionResponseName(_ name: String) -> String {
        switch name {
        // User management
        case "get_user": return "User profile loaded"
        case "get_user_preferences": return "Preferences loaded"
        case "update_user": return "Profile updated"
        case "update_user_preferences": return "Preferences updated"
        case "get_my_user_id": return "Session verified"
        
        // Exercise database
        case "list_exercises": return "Exercises loaded"
        case "search_exercises": return "Search complete"
        case "get_exercise": return "Exercise details loaded"
        
        // Workout tracking
        case "get_user_workouts": return "Workout history loaded"
        case "get_workout": return "Workout details loaded"
        
        // Template management
        case "get_user_templates": return "Templates loaded"
        case "get_template": return "Template loaded"
        case "create_template": return "Template created"
        case "update_template": return "Template updated"
        case "delete_template": return "Template deleted"
        
        // Routine management
        case "get_user_routines": return "Routines loaded"
        case "get_active_routine": return "Active routine found"
        case "get_routine": return "Routine loaded"
        case "create_routine": return "Routine created"
        case "update_routine": return "Routine updated"
        case "delete_routine": return "Routine deleted"
        case "set_active_routine": return "Routine activated"
        
        // Exercise admin
        case "upsert_exercise": return "Exercise saved"
        case "approve_exercise": return "Exercise approved"

        // Active workout
        case "propose_session": return "Session proposed"
        case "start_active_workout": return "Workout started"
        case "get_active_workout": return "Active workout loaded"
        case "prescribe_set": return "Set prescribed"
        case "log_set": return "Set logged"
        case "score_set": return "Set scored"
        case "add_exercise": return "Exercise added"
        case "swap_exercise": return "Exercise swapped"
        case "complete_active_workout": return "Workout completed"
        case "cancel_active_workout": return "Workout cancelled"
        case "note_active_workout": return "Note added"

        // Memory management
        case "store_important_fact": return "Information saved"
        case "get_important_facts": return "Information recalled"
        
        default: return "Complete"
        }
    }
}

// MARK: - Error Types

enum StreamingError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case invalidURL
    case httpError(statusCode: Int)
    case premiumRequired

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User not authenticated"
        case .invalidResponse:
            return "Invalid response from Agent Engine API"
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .premiumRequired:
            return "Premium subscription required"
        }
    }
}
