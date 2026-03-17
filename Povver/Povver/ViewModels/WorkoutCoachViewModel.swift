import Foundation

/// ViewModel for workout coach chat during active workout.
/// Chat is ephemeral (in-memory only, not persisted to Firestore).
///
/// Streaming pattern mirrors CanvasViewModel:
/// - .message events: accumulate text deltas via displayText
/// - .done event: flush messageBuffer as final agent response
/// - .status events: extract session_id for conversation continuity
@MainActor
final class WorkoutCoachViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var inputText = ""
    @Published var showingPaywall = false
    @Published var errorMessage: String? = nil

    /// Gemini-style thinking process — reuses ThinkingProcessState from shell agent
    let thinkingState = ThinkingProcessState()

    private(set) var workoutId: String
    /// Per-workout session isolation — prevents context bleed across workouts
    var conversationId: String { "workout-\(workoutId)" }

    init(workoutId: String) {
        self.workoutId = workoutId
    }

    /// Update workout context. Resets conversation for a different workout.
    func updateWorkout(_ workoutId: String) {
        guard workoutId != self.workoutId else { return }
        self.workoutId = workoutId
        self.messages = []
        self.thinkingState.reset()
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        if messages.isEmpty {
            let elapsedMin = Int(Date().timeIntervalSince(FocusModeWorkoutService.shared.workout?.startTime ?? Date()) / 60)
            let setsLogged = FocusModeWorkoutService.shared.workout?.exercises.reduce(0) { $0 + $1.sets.filter { $0.isDone }.count } ?? 0
            AnalyticsService.shared.workoutCoachOpened(workoutId: workoutId, elapsedMin: elapsedMin, setsLogged: setsLogged)
        }

        inputText = ""

        let userMsg = ChatMessage(
            content: .text(text),
            author: .user
        )
        messages.append(userMsg)

        AnalyticsService.shared.workoutCoachMsgSent(workoutId: workoutId, messageLength: text.count)

        guard let userId = AuthService.shared.currentUser?.uid else {
            messages.append(ChatMessage(
                content: .error("Not authenticated"),
                author: .system
            ))
            return
        }

        isStreaming = true
        thinkingState.start()

        // Placeholder for streaming agent response
        let agentMsgId = UUID().uuidString
        messages.append(ChatMessage(
            id: agentMsgId,
            content: .text(""),
            author: .agent,
            status: .streaming
        ))

        // Accumulate text deltas (same pattern as CanvasViewModel.messageBuffer)
        var messageBuffer = ""

        do {
            let stream = DirectStreamingService.shared.streamQuery(
                userId: userId,
                conversationId: conversationId,
                message: text,
                correlationId: UUID().uuidString,
                workoutId: workoutId
            )

            for try await event in stream {
                // Forward all events to thinking state (same pattern as CanvasViewModel)
                thinkingState.handleEvent(event)

                switch event.eventType {
                case .message:
                    // Text delta — accumulate via displayText
                    let delta = event.displayText
                    if !delta.isEmpty {
                        messageBuffer += delta
                        updateAgentMessage(id: agentMsgId, text: messageBuffer, status: .streaming)
                    }

                case .status:
                    break

                case .done:
                    // Flush: use accumulated buffer as final response
                    let response = messageBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !response.isEmpty {
                        updateAgentMessage(id: agentMsgId, text: response, status: .sent)
                    } else {
                        messages.removeAll { $0.id == agentMsgId }
                    }
                    messageBuffer = ""

                case .error:
                    let errorText = event.displayText
                    updateAgentMessage(id: agentMsgId, text: errorText.isEmpty ? "Error" : errorText, status: .failed)

                case .pipeline, .thinking, .thought, .toolRunning, .toolComplete,
                     .heartbeat, .card, .artifact,
                     .agentResponse, .userPrompt, .userResponse, .clarificationRequest:
                    // Handled by thinkingState.handleEvent() above
                    break

                case .none:
                    break
                }
            }

            // If stream ended without .done (connection dropped), finalize
            if !messageBuffer.isEmpty {
                let response = messageBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !response.isEmpty {
                    updateAgentMessage(id: agentMsgId, text: response, status: .sent)
                }
            }

        } catch {
            if let streamingError = error as? StreamingError,
               case .premiumRequired = streamingError {
                showingPaywall = true
                messages.removeAll { $0.id == agentMsgId }
            } else {
                AppLogger.shared.error(.agent, "workout copilot stream failed", error)
                updateAgentMessage(id: agentMsgId, text: "Connection error. Try again.", status: .failed)
            }
        }

        thinkingState.complete()
        isStreaming = false

        // Refresh workout state from server — picks up exercises/sets
        // added by the agent via Firebase Functions
        await FocusModeWorkoutService.shared.refreshFromServer()
    }

    private func updateAgentMessage(id: String, text: String, status: MessageStatus) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = ChatMessage(
                id: id,
                content: .text(text),
                author: .agent,
                status: status
            )
        }
    }
}
