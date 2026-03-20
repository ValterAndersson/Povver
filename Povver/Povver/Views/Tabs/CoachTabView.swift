import SwiftUI

/// Coach Tab - State-driven agent interface.
/// Hero section adapts to workout day, rest day, post-workout, inactivity, or new user.
/// Quick actions as vertical list, recent conversations as flat rows.
struct CoachTabView: View {
    /// Callback to switch to another tab (e.g., Train)
    let switchToTab: (MainTab) -> Void
    /// One-shot context to auto-navigate to conversation (e.g., after onboarding "Adjust with coach")
    var initialConversationContext: String? = nil

    @StateObject private var viewModel = CoachTabViewModel()
    @State private var hasAppeared = false

    /// Navigation state for conversation screen
    @State private var navigateToConversation = false
    @State private var entryContext: String = ""
    @State private var query: String = ""
    @State private var selectedConversationId: String? = nil
    @State private var showAllConversations = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                // State-driven hero
                heroSection
                    .staggeredEntrance(index: 0, active: hasAppeared)

                // Prompt bar
                inputBar
                    .staggeredEntrance(index: 1, active: hasAppeared)

                // Quick actions (hidden during loading)
                if case .loading = viewModel.state {} else {
                    quickActionsSection
                        .staggeredEntrance(index: 2, active: hasAppeared)
                }

                // Recent conversations
                if viewModel.hasLoadedConversations && !viewModel.recentConversations.isEmpty {
                    recentSection
                        .staggeredEntrance(index: 3, active: hasAppeared)
                }
            }
            .padding(InsetsToken.screen)
        }
        .background(Color.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToConversation) {
            conversationDestination
        }
        .sheet(isPresented: $showAllConversations, onDismiss: {
            // Navigate after sheet fully dismisses to avoid animation race
            if selectedConversationId != nil {
                navigateToConversation = true
            }
        }) {
            AllConversationsSheet { canvasId in
                selectedConversationId = canvasId
                entryContext = ""
                showAllConversations = false
            }
        }
        .task {
            await viewModel.load()
        }
        .onAppear {
            viewModel.loadRecentConversations()
            if !hasAppeared {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    hasAppeared = true
                }
            }
            // Auto-navigate to conversation if coming from onboarding "Adjust with coach"
            if let context = initialConversationContext, !context.isEmpty {
                selectedConversationId = nil
                entryContext = context
                // Small delay to let NavigationStack settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    navigateToConversation = true
                }
            }
        }
        .onChange(of: navigateToConversation) { _, isActive in
            if !isActive {
                // User navigated back — clear input state
                query = ""
                entryContext = ""
                selectedConversationId = nil
                viewModel.loadRecentConversations()
            }
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private var heroSection: some View {
        switch viewModel.state {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .frame(minHeight: 120)
        case .newUser:
            newUserHero
        case .workoutDay(let ctx):
            workoutDayHero(ctx)
        case .restDay(let ctx):
            restDayHero(ctx)
        case .postWorkout(let ctx):
            postWorkoutHero(ctx)
        case .returningAfterInactivity(let ctx):
            inactivityHero(ctx)
        }
    }

    // MARK: - New User Hero

    private var newUserHero: some View {
        VStack(spacing: Space.md) {
            CoachPresenceIndicator(size: 40)

            Text("Let's build your program")
                .textStyle(.screenTitle)
                .foregroundStyle(Color.textPrimary)

            Text("Start with a routine, or ask me anything")
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
    }

    // MARK: - Workout Day Hero

    private func workoutDayHero(_ ctx: WorkoutDayContext) -> some View {
        VStack(spacing: Space.md) {
            CoachPresenceIndicator(size: 40)

            Text(ctx.greeting)
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)

            Text(ctx.scheduledWorkoutName)
                .textStyle(.screenTitle)
                .foregroundStyle(Color.textPrimary)

            if !ctx.dayLabel.isEmpty {
                Text(ctx.dayLabel)
                    .textStyle(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            if let loadStatus = ctx.trainingLoadStatus {
                Text(loadStatus)
                    .textStyle(.caption)
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Color.accent.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
    }

    // MARK: - Rest Day Hero

    private func restDayHero(_ ctx: RestDayContext) -> some View {
        VStack(spacing: Space.md) {
            CoachPresenceIndicator(size: 40)

            Text(ctx.greeting)
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)

            Text("Rest Day")
                .textStyle(.screenTitle)
                .foregroundStyle(Color.textPrimary)

            if let insight = ctx.insight {
                Text(insight)
                    .textStyle(.secondary)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.md)
            }

            // Consistency map — shows 12-week training pattern
            if !viewModel.weeklyWorkoutCounts.isEmpty {
                TrainingConsistencyMap(
                    weeks: viewModel.weeklyWorkoutCounts,
                    routineFrequency: viewModel.routineFrequency
                )
                .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
    }

    // MARK: - Post-Workout Hero

    private func postWorkoutHero(_ ctx: PostWorkoutContext) -> some View {
        VStack(spacing: Space.md) {
            CoachPresenceIndicator(size: 40)

            Text("Session Complete")
                .textStyle(.screenTitle)
                .foregroundStyle(Color.textPrimary)

            Text(ctx.workoutName)
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)

            // Workout stats row
            HStack(spacing: Space.lg) {
                statItem(value: "\(ctx.exerciseCount)", label: "exercises")
                statItem(value: "\(ctx.setCount)", label: "sets")
                statItem(value: formatVolume(ctx.totalVolume), label: "kg")
            }
            .padding(.top, Space.xs)

            if let summary = ctx.summary, !summary.summary.isEmpty {
                Text(summary.summary)
                    .textStyle(.secondary)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.md)
            }

            // Dismiss button to return to normal state
            Button {
                viewModel.dismissPostWorkout()
            } label: {
                Text("Continue")
                    .textStyle(.bodyStrong)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.vertical, Space.xs)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
    }

    // MARK: - Inactivity Hero

    private func inactivityHero(_ ctx: InactivityContext) -> some View {
        VStack(spacing: Space.md) {
            CoachPresenceIndicator(size: 40)

            Text("Welcome back")
                .textStyle(.screenTitle)
                .foregroundStyle(Color.textPrimary)

            Text("\(ctx.daysSinceLastWorkout) days since your last session")
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)

            if let nextName = ctx.nextWorkoutName {
                Text("Up next: \(nextName)")
                    .textStyle(.bodyStrong)
                    .foregroundStyle(Color.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        AgentPromptBar(text: $query, placeholder: "Ask anything") {
            selectedConversationId = nil
            entryContext = "freeform:" + query
            navigateToConversation = true
        }
        .frame(maxWidth: 680)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Quick Actions")
                .textStyle(.sectionLabel)

            VStack(spacing: 1) {
                // Contextual top action for workout day
                if case .workoutDay = viewModel.state {
                    quickActionRow(
                        title: "Start today's session",
                        icon: "play.fill",
                        accent: true
                    ) {
                        switchToTab(.train)
                    }
                }

                quickActionRow(
                    title: "Analyze my progress",
                    icon: "chart.bar",
                    accent: false
                ) {
                    AnalyticsService.shared.quickActionTapped(action: .analyzeProgress)
                    selectedConversationId = nil
                    entryContext = "quick:Analyze progress"
                    navigateToConversation = true
                }

                quickActionRow(
                    title: "Review my program",
                    icon: "arrow.triangle.2.circlepath",
                    accent: false
                ) {
                    AnalyticsService.shared.quickActionTapped(action: .reviewPlan)
                    selectedConversationId = nil
                    entryContext = "quick:Review plan"
                    navigateToConversation = true
                }

                quickActionRow(
                    title: "Create a routine",
                    icon: "figure.strengthtraining.traditional",
                    accent: false
                ) {
                    AnalyticsService.shared.quickActionTapped(action: .createRoutine)
                    selectedConversationId = nil
                    entryContext = "quick:Create routine"
                    navigateToConversation = true
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous))
        }
    }

    private func quickActionRow(title: String, icon: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accent ? Color.accent : Color.textSecondary)
                    .frame(width: 24)

                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(accent ? Color.accent : Color.textPrimary)

                Spacer()

                if accent {
                    Text("START")
                        .textStyle(.sectionLabel)
                        .foregroundStyle(Color.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Conversations

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Recent")
                .textStyle(.sectionLabel)

            ForEach(viewModel.recentConversations.prefix(5)) { conv in
                Button {
                    selectedConversationId = conv.id
                    entryContext = ""
                    navigateToConversation = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conv.title ?? conv.lastMessage ?? "General chat")
                                .textStyle(.secondary)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)

                            if let date = conv.updatedAt ?? conv.createdAt {
                                Text(date.relativeDescription)
                                    .textStyle(.micro)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .padding(.vertical, Space.sm)
                }
                .buttonStyle(.plain)

                if conv.id != viewModel.recentConversations.prefix(5).last?.id {
                    Divider().foregroundStyle(Color.separatorLine)
                }
            }

            // See all button
            Button {
                showAllConversations = true
            } label: {
                Text("See all conversations")
                    .textStyle(.secondary)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Conversation Destination

    @ViewBuilder
    private var conversationDestination: some View {
        if let uid = AuthService.shared.currentUser?.uid {
            if let resumeId = selectedConversationId {
                // Resuming an existing conversation
                ConversationScreen(
                    userId: uid,
                    canvasId: resumeId,
                    purpose: nil,
                    entryContext: nil
                )
            } else {
                // Starting a new conversation
                ConversationScreen(
                    userId: uid,
                    canvasId: nil,
                    purpose: "ad_hoc",
                    entryContext: entryContext
                )
            }
        } else {
            EmptyState(title: "Ask me anything", message: "About your training, nutrition, or recovery.")
        }
    }

    // MARK: - Helpers

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .textStyle(.metricM)
                .foregroundStyle(Color.textPrimary)
            Text(label)
                .textStyle(.micro)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1000 {
            return String(format: "%.0f", volume / 1000) + "k"
        }
        return String(format: "%.0f", volume)
    }

}

// MARK: - Relative Date Formatting

private extension Date {
    var relativeDescription: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        if interval < 60 { return "Just now" }
        if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        }
        if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
        let days = Int(interval / 86400)
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: self)
    }
}

#if DEBUG
struct CoachTabView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CoachTabView(switchToTab: { _ in })
        }
    }
}
#endif
