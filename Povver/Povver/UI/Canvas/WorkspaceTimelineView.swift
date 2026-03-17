import SwiftUI

// MARK: - Scroll Position Tracking Key
private struct BottomVisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

struct TimelineClarificationPrompt: Identifiable {
    let id: String
    let question: String
}

// MARK: - Legacy Thought Track Types (for backward compat with stored events)

/// Single step in a thought track (legacy)
struct ThoughtStep: Identifiable {
    let id: String
    let kind: Kind
    let text: String
    let detail: String?
    let duration: Double?
    let isComplete: Bool
    let timestamp: Date
    
    enum Kind {
        case thinking
        case tool
        case insight
    }
}

/// Completed thought track (legacy)
struct ThoughtTrack: Identifiable {
    let id: String
    let steps: [ThoughtStep]
    let isComplete: Bool
    let summary: String?
    let totalDuration: Double
}

// MARK: - Timeline Item Types
private enum TimelineItemKind {
    case userMessage(text: String)
    case thoughtTrack(ThoughtTrack)           // Completed thought track (expandable)
    case liveThoughtTrack([ThoughtStep])      // In-progress thought track
    case thinkingBubble                       // Live ThinkingBubble (Gemini-style)
    case agentResponse(text: String)
    case artifact(CanvasCardModel)
    case clarification(TimelineClarificationPrompt)
    case status(text: String)
    case error(text: String)
}

private struct TimelineItem: Identifiable {
    let id: String
    let timestamp: Date
    let kind: TimelineItemKind
}

// MARK: - Main View
struct WorkspaceTimelineView: View {
    let events: [WorkspaceEvent]
    let embeddedCards: [CanvasCardModel]
    let allCards: [CanvasCardModel]  // All cards including hidden routine-linked ones (for drill-down lookup)
    let syntheticClarification: TimelineClarificationPrompt?
    let answeredClarifications: Set<String>
    let onClarificationSubmit: (String, String, String) -> Void
    let onClarificationSkip: (String, String) -> Void
    var hideThinkingEvents: Bool = false  // Hide old SRE stream when showing new skeleton
    
    // Gemini-style thinking process state (new system)
    @ObservedObject var thinkingState: ThinkingProcessState
    
    // Simplified sticky bottom scroll state
    @State private var shouldAutoScroll = true  // Single switch - disabled when user scrolls up
    @State private var lastScrollTime: Date = .distantPast
    @State private var lastScrolledItemCount: Int = 0  // Track items to detect changes
    @State private var responses: [String: String] = [:]
    @State private var collapsedTools = true
    
    typealias ClarificationPrompt = TimelineClarificationPrompt
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    workspaceHeader
                    
                    // Synthetic clarification at top if pending
                    if let syntheticClarification,
                       !answeredClarifications.contains(syntheticClarification.id) {
                        clarificationBubble(for: syntheticClarification)
                            .id(syntheticClarification.id + "-synthetic")
                            .padding(.bottom, Space.md)
                    }
                    
                    // Timeline items - using VStack not LazyVStack for reliable height
                    ForEach(timelineItems) { item in
                        timelineItemView(for: item)
                            .id(item.id)
                    }
                    
                    // Bottom anchor for scroll target
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xxl)
            }
            .background(Color.bg)
            .onAppear {
                // Initial scroll to bottom
                scrollToBottom(proxy: proxy, animated: false)
            }
            // STICKY BOTTOM: Scroll when event count changes
            .onChange(of: events.count) { _, _ in
                guard shouldAutoScroll else { return }
                // Small delay to allow SwiftUI to render
                scrollToBottom(proxy: proxy, animated: true)
            }
            // STICKY BOTTOM: Scroll when card count changes  
            .onChange(of: embeddedCards.count) { _, _ in
                guard shouldAutoScroll else { return }
                scrollToBottom(proxy: proxy, animated: true)
            }
            // STICKY BOTTOM: Scroll when last event ID changes (for in-place updates)
            .onChange(of: events.last?.id) { _, _ in
                guard shouldAutoScroll else { return }
                scrollToBottom(proxy: proxy, animated: true)
            }
            // STICKY BOTTOM: Scroll when last card ID changes
            .onChange(of: embeddedCards.last?.id) { _, _ in
                guard shouldAutoScroll else { return }
                scrollToBottom(proxy: proxy, animated: true)
            }
            // STICKY BOTTOM: Also scroll when timeline items change (catches synthesized events)
            .onChange(of: timelineItems.count) { _, newCount in
                guard shouldAutoScroll else { return }
                // Only scroll if count actually increased
                if newCount > lastScrolledItemCount {
                    lastScrolledItemCount = newCount
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
            // Re-enable auto-scroll when new streaming starts
            .onChange(of: hasActiveThinking) { _, isActive in
                if isActive {
                    shouldAutoScroll = true
                    lastScrolledItemCount = 0  // Reset so we scroll on new items
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
            // HIGH-FREQUENCY SCROLL: Also trigger on any event timestamp change
            .onChange(of: events.last?.createdAt) { _, _ in
                guard shouldAutoScroll else { return }
                scrollToBottom(proxy: proxy, animated: true)
            }
            // Detect user scrolling up to disable auto-scroll
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        // Scrolling UP (positive translation.height) = user wants to look at history
                        if value.translation.height > 20 {
                            shouldAutoScroll = false
                            lastScrollTime = Date()
                        }
                        // Scrolling DOWN aggressively = user wants to go back to bottom
                        else if value.translation.height < -40 {
                            shouldAutoScroll = true
                        }
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                if !shouldAutoScroll {
                    jumpToLatestButton(proxy: proxy)
                }
            }
        }
    }
    
    // MARK: - Scroll to Bottom
    
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        // Use a short delay to ensure content is rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }
    
    // MARK: - Header
    private var workspaceHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Conversation")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color.textPrimary)
                Text("Your AI coaching session")
                    .font(.system(size: 13))
                    .foregroundColor(Color.textSecondary)
            }
            Spacer()
            if hasActiveThinking {
                thinkingIndicator
            }
        }
        .padding(.vertical, Space.md)
    }
    
    private var hasActiveThinking: Bool {
        // Check if stream is done (no active thinking if done event exists)
        let hasDone = events.contains { $0.event.eventType == .done }
        if hasDone { return false }
        
        // Check if last few events indicate active work
        let recentEvents = events.suffix(5)
        let hasRecentToolStart = recentEvents.contains { $0.event.eventType == .toolStart }
        let hasRecentCompletion = recentEvents.contains {
            $0.event.eventType == .toolEnd ||
            $0.event.eventType == .done
        }

        return hasRecentToolStart && !hasRecentCompletion
    }
    
    private var thinkingIndicator: some View {
        HStack(spacing: Space.xs) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Working...")
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .background(Color.surface.opacity(0.8))
        .clipShape(Capsule())
    }
    
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            // Re-enable auto-scroll and scroll to bottom
            shouldAutoScroll = true
            scrollToBottom(proxy: proxy, animated: true)
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "arrow.down")
                Text("Latest")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.textInverse)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(Color.accent)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
        .padding(Space.md)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    
    // MARK: - Timeline Item View
    @ViewBuilder
    private func timelineItemView(for item: TimelineItem) -> some View {
        switch item.kind {
        case .userMessage(let text):
            userMessageBubble(text: text, timestamp: item.timestamp)
        case .thoughtTrack, .liveThoughtTrack:
            // Legacy thought tracks - now hidden, using ThinkingBubble instead
            EmptyView()
        case .thinkingBubble:
            // Gemini-style thinking bubble (inline after user message)
            ThinkingBubble(state: thinkingState)
        case .agentResponse(let text):
            agentResponseBubble(text: text, timestamp: item.timestamp)
        case .artifact(let card):
            artifactCard(for: card)
        case .clarification(let prompt):
            if !answeredClarifications.contains(prompt.id) {
                clarificationBubble(for: prompt)
            }
        case .status(let text):
            statusRow(text: text)
        case .error(let text):
            errorRow(text: text)
        }
    }
    
    // MARK: - User Message
    private func userMessageBubble(text: String, timestamp: Date) -> some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: Space.xxs) {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(.textInverse)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .clipShape(BubbleShape(isUser: true))
                
                Text(Self.timeFormatter.string(from: timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary.opacity(0.6))
            }
        }
        .padding(.vertical, Space.sm)
    }
    
    // MARK: - Agent Response
    private func agentResponseBubble(text: String, timestamp: Date) -> some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .foregroundColor(Color.accent)
                    Text("Coach")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.textSecondary)
                }
                
                // Render markdown (bold, italic, bullets)
                markdownText(text)
                    .font(.system(size: 15))
                    .foregroundColor(Color.textPrimary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                
                Text(Self.timeFormatter.string(from: timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary.opacity(0.6))
            }
            Spacer(minLength: 60)
        }
        .padding(.vertical, Space.sm)
    }
    
    // MARK: - Markdown Rendering
    @ViewBuilder
    private func markdownText(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
    
    // MARK: - Thinking Row (Subtle)
    private func thinkingRow(text: String, duration: Double?) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary.opacity(0.6))
            
            if let duration {
                Text(String(format: "Thought for %.1fs", duration))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.textSecondary)
            } else {
                HStack(spacing: Space.xs) {
                    Text(text.isEmpty ? "Thinking..." : text)
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.leading, Space.sm)
    }
    
    // MARK: - Tool Activity Row (Collapsible)
    private func toolActivityRow(name: String, result: String?, duration: Double?) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: result != nil ? "checkmark.circle.fill" : "gearshape")
                .font(.system(size: 12))
                .foregroundColor(result != nil ? .green.opacity(0.7) : Color.textSecondary.opacity(0.5))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(humanReadableToolName(name))
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary)
                if let result, !result.isEmpty {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundColor(Color.textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let duration {
                Text(String(format: "%.1fs", duration))
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary.opacity(0.5))
            }
        }
        .padding(.vertical, Space.xxs)
        .padding(.horizontal, Space.sm)
        .background(Color.surface.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.leading, Space.lg)
    }
    
    // MARK: - Artifact Card (Full Width, Prominent)
    private func artifactCard(for card: CanvasCardModel) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // Artifact label
            HStack(spacing: Space.xs) {
                Image(systemName: artifactIcon(for: card))
                    .font(.system(size: 12))
                    .foregroundColor(Color.accent)
                Text(artifactLabel(for: card))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.accent)
            }
            .padding(.leading, Space.xs)
            
            // The actual card
            cardView(for: card)
        }
        .padding(.vertical, Space.md)
    }
    
    private func artifactIcon(for card: CanvasCardModel) -> String {
        switch card.data {
        case .sessionPlan: return "figure.strengthtraining.traditional"
        case .routineSummary: return "calendar.badge.clock"
        case .visualization: return "chart.bar"
        case .list: return "list.bullet"
        case .agentStream: return "brain"
        case .routineOverview: return "calendar"
        default: return "doc.text"
        }
    }
    
    private func artifactLabel(for card: CanvasCardModel) -> String {
        switch card.data {
        case .sessionPlan: return "Workout Plan"
        case .routineSummary: return "Training Program"
        case .visualization: return "Analysis"
        case .analysisSummary: return "Progress Insights"
        case .list: return "Recommendations"
        case .inlineInfo: return "Note"
        case .agentStream: return "Processing"
        case .routineOverview: return "Routine"
        default: return "Update"
        }
    }
    
    // MARK: - Clarification Bubble
    private func clarificationBubble(for prompt: TimelineClarificationPrompt) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(Color.accent)
                Text("Coach needs input")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.accent)
            }
            
            Text(prompt.question)
                .font(.system(size: 15))
                .foregroundColor(Color.textPrimary)
            
            TextField("Type your answer…", text: Binding(
                get: { responses[prompt.id] ?? "" },
                set: { responses[prompt.id] = $0 }
            ))
            .font(.system(size: 15))
            .padding(Space.sm)
            .background(Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            HStack(spacing: Space.md) {
                Button {
                    responses[prompt.id] = ""
                    onClarificationSkip(prompt.id, prompt.question)
                } label: {
                    Text("Skip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.textSecondary)
                }
                
                Spacer()
                
                Button {
                    let answer = responses[prompt.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !answer.isEmpty else { return }
                    responses[prompt.id] = ""
                    onClarificationSubmit(prompt.id, prompt.question, answer)
                } label: {
                    HStack(spacing: Space.xs) {
                        Text("Reply")
                        Image(systemName: "paperplane.fill")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textInverse)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(
                        (responses[prompt.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        ? Color.textSecondary
                        : Color.accent
                    )
                    .clipShape(Capsule())
                }
                .disabled((responses[prompt.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
            }
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.medium, style: .continuous)
                .stroke(Color.accent.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, Space.sm)
    }
    
    // MARK: - Status Row
    private func statusRow(text: String) -> some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(Color.accent.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
        }
        .padding(.vertical, Space.xxs)
        .frame(maxWidth: .infinity, alignment: .center)
    }
    
    // MARK: - Error Row
    private func errorRow(text: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.red)
        }
        .padding(Space.sm)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, Space.xs)
    }
    
    // MARK: - Card View
    @ViewBuilder
    private func cardView(for card: CanvasCardModel) -> some View {
        switch card.data {
        case .sessionPlan:
            SessionPlanCard(model: card)
        case .routineSummary(let data):
            // Pass ALL cards to environment so RoutineSummaryCard can look up linked session_plans
            RoutineSummaryCard(model: card, data: data)
                .environment(\.canvasCards, allCards)
        case .analysisSummary(let data):
            AnalysisSummaryCard(model: card, data: data)
        case .visualization(let spec):
            VisualizationCard(spec: spec, cardId: card.id, actions: card.actions)
        case .inlineInfo(let text):
            CardContainer(status: card.status) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    CardHeader(title: card.title ?? "Info", subtitle: card.subtitle, lane: card.lane, status: card.status, timestamp: card.publishedAt)
                    PovverText(text, style: .body)
                }
            }
        default:
            CardContainer(status: card.status) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    CardHeader(title: card.title ?? "Update", subtitle: card.subtitle, lane: card.lane, status: card.status, timestamp: card.publishedAt)
                    if let detail = detailText(for: card) {
                        PovverText(detail, style: .body, color: Color.textSecondary)
                    } else {
                        PovverText("New information available.", style: .body, color: Color.textSecondary)
                    }
                }
            }
        }
    }
    
    private func detailText(for card: CanvasCardModel) -> String? {
        switch card.data {
        case .text(let text): return text
        case .inlineInfo(let text): return text
        case .suggestion(let title, let rationale): return rationale ?? title
        case .agentMessage(let message): return message.message
        default: return nil
        }
    }
    
    // MARK: - Timeline Items Builder
    private var timelineItems: [TimelineItem] {
        var items: [TimelineItem] = []
        var lastUserMessageTimestamp: Date?
        
        // Process events
        let sortedEvents = renderedEvents
        for entry in sortedEvents {
            guard let kind = mapEventToKind(entry) else { continue }
            
            // Track last user message timestamp
            if case .userMessage = kind {
                lastUserMessageTimestamp = entry.createdAt
            }
            
            items.append(TimelineItem(
                id: "event-\(entry.id)",
                timestamp: entry.createdAt ?? Date.distantPast,
                kind: kind
            ))
        }
        
        // Process cards as artifacts
        for card in embeddedCards {
            items.append(TimelineItem(
                id: "card-\(card.id)",
                timestamp: card.publishedAt ?? Date(),
                kind: .artifact(card)
            ))
        }
        
        // Sort by timestamp
        var sortedItems = items.sorted { $0.timestamp < $1.timestamp }
        
        // Insert ThinkingBubble after the last user message when thinking is active or complete
        if thinkingState.isActive || thinkingState.isComplete {
            // Find the index of the last user message
            if let lastUserIndex = sortedItems.lastIndex(where: {
                if case .userMessage = $0.kind { return true }
                return false
            }) {
                // Insert thinking bubble right after the last user message
                let thinkingTimestamp = lastUserMessageTimestamp?.addingTimeInterval(0.001) ?? Date()
                let thinkingItem = TimelineItem(
                    id: "thinking-bubble-\(thinkingState.sessionId)",
                    timestamp: thinkingTimestamp,
                    kind: .thinkingBubble
                )
                sortedItems.insert(thinkingItem, at: lastUserIndex + 1)
            }
        }
        
        return sortedItems
    }
    
    private func mapEventToKind(_ entry: WorkspaceEvent) -> TimelineItemKind? {
        let eventType = entry.event.type
        
        // User messages (legacy types that don't map to new enum)
        if entry.event.type == "user_prompt" || entry.event.type == "user_response" {
            let text = entry.event.content?["text"]?.value as? String ?? ""
            return .userMessage(text: text)
        }

        // Handle synthetic thought_track / thinking_track events
        if eventType == "thought_track" || eventType == "thinking_track" {
            let isInProgress = entry.event.content?["is_in_progress"]?.value as? Bool ?? (eventType == "thinking_track")
            let summary = entry.event.content?["summary"]?.value as? String
            let totalDuration = entry.event.content?["total_duration"]?.value as? Double ?? 0
            let timestamp = entry.createdAt ?? Date()
            
            // Parse steps from content
            var steps: [ThoughtStep] = []
            if let stepsData = entry.event.content?["steps"]?.value as? [[String: Any]] {
                for stepData in stepsData {
                    let id = stepData["id"] as? String ?? UUID().uuidString
                    let text = stepData["text"] as? String ?? "Step"
                    let duration = stepData["duration"] as? Double
                    let isComplete = stepData["isComplete"] as? Bool ?? true
                    
                    steps.append(ThoughtStep(
                        id: id,
                        kind: text.contains("→") ? .tool : .thinking,
                        text: text,
                        detail: nil,
                        duration: duration,
                        isComplete: isComplete,
                        timestamp: timestamp
                    ))
                }
            }
            
            // Fallback if no steps parsed
            if steps.isEmpty {
                steps.append(ThoughtStep(
                    id: entry.id,
                    kind: .thinking,
                    text: isInProgress ? "Working..." : (summary ?? "Done"),
                    detail: nil,
                    duration: isInProgress ? nil : totalDuration,
                    isComplete: !isInProgress,
                    timestamp: timestamp
                ))
            }
            
            if isInProgress {
                return .liveThoughtTrack(steps)
            } else {
                let track = ThoughtTrack(
                    id: entry.id,
                    steps: steps,
                    isComplete: true,
                    summary: summary,
                    totalDuration: totalDuration
                )
                return .thoughtTrack(track)
            }
        }
        
        // Legacy thinking/thought handling (for backward compat with old events)
        switch entry.event.eventType {
        case .toolStart:
            // tool_start events are handled in renderedEvents as AgentStep grouping
            return nil

        case .toolEnd:
            // tool_end events are handled in renderedEvents as AgentStep grouping
            return nil

        case .message:
            let text = entry.event.content?["text"]?.value as? String ?? ""
            guard !text.isEmpty else { return nil }
            return .agentResponse(text: text)
            
        case .clarification:
            guard let id = entry.event.content?["id"]?.value as? String,
                  let question = entry.event.content?["question"]?.value as? String else { return nil }
            return .clarification(TimelineClarificationPrompt(id: id, question: question))
            
        case .status:
            let text = entry.event.content?["text"]?.value as? String ?? entry.event.displayText
            return .status(text: text)
            
        case .error:
            let text = entry.event.content?["text"]?.value as? String ?? entry.event.displayText
            return .error(text: text)
            
        default:
            return nil
        }
    }
    
    private var renderedEvents: [WorkspaceEvent] {
        var result: [WorkspaceEvent] = []
        var activeSteps: [AgentStep] = []
        var sessionStartTime: Double?
        
        let sortedEntries = events.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) })
        
        for entry in sortedEntries {
            let eventType = entry.event.eventType
            let ts = entry.event.timestamp ?? entry.createdAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            
            // Skip heartbeats
            if eventType == .heartbeat {
                continue
            }
            
            // User messages - flush any pending thought track and add
            // (user_prompt / user_response are legacy type strings that won't match new enum,
            //  so also check the raw type string)
            let isUserMsg = entry.event.type == "user_prompt" || entry.event.type == "user_response"
            if isUserMsg {
                // Flush pending steps as completed track
                if !activeSteps.isEmpty {
                    let trackEvent = createStepTrackEvent(steps: activeSteps, isComplete: true, timestamp: entry.createdAt)
                    result.append(trackEvent)
                    activeSteps = []
                    sessionStartTime = nil
                }
                
                // Deduplicate consecutive identical text
                if let last = result.last,
                   normalizedText(for: entry) == normalizedText(for: last),
                   last.event.agent == entry.event.agent {
                    continue
                }
                result.append(entry)
                continue
            }
            
            // Thinking start / tool_start - add step
            if eventType == .toolStart || entry.event.type == "thinking" {
                if sessionStartTime == nil {
                    sessionStartTime = ts
                }
                let text = entry.event.content?["text"]?.value as? String ?? "Thinking"
                let intent = extractIntent(from: text)
                activeSteps.append(AgentStep(
                    id: entry.id,
                    kind: .thinking,
                    label: intent,
                    detail: nil,
                    startTime: ts,
                    endTime: nil,
                    isComplete: false
                ))
                continue
            }
            
            // Thought complete (legacy) - close the last thinking step
            if entry.event.type == "thought" {
                if let idx = activeSteps.lastIndex(where: { $0.kind == .thinking && !$0.isComplete }) {
                    let duration = ts - activeSteps[idx].startTime
                    let resultText = entry.event.content?["text"]?.value as? String
                    activeSteps[idx] = AgentStep(
                        id: activeSteps[idx].id,
                        kind: .thinking,
                        label: activeSteps[idx].label,
                        detail: resultText != nil && !resultText!.isEmpty ? "Thought for \(String(format: "%.1f", duration))s" : nil,
                        startTime: activeSteps[idx].startTime,
                        endTime: ts,
                        isComplete: true
                    )
                }
                continue
            }
            
            // Tool start - add tool step
            if eventType == .toolStart || entry.event.type == "toolRunning" {
                if sessionStartTime == nil {
                    sessionStartTime = ts
                }
                let toolName = entry.event.content?["tool"]?.value as? String 
                    ?? entry.event.content?["tool_name"]?.value as? String 
                    ?? "tool"
                let intent = entry.event.content?["intent"]?.value as? String
                let args = entry.event.content?["args"]?.value
                
                // Build label with search query if available
                var label = intent ?? humanReadableToolName(toolName)
                if let argsDetail = extractToolArgsForDisplay(toolName, args: args) {
                    label = "\(humanReadableToolName(toolName)) \(argsDetail)"
                }
                
                activeSteps.append(AgentStep(
                    id: entry.id,
                    kind: .tool(name: toolName),
                    label: label,
                    detail: nil,
                    startTime: ts,
                    endTime: nil,
                    isComplete: false
                ))
                continue
            }
            
            // Tool end - update the tool step with result
            if eventType == .toolEnd || entry.event.type == "toolComplete" {
                let toolName = entry.event.content?["tool"]?.value as? String ?? "tool"
                if let idx = activeSteps.lastIndex(where: {
                    if case .tool(let name) = $0.kind, name == toolName, !$0.isComplete {
                        return true
                    }
                    return false
                }) {
                    let duration = ts - activeSteps[idx].startTime
                    let result = extractToolResult(entry.event.content)
                    activeSteps[idx] = AgentStep(
                        id: activeSteps[idx].id,
                        kind: activeSteps[idx].kind,
                        label: activeSteps[idx].label,
                        detail: result,
                        startTime: activeSteps[idx].startTime,
                        endTime: ts,
                        isComplete: true,
                        duration: duration
                    )
                }
                continue
            }
            
            // Agent response - flush steps and merge consecutive responses.
            // Backend emits two persisted event types per agent turn:
            //   - type "message" (text_delta): incremental streaming chunks
            //   - type "agentResponse" (text_commit): authoritative sentence-boundary commits
            // Both get persisted as workspace_entries. Without merging, each renders
            // as a separate chat bubble. We merge them into a single entry here.
            if eventType == .message || entry.event.type == "agentResponse" {
                let text = entry.event.content?["text"]?.value as? String ?? ""
                guard !text.isEmpty else { continue }
                let isDelta = eventType == .message

                // Flush pending steps as completed track
                if !activeSteps.isEmpty {
                    let trackEvent = createStepTrackEvent(steps: activeSteps, isComplete: true, timestamp: entry.createdAt)
                    result.append(trackEvent)
                    activeSteps = []
                    sessionStartTime = nil
                }

                // Merge with previous agent response if consecutive
                if let lastIdx = result.indices.last,
                   let lastType = result[lastIdx].event.eventType,
                   lastType == .message {
                    let existingText = result[lastIdx].event.content?["text"]?.value as? String ?? ""
                    let prevIsDelta = lastType == .message

                    let mergedText: String
                    if isDelta {
                        // Incoming is a text_delta chunk — concatenate directly (no separator)
                        mergedText = existingText + text
                    } else {
                        // Incoming is a text_commit (authoritative segment).
                        // If accumulated text already contains this commit, skip it.
                        if existingText.contains(text) {
                            continue
                        }
                        if prevIsDelta {
                            // Prior entries were deltas; the commit is the authoritative
                            // version of text that was already streamed as deltas.
                            // Check if existing delta text is a prefix of the commit.
                            let trimmedExisting = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedCommit = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmedCommit.hasPrefix(trimmedExisting) || trimmedExisting.hasPrefix(trimmedCommit) {
                                // Commit supersedes deltas — use the longer of the two
                                mergedText = trimmedCommit.count >= trimmedExisting.count ? text : existingText
                            } else {
                                // Deltas and commit diverged (multi-segment), concatenate
                                mergedText = existingText + text
                            }
                        } else {
                            // Commit after commit — distinct segments, separate with newlines
                            mergedText = existingText + "\n\n" + text
                        }
                    }

                    // Replace with merged event (keep agentResponse type for display)
                    let mergedContent: [String: AnyCodable] = [
                        "text": AnyCodable(mergedText)
                    ]
                    let mergedStreamEvent = StreamEvent(
                        type: isDelta ? result[lastIdx].event.type : "message",
                        agent: result[lastIdx].event.agent,
                        content: mergedContent,
                        timestamp: result[lastIdx].event.timestamp,
                        metadata: result[lastIdx].event.metadata
                    )
                    result[lastIdx] = WorkspaceEvent(
                        id: result[lastIdx].id,
                        event: mergedStreamEvent,
                        createdAt: result[lastIdx].createdAt
                    )
                    continue
                }

                result.append(entry)
                continue
            }
            
            // Clarification
            if eventType == .clarification {
                if !activeSteps.isEmpty {
                    let trackEvent = createStepTrackEvent(steps: activeSteps, isComplete: true, timestamp: entry.createdAt)
                    result.append(trackEvent)
                    activeSteps = []
                    sessionStartTime = nil
                }
                result.append(entry)
                continue
            }
            
            // Status events
            if eventType == .status {
                // Add as a step in the current track
                let text = entry.event.content?["text"]?.value as? String ?? entry.event.displayText
                activeSteps.append(AgentStep(
                    id: entry.id,
                    kind: .status,
                    label: text,
                    detail: nil,
                    startTime: ts,
                    endTime: ts,
                    isComplete: true
                ))
                continue
            }
            
            // Error events
            if eventType == .error {
                result.append(entry)
                continue
            }
        }
        
        // Check if stream is complete
        let hasDoneEvent = events.contains { $0.event.eventType == .done }
        
        // Flush remaining steps - mark all as complete if done
        if !activeSteps.isEmpty {
            // If done, mark all incomplete steps as complete
            let finalSteps: [AgentStep]
            if hasDoneEvent {
                finalSteps = activeSteps.map { step in
                    if step.isComplete {
                        return step
                    }
                    // Mark incomplete step as complete
                    return AgentStep(
                        id: step.id,
                        kind: step.kind,
                        label: step.label,
                        detail: step.detail ?? "Complete",
                        startTime: step.startTime,
                        endTime: step.endTime ?? Date().timeIntervalSince1970,
                        isComplete: true,
                        duration: step.duration ?? 0.1  // Small duration for steps that completed instantly
                    )
                }
            } else {
                finalSteps = activeSteps
            }
            
            let trackEvent = createStepTrackEvent(
                steps: finalSteps,
                isComplete: hasDoneEvent,
                timestamp: sortedEntries.last?.createdAt
            )
            result.append(trackEvent)
        }
        
        return result
    }
    
    // MARK: - Agent Step Model
    
    private struct AgentStep {
        let id: String
        let kind: StepKind
        let label: String
        let detail: String?
        let startTime: Double
        let endTime: Double?
        let isComplete: Bool
        var duration: Double?
        
        enum StepKind: Equatable {
            case thinking
            case tool(name: String)
            case status
            case publishing
        }
        
        init(id: String, kind: StepKind, label: String, detail: String?, startTime: Double, endTime: Double?, isComplete: Bool, duration: Double? = nil) {
            self.id = id
            self.kind = kind
            self.label = label
            self.detail = detail
            self.startTime = startTime
            self.endTime = endTime
            self.isComplete = isComplete
            self.duration = duration ?? (endTime.map { $0 - startTime })
        }
    }
    
    private func extractIntent(from text: String) -> String {
        // Extract semantic intent from thinking text
        let lower = text.lowercased()
        if lower.contains("planning") || lower.contains("plan") {
            return "Planning approach"
        } else if lower.contains("analyzing") || lower.contains("review") {
            return "Thinking about next steps"
        } else if lower.contains("search") {
            return "Preparing search"
        } else if lower.contains("creating") || lower.contains("building") {
            return "Building workout"
        } else if lower.contains("routine") {
            return "Designing routine"
        } else if !text.isEmpty && text.count < 50 {
            return text
        }
        return "Thinking"
    }
    
    /// Extract search args for display (e.g., "with split=upper")
    private func extractToolArgsForDisplay(_ toolName: String, args: Any?) -> String? {
        guard let args = args else { return nil }
        
        // Handle search_exercises tool
        if toolName.contains("search") || toolName.contains("exercise") {
            var parts: [String] = []
            
            if let dict = args as? [String: Any] {
                if let split = dict["split"] as? String { parts.append("split=\(split)") }
                if let muscle = dict["muscle_group"] as? String { parts.append("muscle=\(muscle)") }
                if let movement = dict["movement_type"] as? String { parts.append("movement=\(movement)") }
                if let category = dict["category"] as? String { parts.append("category=\(category)") }
                if let query = dict["query"] as? String { parts.append("query=\"\(query)\"") }
            }
            
            if !parts.isEmpty {
                return "with \(parts.joined(separator: ", "))"
            }
        }
        
        return nil
    }
    
    private func extractToolResult(_ content: [String: AnyCodable]?) -> String? {
        guard let content = content else { return nil }
        
        // Check for specific result patterns
        if let count = content["result_count"]?.value as? Int {
            let tool = content["tool"]?.value as? String ?? ""
            if tool.contains("exercise") || tool.contains("search") {
                return "Found \(count) exercises"
            }
            return "Found \(count) items"
        }
        
        // Try to parse result array/dict for exercise count
        if let result = content["result"]?.value {
            // If it's an array, count items
            if let arr = result as? [Any] {
                let tool = content["tool"]?.value as? String ?? ""
                if tool.contains("exercise") || tool.contains("search") {
                    return "Found \(arr.count) exercises"
                }
                return "Found \(arr.count) items"
            }
            
            // If it's a dict with items array
            if let dict = result as? [String: Any], let items = dict["items"] as? [Any] {
                let tool = content["tool"]?.value as? String ?? ""
                if tool.contains("exercise") || tool.contains("search") {
                    return "Found \(items.count) exercises"
                }
                return "Found \(items.count) items"
            }
            
            // If it's a string
            if let str = result as? String, !str.isEmpty {
                // Truncate long results
                if str.count > 60 {
                    return String(str.prefix(57)) + "..."
                }
                return str
            }
        }
        
        if let summary = content["summary"]?.value as? String, !summary.isEmpty {
            return summary
        }
        
        return nil
    }
    
    private func createStepTrackEvent(steps: [AgentStep], isComplete: Bool, timestamp: Date?) -> WorkspaceEvent {
        var thoughtSteps: [ThoughtStep] = []
        var totalDuration: Double = 0
        
        for step in steps {
            let stepKind: ThoughtStep.Kind
            switch step.kind {
            case .thinking: stepKind = .thinking
            case .tool: stepKind = .tool
            case .status: stepKind = .insight
            case .publishing: stepKind = .tool
            }
            
            let duration = step.duration
            if let d = duration {
                totalDuration += d
            }
            
            // Format the display text with result
            var displayLabel = step.label
            if let detail = step.detail, !detail.isEmpty {
                displayLabel = "\(step.label) → \(detail)"
            }
            
            thoughtSteps.append(ThoughtStep(
                id: step.id,
                kind: stepKind,
                text: displayLabel,
                detail: nil,
                duration: duration,
                isComplete: step.isComplete,
                timestamp: Date(timeIntervalSince1970: step.startTime)
            ))
        }
        
        // Build summary for collapsed view
        let summary = buildTrackSummary(steps: steps, totalDuration: totalDuration)
        
        let content: [String: AnyCodable] = [
            "steps": AnyCodable(thoughtSteps.map { ["id": $0.id, "text": $0.text, "duration": $0.duration ?? 0, "isComplete": $0.isComplete] }),
            "summary": AnyCodable(summary),
            "total_duration": AnyCodable(totalDuration),
            "is_in_progress": AnyCodable(!isComplete)
        ]
        
        let streamEvent = StreamEvent(
            type: isComplete ? "thought_track" : "thinking_track",
            agent: "orchestrator",
            content: content,
            timestamp: timestamp?.timeIntervalSince1970,
            metadata: nil
        )
        
        return WorkspaceEvent(id: UUID().uuidString, event: streamEvent, createdAt: timestamp)
    }
    
    private func buildTrackSummary(steps: [AgentStep], totalDuration: Double) -> String {
        // Find the most meaningful completed action
        let meaningfulSteps = steps.filter { step in
            if case .tool(let name) = step.kind {
                return name.contains("propose") || name.contains("publish") || name.contains("workout") || name.contains("routine")
            }
            return false
        }
        
        if let lastMeaningful = meaningfulSteps.last {
            if lastMeaningful.label.lowercased().contains("routine") {
                return String(format: "Crafted routine (%.1fs)", totalDuration)
            } else {
                return String(format: "Crafted workout (%.1fs)", totalDuration)
            }
        }
        
        // Fallback to tool count summary
        let toolCount = steps.filter { if case .tool = $0.kind { return true }; return false }.count
        if toolCount > 0 {
            return String(format: "Completed %d steps (%.1fs)", toolCount, totalDuration)
        }
        
        return String(format: "Thought for %.1fs", totalDuration)
    }
    
    private func createThinkingSummary(duration: Double, tools: [String], timestamp: Date?, isInProgress: Bool = false) -> WorkspaceEvent {
        var parts: [String] = []
        
        if duration > 0.5 {
            parts.append(String(format: "Thought for %.1fs", duration))
        }
        
        let humanReadableTools = tools.map { humanReadableToolName($0) }
        if !humanReadableTools.isEmpty {
            parts.append(contentsOf: humanReadableTools)
        }
        
        let text = parts.isEmpty ? (isInProgress ? "Working..." : "Done") : parts.joined(separator: " • ")
        
        let content: [String: AnyCodable] = [
            "text": AnyCodable(text),
            "duration_s": AnyCodable(duration),
            "tools": AnyCodable(tools),
            "is_in_progress": AnyCodable(isInProgress)
        ]
        
        let streamEvent = StreamEvent(
            type: isInProgress ? "thinking" : "thought",
            agent: "orchestrator",
            content: content,
            timestamp: timestamp?.timeIntervalSince1970,
            metadata: nil
        )
        
        return WorkspaceEvent(id: UUID().uuidString, event: streamEvent, createdAt: timestamp)
    }
    
    private func normalizedText(for entry: WorkspaceEvent) -> String? {
        if let text = entry.event.content?["text"]?.value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return entry.event.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    
    private func synthesizeThought(thinking: WorkspaceEvent, thought: WorkspaceEvent) -> WorkspaceEvent {
        let start = (thinking.event.metadata?["start_time"]?.value as? Double)
            ?? (thought.event.metadata?["start_time"]?.value as? Double)
            ?? (thinking.event.timestamp ?? Date().timeIntervalSince1970)
        let end = thought.event.timestamp ?? Date().timeIntervalSince1970
        let duration = max(end - start, 0)
        let streamEvent = StreamEvent(
            type: "thought",
            agent: thought.event.agent,
            content: [
                "text": AnyCodable(String(format: "Thought for %.1fs", duration)),
                "duration_s": AnyCodable(duration)
            ],
            timestamp: thought.event.timestamp,
            metadata: thought.event.metadata
        )
        return WorkspaceEvent(id: UUID().uuidString, event: streamEvent, createdAt: thought.createdAt)
    }
    
    private func humanReadableToolName(_ name: String) -> String {
        switch name {
        // Multi-agent routing tools
        case "tool_echo_routing": return "Understanding query"
        case "tool_route_to_agent": return "Understanding query"
        // New unified agent tools
        case "tool_set_context": return "Setting up"
        case "tool_search_exercises": return "Searching exercises"
        case "tool_get_user_profile", "tool_fetch_profile": return "Reviewing profile"
        case "tool_get_recent_workouts", "tool_fetch_recent_sessions": return "Checking history"
        case "tool_ask_user", "tool_request_clarification": return "Asking question"
        case "tool_create_workout_plan": return "Creating plan"
        case "tool_publish_workout_plan", "tool_publish_cards": return "Publishing plan"
        case "tool_record_user_info": return "Recording info"
        case "tool_emit_status", "tool_emit_agent_event": return "Logging"
        case "tool_send_message": return "Sending message"
        // Legacy tools
        case "tool_set_canvas_context": return "Setting context"
        case "tool_format_workout_plan_cards": return "Formatting plan"
        case "tool_format_analysis_cards": return "Formatting analysis"
        case "get_user_workouts": return "Loading workout history"
        case "get_user_routines": return "Loading routines"
        case "list_exercises", "search_exercises": return "Searching exercises"
        case "get_user_templates": return "Loading templates"
        case "get_active_workout": return "Checking active workout"
        default: return name.replacingOccurrences(of: "tool_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Bubble Shape
private struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        var path = Path()
        
        if isUser {
            // User bubble - rounded with slight tail on right
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        } else {
            // Agent bubble - rounded with slight tail on left
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
        
        return path
    }
}

// MARK: - Preview
#if DEBUG
struct WorkspaceTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        WorkspaceTimelineView(
            events: [],
            embeddedCards: [],
            allCards: [],
            syntheticClarification: TimelineClarificationPrompt(id: "test", question: "What muscle groups do you want to focus on?"),
            answeredClarifications: [],
            onClarificationSubmit: { _, _, _ in },
            onClarificationSkip: { _, _ in },
            hideThinkingEvents: true,
            thinkingState: ThinkingProcessState()
        )
        .previewLayout(.sizeThatFits)
    }
}
#endif
