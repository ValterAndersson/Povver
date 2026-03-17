import Foundation
import Combine
import SwiftUI

// =============================================================================
// MARK: - ThinkingProcessState.swift - Gemini-Style Thought Process
// =============================================================================
//
// PURPOSE:
// Unified state management for the agent's thinking process, replacing the
// fragmented ThoughtTrackView, StreamOverlay, and AgentProgressState.
//
// DESIGN PRINCIPLES:
// 1. ONE STATE - Single source of truth for thinking UI
// 2. GROUPED STEPS - Multiple tools grouped into "Gathering information"
// 3. COLLAPSED BY DEFAULT - One line, expandable on tap
// 4. LIVE PROGRESS - Elapsed timer and step counter while active
//
// USAGE:
//   @StateObject private var thinkingState = ThinkingProcessState()
//   thinkingState.handleEvent(event)  // Called from ConversationViewModel
//   ThinkingBubble(state: thinkingState)  // Used in UI
//
// =============================================================================

// MARK: - Thinking Step Model

/// A single tool call result for history tracking
public struct ToolResult: Identifiable, Equatable {
    public let id: String
    public let tool: String
    public let displayName: String
    public var result: String?
    public var durationMs: Int?
    public var isComplete: Bool
    
    public init(id: String = UUID().uuidString, tool: String, displayName: String, result: String? = nil, durationMs: Int? = nil, isComplete: Bool = false) {
        self.id = id
        self.tool = tool
        self.displayName = displayName
        self.result = result
        self.durationMs = durationMs
        self.isComplete = isComplete
    }
}

/// A single step in the thinking process
public struct ThinkingStep: Identifiable, Equatable {
    public let id: String
    public let phase: ThinkingPhase
    public let title: String
    public var detail: String?
    public var status: StepStatus
    public let timestamp: Date
    public var durationMs: Int?
    
    /// All tool calls in this phase (for history display when expanded)
    public var toolResults: [ToolResult] = []
    
    public enum StepStatus: Equatable {
        case pending
        case active
        case complete
        case error(String)
    }
    
    public init(
        id: String = UUID().uuidString,
        phase: ThinkingPhase,
        title: String,
        detail: String? = nil,
        status: StepStatus = .pending,
        timestamp: Date = Date(),
        durationMs: Int? = nil,
        toolResults: [ToolResult] = []
    ) {
        self.id = id
        self.phase = phase
        self.title = title
        self.detail = detail
        self.status = status
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.toolResults = toolResults
    }
    
    /// Duration formatted as string
    public var durationText: String? {
        guard let ms = durationMs else { return nil }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
    
    /// Summary of tool results for collapsed display
    public var toolSummary: String? {
        guard !toolResults.isEmpty else { return nil }
        let completed = toolResults.filter { $0.isComplete }.count
        return "\(completed) of \(toolResults.count) steps"
    }
}

// MARK: - Thinking Phase

/// The major phases of agent work - used for grouping
public enum ThinkingPhase: String, CaseIterable {
    case planning = "Planning approach"
    case gathering = "Gathering information"
    case building = "Building response"
    case finalizing = "Finalizing"
    
    /// SF Symbol for this phase
    public var icon: String {
        switch self {
        case .planning: return "brain"
        case .gathering: return "magnifyingglass"
        case .building: return "hammer"
        case .finalizing: return "checkmark.circle"
        }
    }
    
    /// Derive phase from tool name
    public static func from(toolName: String) -> ThinkingPhase {
        let name = toolName.lowercased()
        
        // Context/search tools → gathering
        if name.contains("context") || name.contains("profile") || 
           name.contains("search") || name.contains("history") ||
           name.contains("workout") || name.contains("template") ||
           name.contains("routine") && !name.contains("propose") {
            return .gathering
        }
        
        // Proposal/creation tools → building
        if name.contains("propose") || name.contains("create") || 
           name.contains("build") || name.contains("format") {
            return .building
        }
        
        // Publish/save tools → finalizing
        if name.contains("publish") || name.contains("save") ||
           name.contains("emit") {
            return .finalizing
        }
        
        return .gathering  // Default
    }
    
    /// Derive phase from pipeline step
    public static func from(pipelineStep: String) -> ThinkingPhase {
        switch pipelineStep.lowercased() {
        case "router", "planner": return .planning
        case "critic": return .finalizing
        default: return .building
        }
    }
}

// MARK: - Thinking Process State

/// Main state object for the thinking process UI
@MainActor
public final class ThinkingProcessState: ObservableObject {
    
    // MARK: - Published State

    /// All steps in the current thinking process
    @Published public private(set) var steps: [ThinkingStep] = []

    /// Current active phase for the header display
    @Published public private(set) var currentPhase: ThinkingPhase = .planning

    /// Whether the process is complete
    @Published public private(set) var isComplete: Bool = false

    /// Whether the bubble is expanded (collapsed by default)
    @Published public var isExpanded: Bool = false

    /// Total duration in milliseconds
    @Published public private(set) var totalDurationMs: Int = 0

    /// Live elapsed seconds while active (ticks every second)
    @Published public private(set) var elapsedSeconds: Int = 0

    /// Expected total steps from planner (nil if planner didn't run, e.g. Fast Lane)
    @Published public private(set) var totalExpectedSteps: Int? = nil

    /// Completed tool steps so far
    @Published public private(set) var completedSteps: Int = 0

    /// Display label of the currently running tool (nil between tools)
    @Published public private(set) var activeDetail: String? = nil

    /// Stable ID for this thinking session — unique per start(), stable within a session.
    /// Used by WorkspaceTimelineView to give the ThinkingBubble a stable SwiftUI identity.
    @Published public private(set) var sessionId: String = UUID().uuidString

    // MARK: - Internal State

    private var startTime: Date?
    private var activeToolStarts: [String: Date] = [:]
    private var toolPhaseMap: [String: ThinkingPhase] = [:]
    private var elapsedTimer: Timer?

    public init() {}
    
    // MARK: - Computed Properties
    
    /// The summary text shown in collapsed state — prefers active tool detail over generic phase
    public var summaryText: String {
        if isComplete {
            return "Thought for \(totalDurationText)"
        }
        if let detail = activeDetail {
            return detail
        }
        return currentPhase.rawValue
    }
    
    /// Duration formatted for display
    public var totalDurationText: String {
        String(format: "%.1fs", Double(totalDurationMs) / 1000.0)
    }
    
    /// Whether there is active work happening
    public var isActive: Bool {
        !isComplete && !steps.isEmpty
    }
    
    /// Whether there are any active steps
    public var hasActiveSteps: Bool {
        steps.contains { $0.status == .active }
    }
    
    // MARK: - Event Handling
    
    /// Handle an incoming stream event
    public func handleEvent(_ event: StreamEvent) {
        guard let eventType = event.eventType else { return }
        
        switch eventType {
        case .toolStart:
            handleToolStart(event)

        case .toolEnd:
            handleToolComplete(event)

        case .done:
            handleDone()

        case .error:
            handleError(event)

        default:
            break
        }
    }
    
    /// Reset for a new request
    public func reset() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        steps = []
        currentPhase = .planning
        isComplete = false
        isExpanded = false
        totalDurationMs = 0
        elapsedSeconds = 0
        totalExpectedSteps = nil
        completedSteps = 0
        activeDetail = nil
        sessionId = UUID().uuidString
        startTime = nil
        activeToolStarts.removeAll()
        toolPhaseMap.removeAll()
    }
    
    /// Start a new thinking process
    public func start() {
        reset()
        startTime = Date()

        // Add initial "Planning approach" step
        steps.append(ThinkingStep(
            phase: .planning,
            title: "Planning approach",
            status: .active
        ))
        currentPhase = .planning

        // Start live elapsed timer (calculates from startTime for accuracy after backgrounding)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startTime, !self.isComplete else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }
    
    /// Mark the thinking process as complete
    public func complete() {
        handleDone()
    }
    
    // MARK: - Private Event Handlers

    private func handleToolStart(_ event: StreamEvent) {
        let toolName = (event.content?["tool"]?.value as? String) ??
                       (event.content?["tool_name"]?.value as? String) ?? "tool"
        let displayText = event.content?["text"]?.value as? String
        let toolId = event.content?["id"]?.value as? String ?? UUID().uuidString

        // Track start time for duration calculation
        activeToolStarts[toolName] = Date()

        // Update header summary with active tool label
        activeDetail = displayText ?? humanReadableToolName(toolName)
        
        // Determine phase for this tool
        let phase = ThinkingPhase.from(toolName: toolName)
        toolPhaseMap[toolName] = phase
        
        // Update current phase if needed
        if phase != currentPhase {
            // Complete the current phase step
            updateStep(forPhase: currentPhase) { step in
                step.status = .complete
            }
            
            currentPhase = phase
            
            // Check if we already have a step for this phase
            if !steps.contains(where: { $0.phase == phase && $0.status != .complete }) {
                steps.append(ThinkingStep(
                    phase: phase,
                    title: phase.rawValue,
                    status: .active
                ))
            }
        }
        
        // Update the current phase step with tool info
        updateStep(forPhase: phase) { step in
            if step.status != .active {
                step.status = .active
            }
            
            // Add tool to history (as in-progress)
            let toolResult = ToolResult(
                id: toolId,
                tool: toolName,
                displayName: displayText ?? humanReadableToolName(toolName),
                result: nil,
                durationMs: nil,
                isComplete: false
            )
            step.toolResults.append(toolResult)
            
            // Update detail with current tool (shows what's happening now)
            step.detail = displayText ?? humanReadableToolName(toolName)
        }
    }
    
    private func handleToolComplete(_ event: StreamEvent) {
        let toolName = (event.content?["tool"]?.value as? String) ??
                       (event.content?["tool_name"]?.value as? String) ?? "tool"
        let displayText = event.content?["text"]?.value as? String

        // Track progress
        completedSteps += 1
        activeDetail = nil

        // Calculate duration
        var durationMs: Int?
        if let startTime = activeToolStarts.removeValue(forKey: toolName) {
            durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        }

        // Get phase for this tool
        let phase = toolPhaseMap.removeValue(forKey: toolName) ?? currentPhase

        // Update the phase step
        updateStep(forPhase: phase) { step in
            // Find and update the tool result in history
            if let toolIndex = step.toolResults.lastIndex(where: { $0.tool == toolName && !$0.isComplete }) {
                step.toolResults[toolIndex].result = displayText
                step.toolResults[toolIndex].durationMs = durationMs
                step.toolResults[toolIndex].isComplete = true
            }

            // Update cumulative duration
            if let ms = durationMs {
                step.durationMs = (step.durationMs ?? 0) + ms
            }

            // Update detail to show latest completed action
            step.detail = displayText ?? humanReadableToolName(toolName)

            // Don't mark complete yet - more tools might be in this phase
        }
    }
    
    private func handleDone() {
        guard !isComplete else { return }

        // Stop timer
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        activeDetail = nil

        // Complete all active steps and force-complete any orphaned tool results
        for i in steps.indices {
            if steps[i].status == .active {
                steps[i].status = .complete
            }
            for j in steps[i].toolResults.indices {
                if !steps[i].toolResults[j].isComplete {
                    steps[i].toolResults[j].isComplete = true
                }
            }
        }

        // Clear any leaked tool tracking state
        activeToolStarts.removeAll()
        toolPhaseMap.removeAll()

        // Calculate total duration
        if let start = startTime {
            totalDurationMs = Int(Date().timeIntervalSince(start) * 1000)
        }

        isComplete = true
    }
    
    private func handleError(_ event: StreamEvent) {
        let errorText = event.content?["text"]?.value as? String ??
                        event.content?["error"]?.value as? String ?? "An error occurred"

        // Stop timer
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        activeDetail = nil

        // Mark current step as error
        updateActiveStep { step in
            step.status = .error(errorText)
        }

        isComplete = true
    }
    
    // MARK: - Helpers
    
    private func updateStep(forPhase phase: ThinkingPhase, modifier: (inout ThinkingStep) -> Void) {
        if let index = steps.lastIndex(where: { $0.phase == phase }) {
            modifier(&steps[index])
        }
    }
    
    private func updateActiveStep(modifier: (inout ThinkingStep) -> Void) {
        if let index = steps.lastIndex(where: { $0.status == .active }) {
            modifier(&steps[index])
        }
    }
    
    private func humanReadableToolName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "tool_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}

// MARK: - Xcode Debug Logging

extension ThinkingProcessState {
    /// Log current state to Xcode console for debugging
    public func logState() {
        #if DEBUG
        print("┌─ ThinkingProcessState ──────────────────")
        print("│ Phase: \(currentPhase.rawValue)")
        print("│ Complete: \(isComplete)")
        print("│ Steps: \(steps.count)")
        for step in steps {
            let statusIcon: String
            switch step.status {
            case .pending: statusIcon = "⏳"
            case .active: statusIcon = "🔄"
            case .complete: statusIcon = "✅"
            case .error: statusIcon = "❌"
            }
            print("│   \(statusIcon) [\(step.phase.rawValue)] \(step.title)")
            if let detail = step.detail {
                print("│       └─ \(detail)")
            }
        }
        print("└──────────────────────────────────────────")
        #endif
    }
}
