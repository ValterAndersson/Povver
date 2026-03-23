import Foundation

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
                    // If cached state says not-premium, refresh once — the override may
                    // not have loaded yet on cold launch (race with .task entitlement check).
                    if await !SubscriptionService.shared.isPremium {
                        await SubscriptionService.shared.checkEntitlements()
                        if await !SubscriptionService.shared.isPremium {
                            AgentPipelineLogger.failRequest(error: "Premium required", afterMs: 0)
                            continuation.finish(throwing: StreamingError.premiumRequired)
                            return
                        }
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

    // MARK: - Onboarding Streaming

    /// Onboarding-specific streaming — calls the dedicated endpoint with no premium check.
    /// Server builds the prompt from structured parameters.
    func streamOnboardingRoutine(
        userId: String,
        conversationId: String,
        fitnessLevel: String,
        frequency: Int,
        equipment: String
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let currentUser = AuthService.shared.currentUser else {
                        continuation.finish(throwing: StreamingError.notAuthenticated)
                        return
                    }

                    // No premium check — this endpoint is free for onboarding

                    let idToken = try await currentUser.getIDToken()

                    let url = URL(string: "https://us-central1-myon-53d85.cloudfunctions.net/streamOnboardingRoutine")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let body: [String: Any] = [
                        "conversationId": conversationId,
                        "fitnessLevel": fitnessLevel,
                        "frequency": frequency,
                        "equipment": equipment,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Use a dedicated session for this request so timeout
                    // cancellation doesn't destroy the shared URLSession.
                    let onboardingSession = URLSession(configuration: .default)
                    let (asyncBytes, response) = try await onboardingSession.bytes(for: request)

                    let timeoutTask = Task {
                        try await Task.sleep(nanoseconds: 120 * 1_000_000_000) // 2min
                        onboardingSession.invalidateAndCancel()
                    }
                    defer { timeoutTask.cancel() }

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw StreamingError.httpError(statusCode: code)
                    }

                    for try await line in asyncBytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))

                            if jsonStr == "[DONE]" {
                                continuation.finish()
                                break
                            }

                            if let data = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

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

                                let event = StreamEvent(
                                    type: json["type"] as? String ?? "unknown",
                                    agent: json["agent"] as? String,
                                    content: contentDict,
                                    timestamp: json["timestamp"] as? Double,
                                    metadata: metadataDict
                                )
                                continuation.yield(event)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
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
