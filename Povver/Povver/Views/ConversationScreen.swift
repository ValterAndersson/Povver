import SwiftUI

struct ConversationScreen: View {
    @StateObject private var vm = ConversationViewModel()
    let userId: String
    let canvasId: String?
    let purpose: String?
    let entryContext: String?
    @State private var seededDemo: Bool = false
    @State private var showRefine: Bool = false
    @State private var refineText: String = ""
    @State private var showSwap: Bool = false
    @State private var pinned: [CanvasCardModel] = []
    @State private var toastText: String? = nil
    @State private var didInvokeAgent: Bool = false
    @State private var composerText: String = ""
    @State private var answeredClarifications: Set<String> = []
    @State private var composerExpanded: Bool = true
    @State private var showFocusMode: Bool = false
    @State private var planBlocksForFocusMode: [[String: Any]]? = nil
    @FocusState private var composerFocused: Bool
    
    private typealias ClarificationPrompt = TimelineClarificationPrompt

    var body: some View {
        // Filter to only show the latest session_plan card (others can accumulate)
        let dedupedCards = deduplicateSessionPlans(vm.cards)
        let embeddedCards = dedupedCards.sorted {
            ($0.publishedAt ?? Date.distantPast) < ($1.publishedAt ?? Date.distantPast)
        }
        let pendingClarification = activeClarificationPrompt
        
        VStack(spacing: 0) {
            if !vm.errorMessage.orEmpty.isEmpty {
                Banner(title: "Error", message: vm.errorMessage, kind: .error)
            }
            WorkspaceTimelineView(
                events: vm.workspaceEvents,
                embeddedCards: embeddedCards,
                allCards: vm.cards,  // Pass ALL cards for RoutineSummaryCard to look up linked session_plans
                syntheticClarification: syntheticClarificationPrompt,
                answeredClarifications: answeredClarifications,
                onClarificationSubmit: handleClarificationSubmit,
                onClarificationSkip: handleClarificationSkip,
                hideThinkingEvents: true,  // Hide old thought process - using new ThinkingBubble
                thinkingState: vm.thinkingState  // Gemini-style thinking process
            )
            .contentShape(Rectangle())
            .onTapGesture { composerFocused = false }
            
            composeBar(pendingClarification: pendingClarification)
        }
        .environment(\.cardActionHandler, handleCardAction)
        .sheet(isPresented: $showRefine) { RefineSheet(text: $refineText) { _ in showRefine = false } }
        .sheet(isPresented: $showSwap) { SwapSheet { _, _ in showSwap = false } }
        .navigationTitle("Conversation")
        .onAppear {
            if let cid = canvasId {
                vm.start(userId: userId, canvasId: cid)
            } else {
                let p = purpose ?? "ad_hoc"
                vm.start(userId: userId, purpose: p)
            }
        }
        .onDisappear { vm.stop() }
        .onChange(of: vm.isReady) { _, ready in
            guard ready, !didInvokeAgent, let cid = vm.canvasId else { return }
            if let msg = computeAgentMessage(from: entryContext) {
                didInvokeAgent = true
                vm.clearCards()
                answeredClarifications.removeAll()
                let correlationId = UUID().uuidString
                vm.startSSEStream(userId: userId, canvasId: cid, message: msg, correlationId: correlationId)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = toastText {
                UndoToast(t) {
                    if let cid = vm.canvasId ?? canvasId {
                        Task { await vm.applyAction(canvasId: cid, type: "UNDO", cardId: nil) }
                    }
                    toastText = nil
                }
                .padding(.bottom, Space.xl)
            }
        }
        .overlay {
            if !vm.isReady {
                ZStack {
                    Color.bg.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: Space.md) {
                        ProgressView().progressViewStyle(.circular)
                        PovverText("Connecting to canvas…", style: .subheadline, color: Color.textSecondary)
                    }
                    .padding(InsetsToken.screen)
                }
            }
        }
        .overlay {
            if vm.isApplying {
                ZStack {
                    Color.black.opacity(0.05).ignoresSafeArea()
                    ProgressView().progressViewStyle(.circular)
                }
                .allowsHitTesting(true)
            }
        }
        .fullScreenCover(isPresented: $showFocusMode) {
            FocusModeWorkoutScreen(planBlocks: planBlocksForFocusMode)
        }
        .sheet(isPresented: $vm.showingPaywall) {
            PaywallView()
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

// MARK: - Compose Bar
extension ConversationScreen {
    /// Check if there's any session plan card
    private var hasSessionPlanCard: Bool {
        vm.cards.contains { $0.type == .session_plan }
    }
    
    /// Check if there's an active proposed plan (makes it the focal element)
    private var hasProposedPlan: Bool {
        vm.cards.contains { (card: CanvasCardModel) -> Bool in
            card.type == .session_plan && card.status == .proposed
        }
    }
    
    private func composeBar(pendingClarification: ClarificationPrompt?) -> some View {
        let placeholder = pendingClarification?.question ?? "Ask anything…"
        
        // When a plan is focal, show collapsed composer unless expanded
        let showCollapsed = hasProposedPlan && !composerExpanded && composerText.isEmpty
        
        let canSend = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isAgentThinking

        return VStack(spacing: 0) {
            if showCollapsed {
                // Minimal "Ask / Adjust" pill
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        composerExpanded = true
                    }
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 13))
                        Text("Ask or adjust...")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(Color.textSecondary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 10)
                    .background(Color.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.separatorLine, lineWidth: StrokeWidthToken.thin))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, Space.md)
            } else {
                // Full composer — matches AgentPromptBar capsule styling
                HStack(spacing: Space.sm) {
                    TextField(placeholder, text: $composerText, axis: .vertical)
                        .focused($composerFocused)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(1...4)

                    Button(action: sendComposerMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color.textInverse)
                            .padding(InsetsToken.all(Space.sm))
                            .background(canSend ? Color.textPrimary : Color.textSecondary.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                }
                .padding(InsetsToken.symmetric(vertical: Space.md, horizontal: Space.lg))
                .background(Color.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.separatorLine, lineWidth: StrokeWidthToken.thin))
                .shadowStyle(ShadowsToken.level2)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
            }
        }
    }
    
    private func sendComposerMessage() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerFocused = false
        if let pending = activeClarificationPrompt {
            composerText = ""
            composerExpanded = false  // Collapse after sending
            handleClarificationSubmit(id: pending.id, question: pending.question, answer: trimmed)
            return
        }
        composerText = ""
        composerExpanded = false  // Collapse after sending
        firePrompt(trimmed)
    }
    
    private func firePrompt(_ message: String) {
        guard let cid = vm.canvasId ?? canvasId else { return }
        answeredClarifications.removeAll()
        vm.archiveProposedCards()
        let correlationId = UUID().uuidString
        vm.startSSEStream(userId: userId, canvasId: cid, message: message, correlationId: correlationId)
    }
    
    private func handleClarificationSubmit(id: String, question: String, answer: String) {
        answeredClarifications.insert(id)
        vm.clearPendingClarification(id: id)
        let message = "Clarification response — \(question): \(answer)"
        vm.logUserResponse(text: message)
        firePrompt(message)
    }

    private func handleClarificationSkip(id: String, question: String) {
        answeredClarifications.insert(id)
        vm.clearPendingClarification(id: id)
        let message = "Clarification skipped — \(question)"
        vm.logUserResponse(text: message)
        firePrompt(message)
    }
    
    private var handleCardAction: CardActionHandler {
        { action, card in
            switch action.kind {
            case "refine":
                refineText = ""; showRefine = true
            case "swap":
                showSwap = true
            case "copy":
                UIPasteboard.general.string = card.title ?? ""
            case "apply":
                if let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "ACCEPT_PROPOSAL", cardId: card.id) }
                    toastText = "Applied"
                }
            case "dismiss":
                if let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "REJECT_PROPOSAL", cardId: card.id) }
                    toastText = "Dismissed"
                }
            case "accept_all":
                if let groupId = card.meta?.groupId, let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "ACCEPT_ALL", cardId: nil, payload: ["group_id": AnyCodable(groupId)]) }
                    toastText = "Applied group"
                }
            case "reject_all":
                if let groupId = card.meta?.groupId, let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "REJECT_ALL", cardId: nil, payload: ["group_id": AnyCodable(groupId)]) }
                    toastText = "Dismissed group"
                }
            case "pin":
                if !pinned.contains(where: { $0.id == card.id }) { pinned.append(card) }
            case "unpin":
                pinned.removeAll { $0.id == card.id }
            case "explain":
                withAnimation(.easeOut(duration: MotionToken.medium)) {
                    vm.cards.insert(
                        CanvasCardModel(
                            type: .summary,
                            data: .inlineInfo("The agent chose this based on your recent volume and preferences."),
                            width: .oneHalf,
                            publishedAt: Date()
                        ),
                        at: 0
                    )
                }
            // MARK: - Plan Card Actions
            case "accept_plan", "start":
                // Accept artifact via AgentsApi if artifact-sourced, else fallback to legacy applyAction
                if let artifactId = card.meta?.artifactId,
                   let conversationId = card.meta?.conversationId ?? vm.canvasId ?? canvasId,
                   let uid = AuthService.shared.currentUser?.uid {
                    Task { _ = try? await AgentsApi.artifactAction(userId: uid, conversationId: conversationId, artifactId: artifactId, action: "accept") }
                } else if let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "ACCEPT_PROPOSAL", cardId: card.id) }
                }

                // P1 Fix: Call startActiveWorkout with plan BEFORE presenting Focus Mode
                // This ensures server-side normalization/validation of plan data
                if let _ = vm.canvasId ?? canvasId {
                    // Parse plan exercises and start workout via backend
                    if let exercisesJson = action.payload?["exercises_json"],
                       let data = exercisesJson.data(using: .utf8),
                       let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        // Start workout via backend for server-side normalization
                        Task {
                            do {
                                // This creates the active workout with normalized exercises
                                _ = try await FocusModeWorkoutService.shared.startWorkoutFromPlan(plan: blocks)
                                await MainActor.run {
                                    // Focus Mode will load via getActiveWorkout (no client-side plan)
                                    planBlocksForFocusMode = nil
                                    showFocusMode = true
                                }
                            } catch {
                                print("[ConversationScreen] Failed to start workout from plan: \(error)")
                                // Fallback: pass plan directly (client-side parsing)
                                await MainActor.run {
                                    planBlocksForFocusMode = blocks
                                    showFocusMode = true
                                }
                            }
                        }
                    } else {
                        // No plan blocks - just open Focus Mode empty
                        showFocusMode = true
                    }
                }
            case "save_as_template":
                // Save session plan exercises as a new template
                if let exercisesJson = action.payload?["exercises_json"],
                   let data = exercisesJson.data(using: .utf8),
                   let planExercises = try? JSONDecoder().decode([PlanExercise].self, from: data) {
                    Task {
                        do {
                            let uid = AuthService.shared.currentUser?.uid ?? ""
                            let templateExercises = planExercises.enumerated().map { (idx, ex) -> WorkoutTemplateExercise in
                                let templateSets = ex.sets.map { s -> WorkoutTemplateSet in
                                    WorkoutTemplateSet(
                                        id: s.id,
                                        reps: s.reps,
                                        rir: s.rir,
                                        type: s.type?.rawValue ?? "working",
                                        weight: s.weight ?? 0
                                    )
                                }
                                return WorkoutTemplateExercise(
                                    id: ex.id,
                                    exerciseId: ex.exerciseId ?? ex.id,
                                    name: ex.name,
                                    position: idx,
                                    sets: templateSets,
                                    restBetweenSets: ex.restBetweenSets
                                )
                            }
                            let template = WorkoutTemplate(
                                id: "",
                                userId: uid,
                                name: card.title ?? "Workout Template",
                                exercises: templateExercises,
                                createdAt: Date(),
                                updatedAt: Date()
                            )
                            _ = try await CloudFunctionService().createTemplate(template: template)
                            await MainActor.run { toastText = "Template saved" }
                        } catch {
                            print("[ConversationScreen] Failed to save template: \(error)")
                            await MainActor.run { toastText = "Failed to save template" }
                        }
                    }
                }
            case "adjust_plan":
                if let instruction = action.payload?["instruction"],
                   let currentPlan = action.payload?["current_plan"] {
                    let prompt = """
                    User adjustment request: \(instruction)
                    
                    Current plan:
                    \(currentPlan)
                    
                    Please update the plan accordingly and publish the revised workout.
                    """
                    firePrompt(prompt)
                }
            case "swap_exercise":
                // Swap exercise - works for both SessionPlanCard and RoutineSummaryCard
                if let instruction = action.payload?["instruction"] {
                    var prompt = "User swap request: \(instruction)"
                    // If current_plan is provided (SessionPlanCard), include it
                    if let currentPlan = action.payload?["current_plan"] {
                        prompt = """
                        User swap request: \(instruction)
                        
                        Current plan (with any user modifications):
                        \(currentPlan)
                        
                        Please swap the exercise and publish the updated plan.
                        """
                    }
                    firePrompt(prompt)
                }
                
            // MARK: - Routine Card Inline Actions
            case "edit_set":
                // User tapped on a set cell to edit it - send to agent for now
                // In future, this could open an inline editor
                if let exerciseName = action.payload?["exercise_name"],
                   let field = action.payload?["field"],
                   let currentValue = action.payload?["current_value"] {
                    // For now, just log - TODO: implement inline number picker
                    print("[ConversationScreen] edit_set: \(exerciseName) \(field)=\(currentValue)")
                }
                
            case "adjust_workout":
                // Adjust workout (shorter, harder, swap focus, regenerate)
                if let instruction = action.payload?["instruction"],
                   let workoutIndex = action.payload?["workout_index"] {
                    let prompt = """
                    User wants to adjust workout day \(workoutIndex): \(instruction)
                    
                    Please update the routine accordingly and publish the revised version.
                    """
                    firePrompt(prompt)
                }
                
            // MARK: - Routine Draft Actions
            case "save_routine":
                // Save routine and templates from draft via artifact action if available
                if let artifactId = card.meta?.artifactId,
                   let conversationId = card.meta?.conversationId ?? vm.canvasId ?? canvasId,
                   let uid = AuthService.shared.currentUser?.uid {
                    Task {
                        do {
                            _ = try await AgentsApi.artifactAction(userId: uid, conversationId: conversationId, artifactId: artifactId, action: "save_routine")
                            await MainActor.run {
                                if let idx = vm.cards.firstIndex(where: { $0.id == card.id }) {
                                    vm.cards[idx] = CanvasCardModel(
                                        id: card.id, type: card.type, status: .accepted, lane: card.lane,
                                        title: card.title, subtitle: card.subtitle, data: card.data,
                                        width: card.width, actions: card.actions, menuItems: card.menuItems,
                                        meta: card.meta, publishedAt: card.publishedAt
                                    )
                                }
                            }
                        } catch {
                            print("[ConversationScreen] save_routine failed: \(error)")
                            await MainActor.run { vm.errorMessage = "Failed to save routine: \(error.localizedDescription)" }
                        }
                    }
                } else if let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "SAVE_ROUTINE", cardId: card.id) }
                }
            case "dismiss_draft":
                // Dismiss entire routine draft via artifact action if available
                if let artifactId = card.meta?.artifactId,
                   let conversationId = card.meta?.conversationId ?? vm.canvasId ?? canvasId,
                   let uid = AuthService.shared.currentUser?.uid {
                    Task { _ = try? await AgentsApi.artifactAction(userId: uid, conversationId: conversationId, artifactId: artifactId, action: "dismiss") }
                    // Remove card from local state
                    vm.cards.removeAll { $0.id == card.id }
                } else if let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "DISMISS_DRAFT", cardId: card.id) }
                }
            case "pin_draft":
                // Pin routine draft (marks all cards active, exempts from TTL)
                if let cid = vm.canvasId ?? canvasId {
                    Task { await vm.applyAction(canvasId: cid, type: "PIN_DRAFT", cardId: card.id) }
                }
            // learn_exercise is now handled directly in SessionPlanCard via ExerciseDetailSheet
            default:
                break
            }
        }
    }
    private func computeAgentMessage(from ctx: String?) -> String? {
        guard let ctx, !ctx.isEmpty else { return nil }
        if ctx.hasPrefix("freeform:") {
            return String(ctx.dropFirst("freeform:".count))
        }
        if ctx.hasPrefix("quick:") {
            let key = String(ctx.dropFirst("quick:".count)).lowercased()
            if key.contains("plan program") { return "Take a look at my profile and goals and propose a training program well suited for me, relying on defined exercise science." }
            if key.contains("new workout") { return "I want to train today. Plan an upper body session and propose the first target." }
            if key.contains("analyze progress") { return "Analyze my progress and show a few key charts for the last 6 weeks." }
        }
        return ctx
    }
}

private extension ConversationScreen {
    /// Filter and deduplicate cards:
    /// - Session plans that are part of a routine (have groupId matching a routine_summary) are HIDDEN
    ///   because they will be accessed via RoutineSummaryCard expansion, not as standalone cards
    /// - Standalone session_plans: only show the latest one (deduplicate)
    /// - Routine summaries: only show the latest PROPOSED or ACTIVE one; hide old/rejected/expired ones
    func deduplicateSessionPlans(_ cards: [CanvasCardModel]) -> [CanvasCardModel] {
        // Find groupIds that belong to routine_summary cards
        let routineGroupIds = Set(cards.compactMap { card -> String? in
            guard card.type == .routine_summary else { return nil }
            return card.meta?.groupId
        })
        
        // Find all STANDALONE session_plan cards (not part of a routine)
        let standalonePlans = cards.filter { card in
            guard card.type == .session_plan else { return false }
            // If this card's groupId matches a routine, it's NOT standalone
            if let groupId = card.meta?.groupId, routineGroupIds.contains(groupId) {
                return false
            }
            return true
        }.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        
        // Keep only the latest STANDALONE session_plan
        let latestStandalonePlanId = standalonePlans.first?.id
        
        // Find the latest PROPOSED or ACTIVE routine_summary card
        // Hide older routine_summary cards to prevent duplicates when agent iterates
        let routineSummaries = cards.filter { $0.type == .routine_summary }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        
        // Keep only the latest routine_summary that is proposed or active
        // If none are proposed/active, keep the absolute latest
        let latestRoutineSummaryId: String? = {
            if let latestProposed = routineSummaries.first(where: { $0.status == .proposed || $0.status == .active }) {
                return latestProposed.id
            }
            return routineSummaries.first?.id
        }()
        
        // Return filtered cards:
        // - HIDE session_plans that are part of a routine (accessed via RoutineSummaryCard expansion)
        // - Deduplicate standalone session_plans (keep only latest)
        // - Deduplicate routine_summaries (keep only latest proposed/active)
        return cards.filter { card in
            if card.type == .session_plan {
                // If part of a routine, HIDE it (will be accessed via RoutineSummaryCard expansion)
                if let groupId = card.meta?.groupId, routineGroupIds.contains(groupId) {
                    return false
                }
                // Standalone: only keep the latest
                return card.id == latestStandalonePlanId
            }
            
            // Deduplicate routine_summary cards - only show the latest
            if card.type == .routine_summary {
                return card.id == latestRoutineSummaryId
            }
            
            return true
        }
    }
    
    private var workspaceClarificationPrompt: ClarificationPrompt? {
        for entry in vm.workspaceEvents.reversed() {
            guard entry.event.eventType == .clarification,
                  let id = entry.event.content?["id"]?.value as? String,
                  answeredClarifications.contains(id) == false,
                  let question = entry.event.content?["question"]?.value as? String else { continue }
            return ClarificationPrompt(id: id, question: question)
        }
        return nil
    }
    
    private var syntheticClarificationPrompt: WorkspaceTimelineView.ClarificationPrompt? {
        guard let cue = vm.pendingClarificationCue else { return nil }
        if let workspace = workspaceClarificationPrompt, workspace.id == cue.id {
            return nil
        }
        return WorkspaceTimelineView.ClarificationPrompt(id: cue.id, question: cue.question)
    }
    
    private var activeClarificationPrompt: ClarificationPrompt? {
        workspaceClarificationPrompt ?? syntheticClarificationPrompt
    }
}
