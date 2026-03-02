/**
 =============================================================================
 CanvasViewModel.swift - Central Canvas State Management
 =============================================================================
 
 PURPOSE:
 The central ViewModel for the canvas experience. Manages canvas state, card
 collections, SSE streaming from agent, and user actions.
 
 ARCHITECTURE CONTEXT:
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ iOS CANVAS DATA FLOW                                                        │
 │                                                                             │
 │ CanvasScreen.swift (UI)                                                     │
 │   │                                                                         │
 │   ▼                                                                         │
 │ CanvasViewModel (THIS FILE)                                                 │
 │   │                                                                         │
 │   ├──▶ CanvasRepository.subscribe() ──▶ Firestore Listener                 │
 │   │      cards collection, state doc                                        │
 │   │                                                                         │
 │   ├──▶ CanvasService.applyAction() ──▶ apply-action.js                     │
 │   │      user actions (accept, dismiss, edit)                               │
 │   │                                                                         │
 │   ├──▶ DirectStreamingService.streamQuery() ──▶ stream-agent-normalized.js │
 │   │      SSE events during agent work                                       │
 │   │                                                                         │
 │   └──▶ CanvasService.openCanvas() ──▶ open-canvas.js                       │
 │          canvas + session initialization                                    │
 └─────────────────────────────────────────────────────────────────────────────┘
 
 KEY STATE:
 - cards: [CanvasCardModel] - All canvas cards from Firestore listener
 - streamEvents: [StreamEvent] - SSE events for workspace timeline
 - workspaceEvents: [WorkspaceEvent] - Persisted conversation history
 - thinkingState: ThinkingProcessState - Gemini-style collapsible thought process
 - pendingClarificationCue: ClarificationCue? - Pending agent question
 
 METHODS:
 - start(userId:canvasId:) - Open existing canvas with session reuse
 - start(userId:purpose:) - Create new canvas with combined openCanvas call
 - startSSEStream() - Begin agent streaming with correlation ID
 - applyAction() - Send user action to apply-action.js
 - handleIncomingStreamEvent() - Process SSE events and update UI
 
 FIRESTORE LISTENERS:
 - Canvas cards: users/{uid}/canvases/{canvasId}/cards
 - Canvas state: users/{uid}/canvases/{canvasId}/state
 - Workspace entries: users/{uid}/canvases/{canvasId}/workspace_entries
 - Events (telemetry): users/{uid}/canvases/{canvasId}/events
 
 RELATED FILES:
 - CanvasScreen.swift: UI layer that uses this ViewModel
 - CanvasRepository.swift: Firestore subscription logic
 - CanvasService.swift: HTTP calls to Firebase Functions
 - DirectStreamingService.swift: SSE streaming client
 
 =============================================================================
 */

import Foundation
import Combine
import FirebaseFirestore

struct ClarificationCue: Identifiable, Equatable {
    let id: String
    let question: String
}

@MainActor
final class CanvasViewModel: ObservableObject {
    @Published var cards: [CanvasCardModel] = []
    @Published var upNext: [String] = []
    @Published var version: Int = 0
    @Published var phase: CanvasPhase = .planning
    @Published var canvasId: String?
    @Published var isApplying: Bool = false
    @Published var errorMessage: String?
    @Published var isReady: Bool = false
    @Published var pendingInvoke: (message: String, correlationId: String)? = nil
    
    // SSE Streaming properties
    @Published var streamEvents: [StreamEvent] = []
    @Published var currentAgentStatus: String? = nil
    @Published var isAgentThinking: Bool = false
    @Published var showStreamOverlay: Bool = false
    @Published var workspaceEvents: [WorkspaceEvent] = []
    @Published var pendingClarificationCue: ClarificationCue? = nil
    
    // Gemini-style thinking process state
    @Published var thinkingState = ThinkingProcessState()

    // Paywall state
    @Published var showingPaywall: Bool = false

    private let repo: CanvasRepositoryProtocol
    private let service: CanvasServiceProtocol
    private var streamTask: Task<Void, Never>?
    private var sseStreamTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var eventsListener: ListenerRegistration?
    private var workspaceListener: ListenerRegistration?
    private var currentUserId: String?
    private var currentSessionId: String?
    
    // Overlay synthesis state
    private var messageBuffer: String = ""
    private var thoughtStartAt: Double? = nil
    private var toolStartByName: [String: Double] = [:]

    // Conversation tracking state
    private var conversationDepth: Int = 0
    private var conversationStartTime: Date?
    private var artifactsReceived: Int = 0
    private var artifactsAccepted: Int = 0
    private var didFireConversationEnded: Bool = false

    init(repo: CanvasRepositoryProtocol = CanvasRepository(), service: CanvasServiceProtocol = CanvasService()) {
        self.repo = repo
        self.service = service
    }

    func start(userId: String, canvasId: String) {
        streamTask?.cancel()
        let startTime = Date()

        // Reset conversation tracking state
        conversationDepth = 0
        conversationStartTime = Date()
        artifactsReceived = 0
        artifactsAccepted = 0
        didFireConversationEnded = false

        AppLogger.shared.nav("canvas:\(canvasId)")
        AppLogger.shared.info(.app, "Canvas start BEGIN (existing canvas) canvas_id=\(canvasId)")
        AnalyticsService.shared.conversationStarted(entryPoint: "existing_canvas")
        
        streamTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                self.currentUserId = userId
                self.canvasId = canvasId
                await MainActor.run { CanvasRepository.shared.currentCanvasId = canvasId }
                
                // PHASE 1 OPTIMIZATION: Clear UI state and attach listeners IMMEDIATELY
                await MainActor.run {
                    self.cards = []
                    self.upNext = []
                    self.pendingClarificationCue = nil
                }
                
                // Attach listeners right away (don't wait for session)
                self.attachEventsListener(userId: userId, canvasId: canvasId)
                self.attachWorkspaceEntriesListener(userId: userId, canvasId: canvasId)
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                AppLogger.shared.info(.app, "Listeners attached elapsed_s=\(elapsed)")
                
                // PHASE 1 OPTIMIZATION: Start session initialization in parallel
                // Use forceNew: false to enable session reuse
                let sessionTask = Task<String?, Never> {
                    let sessionStart = Date()
                    do {
                        let sessionId = try await self.service.initializeSession(canvasId: canvasId, purpose: "general", forceNew: false)
                        let sessionDuration = Date().timeIntervalSince(sessionStart)
                        AppLogger.shared.info(.app, "Session initialized session_id=\(sessionId) duration_s=\(String(format: "%.2f", sessionDuration)) reuse_enabled=true")
                        return sessionId
                    } catch {
                        AppLogger.shared.error(.app, "initializeSession failed - will create new on first message", error)
                        return nil
                    }
                }
                
                // PHASE 1 OPTIMIZATION: Skip purgeCanvas
                // Purging workspace_entries on every open adds latency and loses conversation history
                AppLogger.shared.info(.app, "Skipping purgeCanvas (optimization)")

                let subElapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                AppLogger.shared.info(.app, "Starting subscription elapsed_s=\(subElapsed)")
                
                // Subscribe to canvas updates
                var firstSnapshotReceived = false
                for try await snap in self.repo.subscribe(userId: userId, canvasId: canvasId) {
                    if !firstSnapshotReceived {
                        firstSnapshotReceived = true
                        let snapElapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                        AppLogger.shared.info(.app, "First snapshot received elapsed_s=\(snapElapsed)")
                    }

                    // Log canvas state snapshot
                    self.logCanvasSnapshot(snap: snap, trigger: "firestore_update")

                    self.version = snap.version
                    self.cards = snap.cards
                    self.upNext = snap.upNext
                    if let ph = snap.state.phase { self.phase = ph }

                    // Mark ready on first snapshot
                    if self.isReady == false {
                        self.isReady = true
                        let readyElapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                        AppLogger.shared.info(.app, "Canvas READY elapsed_s=\(readyElapsed)")
                    }
                }
                
                // Resolve session in background (don't block UI)
                if let sessionId = await sessionTask.value {
                    await MainActor.run { self.currentSessionId = sessionId }
                }

            } catch {
                self.errorMessage = error.localizedDescription
                AppLogger.shared.error(.app, "Canvas subscribe error", error)
            }
        }
    }

    func start(userId: String, purpose: String) {
        streamTask?.cancel()
        let startTime = Date()

        // Reset conversation tracking state
        conversationDepth = 0
        conversationStartTime = Date()
        artifactsReceived = 0
        artifactsAccepted = 0
        didFireConversationEnded = false

        AppLogger.shared.nav("canvas:new")
        AppLogger.shared.info(.app, "Canvas start BEGIN (new canvas) purpose=\(purpose)")
        AnalyticsService.shared.conversationStarted(entryPoint: purpose)
        
        streamTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                self.currentUserId = userId
                
                // PHASE 2 OPTIMIZATION: Use combined openCanvas endpoint (1 call instead of 2)
                // This creates canvas + session in parallel on the server, saving a network round trip
                let openStart = Date()
                let (cid, sessionId) = try await self.service.openCanvas(userId: userId, purpose: purpose)
                let openDuration = Date().timeIntervalSince(openStart)

                AppLogger.shared.info(.app, "openCanvas completed canvas_id=\(cid) session_id=\(sessionId) duration_s=\(String(format: "%.2f", openDuration))")
                
                self.canvasId = cid
                self.currentSessionId = sessionId
                await MainActor.run { CanvasRepository.shared.currentCanvasId = cid }
                
                // Clear UI state and attach listeners IMMEDIATELY
                await MainActor.run {
                    self.cards = []
                    self.upNext = []
                    self.pendingClarificationCue = nil
                }
                
                // Attach listeners right away
                self.attachEventsListener(userId: userId, canvasId: cid)
                self.attachWorkspaceEntriesListener(userId: userId, canvasId: cid)
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                AppLogger.shared.info(.app, "Listeners attached elapsed_s=\(elapsed)")

                let subElapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                AppLogger.shared.info(.app, "Starting subscription elapsed_s=\(subElapsed)")
                
                // Subscribe to canvas updates
                var firstSnapshotReceived = false
                for try await snap in self.repo.subscribe(userId: userId, canvasId: cid) {
                    if !firstSnapshotReceived {
                        firstSnapshotReceived = true
                        let snapElapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                        AppLogger.shared.info(.app, "First snapshot received elapsed_s=\(snapElapsed)")
                    }

                    // Log canvas state snapshot
                    self.logCanvasSnapshot(snap: snap, trigger: "firestore_update")

                    self.version = snap.version
                    self.cards = snap.cards
                    self.upNext = snap.upNext
                    if let ph = snap.state.phase { self.phase = ph }

                    // Mark ready on first snapshot
                    if self.isReady == false {
                        self.isReady = true
                        let readyElapsed = String(format: "%.2f", Date().timeIntervalSince(startTime))
                        AppLogger.shared.info(.app, "Canvas READY elapsed_s=\(readyElapsed)")
                    }
                }

            } catch {
                self.errorMessage = error.localizedDescription
                AppLogger.shared.error(.app, "openCanvas/subscribe error", error)
            }
        }
    }

    func stop() {
        // Fire conversation_ended event if conversation had activity
        if !didFireConversationEnded {
            didFireConversationEnded = true
            if conversationDepth > 0 {
                let durationSec = Int(Date().timeIntervalSince(conversationStartTime ?? Date()))
                AnalyticsService.shared.conversationEnded(
                    ConversationEndedParams(
                        conversationDepth: conversationDepth,
                        artifactsReceived: artifactsReceived,
                        artifactsAccepted: artifactsAccepted,
                        durationSec: durationSec
                    )
                )
            }
        }

        streamTask?.cancel()
        streamTask = nil
        eventsListener?.remove()
        eventsListener = nil
        workspaceListener?.remove()
        workspaceListener = nil
        isReady = false
        currentSessionId = nil
    }

    // MARK: - Actions
    
    func applyAction(canvasId: String, expectedVersion: Int? = nil, type: String, cardId: String? = nil, payload: [String: AnyCodable]? = nil) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let req = ApplyActionRequestDTO(
            canvasId: canvasId,
            expected_version: expectedVersion ?? version,
            action: CanvasActionDTO(type: type, card_id: cardId, payload: payload, by: "user", idempotency_key: UUID().uuidString)
        )
        do {
            let result = try await service.applyAction(req)
            if result.success == false, let err = result.error {
                if err.code == "STALE_VERSION" {
                    // Retry once with updated version
                    let retry = ApplyActionRequestDTO(canvasId: canvasId, expected_version: self.version, action: req.action)
                    _ = try await service.applyAction(retry)
                } else {
                    errorMessage = err.message
                }
            } else {
                let cardType = cards.first(where: { $0.id == cardId })?.type.rawValue ?? "unknown"
                AnalyticsService.shared.artifactAction(action: type, artifactType: cardType)

                // Track artifact acceptance for conversation_ended event
                if type == "accept" || type == "start_workout" || type == "save_as_template" || type == "save_routine" {
                    artifactsAccepted += 1
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startSSEStream(userId: String, canvasId: String, message: String, correlationId: String) {
        AppLogger.shared.user("message", String(message.prefix(80)))
        AppLogger.shared.info(.app, "SSE stream BEGIN corr=\(correlationId) sessionId=\(currentSessionId ?? "nil")")

        // Increment conversation depth synchronously before async Task block
        conversationDepth += 1
        AnalyticsService.shared.messageSent(messageLength: message.count, conversationDepth: conversationDepth)

        sseStreamTask?.cancel()
        sseStreamTask = Task { [weak self] in
            guard let self = self else { return }

            // Show overlay while agent is working
            await MainActor.run {
                self.showStreamOverlay = true
                self.streamEvents = []
                self.currentAgentStatus = "Connecting..."
                self.isAgentThinking = true
                self.messageBuffer = ""
                self.thoughtStartAt = Date().timeIntervalSince1970
                self.toolStartByName.removeAll()
                // Reset and start Gemini-style thinking process
                self.thinkingState.start()
            }
            
            // Track last meaningful event time for timeout detection
            var lastMeaningfulEventTime = Date()
            let streamTimeoutSeconds: TimeInterval = 120
            var receivedDoneEvent = false
            
            do {
                // Seed log with user prompt
                await MainActor.run {
                    let now = Date().timeIntervalSince1970
                    let evt = StreamEvent(
                        type: "user_prompt",
                        agent: "user",
                        content: [
                            "text": AnyCodable(message),
                            "correlation_id": AnyCodable(correlationId)
                        ],
                        timestamp: now,
                        metadata: ["source": AnyCodable("client")]
                    )
                    self.streamEvents.append(evt)

                    // Inject into workspace events for immediate timeline display.
                    // The server persists the authoritative copy; when the listener
                    // fires it replaces this array, naturally superseding this entry.
                    let userWorkspaceEvent = WorkspaceEvent(
                        id: "local-\(correlationId)",
                        event: evt,
                        createdAt: Date()
                    )
                    self.workspaceEvents.append(userWorkspaceEvent)
                }
                
                // Stream agent events
                for try await event in DirectStreamingService.shared.streamQuery(
                    userId: userId,
                    conversationId: canvasId,
                    message: message,
                    correlationId: correlationId,
                    sessionId: self.currentSessionId
                ) {
                    // Check for timeout (only heartbeats for too long)
                    let isMeaningfulEvent = event.eventType != .heartbeat && event.eventType != .status
                    if isMeaningfulEvent {
                        lastMeaningfulEventTime = Date()
                    } else if Date().timeIntervalSince(lastMeaningfulEventTime) > streamTimeoutSeconds {
                        AppLogger.shared.info(.app, "Stream timeout - only heartbeats for \(streamTimeoutSeconds)s")
                        await MainActor.run {
                            self.thinkingState.complete()
                            self.currentAgentStatus = "Request timed out"
                            self.showStreamOverlay = false
                            self.isAgentThinking = false
                        }
                        break
                    }
                    
                    // NOTE: SSE event logging is handled by AgentPipelineLogger - no need to duplicate here
                    await MainActor.run {
                        self.handleIncomingStreamEvent(event)
                    }
                    
                    if event.eventType == .done {
                        receivedDoneEvent = true
                    }
                }

                // If stream ended without done event, clean up gracefully
                if !receivedDoneEvent {
                    AppLogger.shared.info(.app, "Stream ended without done event - cleaning up")
                    await MainActor.run {
                        self.thinkingState.complete()
                        self.showStreamOverlay = false
                        self.isAgentThinking = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.thinkingState.complete()
                    // Check if this is a premium required error
                    if let streamingError = error as? StreamingError,
                       case .premiumRequired = streamingError {
                        AnalyticsService.shared.paywallShown(trigger: "streaming_premium_gate")
                        self.showingPaywall = true
                        self.showStreamOverlay = false
                        self.isAgentThinking = false
                    } else {
                        AnalyticsService.shared.streamingError(errorCode: error.localizedDescription)
                        self.errorMessage = "Streaming error: \(error.localizedDescription)"
                        self.showStreamOverlay = false
                        self.isAgentThinking = false
                    }
                }
            }
        }
    }
    
    private func handleIncomingStreamEvent(_ event: StreamEvent) {
        let now = Date().timeIntervalSince1970
        guard let type = event.eventType else { return }
        
        // Forward ALL events to Gemini-style thinking state
        thinkingState.handleEvent(event)
        
        switch type {
        case .pipeline:
            // Pipeline events (router, planner, critic) are handled by thinkingState
            // Just log for debugging
            if let step = event.content?["step"]?.value as? String {
                AppLogger.shared.info(.app, "Pipeline: \(step)")
            }
            
        case .thinking:
            currentAgentStatus = event.displayText
            isAgentThinking = true
            if thoughtStartAt == nil { thoughtStartAt = event.timestamp ?? now }
            streamEvents.append(event)
            
        case .toolRunning:
            currentAgentStatus = event.displayText
            isAgentThinking = true
            let toolName = (event.content?["tool"]?.value as? String) ?? (event.content?["tool_name"]?.value as? String) ?? "tool"
            toolStartByName[toolName] = event.timestamp ?? now
            streamEvents.append(event)
            
        case .toolComplete:
            isAgentThinking = false
            let toolName = (event.content?["tool"]?.value as? String) ?? (event.content?["tool_name"]?.value as? String) ?? "tool"
            let start = toolStartByName.removeValue(forKey: toolName) ?? (event.timestamp ?? now)
            let end = event.timestamp ?? now
            let secs = max(0, end - start)
            let formatted = StreamEvent(
                type: "toolComplete",
                agent: event.agent,
                content: [
                    "text": AnyCodable(event.displayText),
                    "tool": AnyCodable(toolName),
                    "duration_s": AnyCodable(secs),
                    "phase": event.content?["phase"] ?? AnyCodable("")
                ],
                timestamp: event.timestamp ?? now,
                metadata: event.metadata
            )
            streamEvents.append(formatted)
            
        case .message:
            let delta = event.displayText
            if !delta.isEmpty {
                messageBuffer += delta
            }
            
        case .status:
            currentAgentStatus = event.displayText
            streamEvents.append(event)
            if let sessionId = event.content?["session_id"]?.value as? String {
                currentSessionId = sessionId
            }
            
        case .userPrompt:
            streamEvents.append(event)
            
        case .userResponse:
            streamEvents.append(event)
            
        case .clarificationRequest:
            streamEvents.append(event)
            if let id = event.content?["id"]?.value as? String,
               let question = event.content?["question"]?.value as? String {
                pendingClarificationCue = ClarificationCue(id: id, question: question)
            }
            
        case .error:
            // Check for server-side premium gate (defense-in-depth: client gate catches most cases,
            // but if client cache is stale the server emits PREMIUM_REQUIRED via SSE error event)
            if let code = event.content?["code"]?.value as? String, code == "PREMIUM_REQUIRED" {
                AnalyticsService.shared.paywallShown(trigger: "server_premium_gate")
                showingPaywall = true
            } else {
                errorMessage = event.displayText
            }
            showStreamOverlay = false
            isAgentThinking = false
            
        case .done:
            thinkingState.complete()
            if let start = thoughtStartAt {
                let secs = max(0, (event.timestamp ?? now) - start)
                let text = String(format: "Thought for %.1fs", secs)
                let thoughtEvt = StreamEvent(
                    type: "thought",
                    agent: event.agent,
                    content: [
                        "text": AnyCodable(text),
                        "duration_s": AnyCodable(secs)
                    ],
                    timestamp: event.timestamp ?? now,
                    metadata: event.metadata
                )
                streamEvents.append(thoughtEvt)
                thoughtStartAt = nil
            }
            isAgentThinking = false
            let response = messageBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !response.isEmpty {
                let responseEvt = StreamEvent(
                    type: "agent_response",
                    agent: event.agent,
                    content: ["text": AnyCodable(response)],
                    timestamp: event.timestamp ?? now,
                    metadata: event.metadata
                )
                streamEvents.append(responseEvt)
            }
            messageBuffer = ""
            showStreamOverlay = false
            
        case .agentResponse:
            streamEvents.append(event)
            
        case .thought:
            streamEvents.append(event)
            
        case .artifact:
            // Build a CanvasCardModel from artifact SSE event data
            guard let artifactType = event.content?["artifact_type"]?.value as? String else { break }

            let artifactId = event.content?["artifact_id"]?.value as? String
            let artifactContent = event.content?["artifact_content"]?.value as? [String: Any] ?? [:]
            let actionsRaw = event.content?["actions"]?.value as? [Any] ?? []
            let actionStrings = actionsRaw.compactMap { $0 as? String }
            let status = event.content?["status"]?.value as? String ?? "proposed"

            if let card = buildCardFromArtifact(
                type: artifactType,
                content: artifactContent,
                actions: actionStrings,
                status: status,
                artifactId: artifactId
            ) {
                cards.append(card)
                streamEvents.append(event)
                artifactsReceived += 1
                AnalyticsService.shared.artifactReceived(artifactType: artifactType, conversationDepth: conversationDepth)
                AppLogger.shared.info(.app, "Artifact card added type=\(artifactType) id=\(card.id) artifactId=\(artifactId ?? "nil")")
            }

        case .card, .heartbeat:
            break
        }

        // Auto-hide overlay if cards start appearing
        if !cards.isEmpty {
            showStreamOverlay = false
        }
    }
    
    private func humanReadableToolName(_ name: String) -> String {
        switch name {
        case "tool_set_canvas_context": return "canvas context"
        case "tool_fetch_profile": return "athlete profile"
        case "tool_fetch_recent_sessions": return "recent sessions"
        case "tool_emit_agent_event": return "telemetry"
        case "tool_format_workout_plan_cards": return "workout plan formatter"
        case "tool_format_analysis_cards": return "analysis formatter"
        case "tool_publish_cards": return "card publisher"
        case "get_user_workouts": return "activity history"
        case "get_user_routines": return "routines"
        case "list_exercises", "search_exercises": return "exercise library"
        case "get_user_templates": return "templates"
        case "get_active_workout": return "active workout"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }
    
    // MARK: - Artifact → Card Conversion

    /// Converts an artifact SSE event into a CanvasCardModel for inline display.
    /// Uses JSON round-trip to leverage existing Codable decoders (PlanExercise, RoutineSummaryData, etc.)
    /// When artifactId is provided (from pre-generated Firestore doc ID), it becomes the card's stable identity
    /// and is stored in CardMeta for artifact action routing.
    private func buildCardFromArtifact(
        type: String,
        content: [String: Any],
        actions: [String],
        status: String,
        artifactId: String? = nil
    ) -> CanvasCardModel? {
        let cardStatus = CardStatus(rawValue: status) ?? .proposed
        let cardActions = actions.map { action -> CardAction in
            let label: String
            let style: CardActionStyle
            switch action {
            case "start_workout":
                label = "Start Workout"
                style = .primary
            case "save_routine":
                label = "Save Routine"
                style = .primary
            case "dismiss":
                label = "Dismiss"
                style = .ghost
            default:
                label = action.replacingOccurrences(of: "_", with: " ").capitalized
                style = .secondary
            }
            return CardAction(kind: action, label: label, style: style)
        }

        // Use artifactId as stable card identity when available
        let cardId = artifactId ?? UUID().uuidString
        let artifactMeta = { (notes: String?) -> CardMeta in
            CardMeta(notes: notes, artifactId: artifactId, conversationId: self.canvasId)
        }

        switch type {
        case "session_plan":
            let title = content["title"] as? String ?? "Workout"
            let coachNotes = content["coach_notes"] as? String
            let blocks = content["blocks"] as? [[String: Any]] ?? []

            // Parse blocks → [PlanExercise] via JSON round-trip (reuses existing Codable decoder)
            var exercises: [PlanExercise] = []
            if let jsonData = try? JSONSerialization.data(withJSONObject: blocks),
               let decoded = try? JSONDecoder().decode([PlanExercise].self, from: jsonData) {
                exercises = decoded
            }

            return CanvasCardModel(
                id: cardId,
                type: .session_plan,
                status: cardStatus,
                lane: .workout,
                title: title,
                data: .sessionPlan(exercises: exercises),
                actions: cardActions,
                meta: artifactMeta(coachNotes),
                publishedAt: Date()
            )

        case "routine_summary":
            let name = content["name"] as? String ?? "Routine"
            let description = content["description"] as? String
            let frequency = content["frequency"] as? Int ?? 0
            let workoutsRaw = content["workouts"] as? [[String: Any]] ?? []

            var workouts: [RoutineWorkoutSummary] = []
            if let jsonData = try? JSONSerialization.data(withJSONObject: workoutsRaw),
               let decoded = try? JSONDecoder().decode([RoutineWorkoutSummary].self, from: jsonData) {
                workouts = decoded
            }

            let mode = content["mode"] as? String
            let sourceRoutineId = content["source_routine_id"] as? String
            let sourceRoutineName = content["source_routine_name"] as? String

            let routineData = RoutineSummaryData(
                name: name,
                description: description,
                frequency: frequency,
                workouts: workouts,
                mode: mode,
                sourceRoutineId: sourceRoutineId,
                sourceRoutineName: sourceRoutineName
            )

            return CanvasCardModel(
                id: cardId,
                type: .routine_summary,
                status: cardStatus,
                lane: .workout,
                title: name,
                data: .routineSummary(routineData),
                actions: cardActions,
                meta: artifactMeta(nil),
                publishedAt: Date()
            )

        case "analysis_summary":
            if let jsonData = try? JSONSerialization.data(withJSONObject: content),
               let decoded = try? JSONDecoder().decode(AnalysisSummaryData.self, from: jsonData) {
                return CanvasCardModel(
                    id: cardId,
                    type: .analysis_summary,
                    status: cardStatus,
                    lane: .analysis,
                    title: decoded.headline,
                    data: .analysisSummary(decoded),
                    actions: cardActions,
                    meta: artifactMeta(nil),
                    publishedAt: Date()
                )
            }
            return nil

        case "visualization":
            if let jsonData = try? JSONSerialization.data(withJSONObject: content),
               let decoded = try? JSONDecoder().decode(VisualizationSpec.self, from: jsonData) {
                return CanvasCardModel(
                    id: cardId,
                    type: .visualization,
                    status: cardStatus,
                    lane: .analysis,
                    title: decoded.title,
                    data: .visualization(spec: decoded),
                    actions: cardActions,
                    meta: artifactMeta(nil),
                    publishedAt: Date()
                )
            }
            return nil

        default:
            AppLogger.shared.info(.app, "Unknown artifact type: \(type)")
            return nil
        }
    }

    private func attachEventsListener(userId: String, canvasId: String) {
        eventsListener?.remove()
        let db = Firestore.firestore()
        let eventsRef = db.collection("users").document(userId).collection("canvases").document(canvasId).collection("events").order(by: "created_at", descending: true).limit(to: 50)
        eventsListener = eventsRef.addSnapshotListener { snap, _ in
            guard let docs = snap?.documents else { return }
            for doc in docs {
                if let payload = doc.data()["payload"] as? [String: Any], let correlation = payload["correlation_id"] as? String {
                    AppLogger.shared.info(.app, "event=\(doc.data()["type"] as? String ?? "?") correlation=\(correlation)")
                }
            }
        }
    }

    private func attachWorkspaceEntriesListener(userId: String, canvasId: String) {
        workspaceListener?.remove()
        let db = Firestore.firestore()
        // Query newest 200 entries (descending) so recent messages are always included.
        // Each agent turn generates ~20-50 entries, so ascending+limit(200) dropped
        // all recent messages once a conversation exceeded ~200 total entries.
        let ref = db.collection("users")
            .document(userId)
            .collection("canvases")
            .document(canvasId)
            .collection("workspace_entries")
            .order(by: "created_at", descending: true)
            .limit(to: 200)
        let decoder = JSONDecoder()
        workspaceListener = ref.addSnapshotListener { [weak self] snapshot, error in
            guard let self, let snapshot = snapshot else {
                if let error {
                    AppLogger.shared.error(.store, "workspace_entries listener error", error)
                }
                return
            }
            let docs = snapshot.documents
            let events: [WorkspaceEvent] = docs.compactMap { doc in
                guard let entry = doc.data()["entry"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(entry),
                      let data = try? JSONSerialization.data(withJSONObject: entry),
                      let streamEvent = try? decoder.decode(StreamEvent.self, from: data) else {
                    return nil
                }
                let timestamp = (doc.data()["created_at"] as? Timestamp)?.dateValue()
                return WorkspaceEvent(id: doc.documentID, event: streamEvent, createdAt: timestamp)
            }
            Task { @MainActor in
                // Reverse to chronological order (query returns newest-first)
                self.workspaceEvents = events.reversed()
            }
        }
    }

    // recordUserPromptEntry removed — both workspace_entries write and canvas
    // metadata update are now handled server-side in stream-agent-normalized.js
    // (client writes were blocked by Firestore security rules).

    func clearCards() {
        cards = []
        upNext = []
    }

    /// Transition proposed/active cards to completed status.
    /// Preserves artifacts in the timeline but strips action buttons
    /// so users can't re-act on stale proposals.
    func archiveProposedCards() {
        cards = cards.map { card in
            guard card.status == .proposed || card.status == .active else { return card }
            return CanvasCardModel(
                id: card.id,
                type: card.type,
                status: .completed,
                lane: card.lane,
                title: card.title,
                subtitle: card.subtitle,
                data: card.data,
                width: card.width,
                actions: [],
                menuItems: [],
                meta: card.meta,
                publishedAt: card.publishedAt
            )
        }
    }

    func logUserResponse(text: String) {
        guard let userId = currentUserId, let canvasId = canvasId else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users")
            .document(userId)
            .collection("canvases")
            .document(canvasId)
            .collection("workspace_entries")
            .document()
        let entry: [String: Any] = [
            "entry": [
                "type": "user_response",
                "agent": userId,
                "content": [
                    "text": text
                ],
                "timestamp": Date().timeIntervalSince1970
            ],
            "type": "user_response",
            "agent": userId,
            "created_at": FieldValue.serverTimestamp()
        ]
        ref.setData(entry) { error in
            if let error {
                AppLogger.shared.error(.app, "Failed to log user response", error)
            }
        }
    }

    func clearPendingClarification(id: String) {
        if pendingClarificationCue?.id == id {
            pendingClarificationCue = nil
        }
    }
    
    // MARK: - Canvas State Snapshot Logging

    private func logCanvasSnapshot(snap: CanvasSnapshot, trigger: String) {
        let phase = snap.state.phase?.rawValue ?? "unknown"
        let cardCount = snap.cards.count
        let cardSummary = snap.cards.map { "\($0.type.rawValue)(\($0.status.rawValue))" }.joined(separator: ", ")
        AppLogger.shared.info(.store, "snapshot phase=\(phase) v=\(snap.version) cards=\(cardCount) [\(cardSummary)] trigger=\(trigger)")
    }
}
