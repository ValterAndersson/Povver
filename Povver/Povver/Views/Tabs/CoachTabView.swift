import SwiftUI
import FirebaseFirestore

/// Coach Tab - Primary agent interface with quick action buttons
/// Direct access to different coaching use-cases without mode switching
struct CoachTabView: View {
    /// Callback to switch to another tab (e.g., Train)
    let switchToTab: (MainTab) -> Void
    /// One-shot context to auto-navigate to canvas (e.g., after onboarding "Adjust with coach")
    var initialCanvasContext: String? = nil

    /// Navigation state for canvas screen
    @State private var navigateToCanvas = false
    @State private var entryContext: String = ""
    @State private var query: String = ""
    @State private var selectedCanvasId: String? = nil
    @State private var recentCanvases: [RecentCanvas] = []
    @State private var showAllConversations = false
    @State private var hasLoadedCanvases = false

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: Space.xl) {
                Spacer(minLength: Space.xl)

                // Header
                header

                // Input bar for free-form questions
                inputBar

                if hasLoadedCanvases {
                    // Returning user: show conversations, hide quick actions
                    if !recentCanvases.isEmpty {
                        recentChatsSection
                    } else {
                        // New user: show quick actions
                        quickActionsGrid
                    }
                }

                Spacer(minLength: Space.xxl)
            }
            .frame(maxWidth: .infinity)
            .padding(InsetsToken.screen)
        }
        .background(Color.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToCanvas) {
            canvasDestination
        }
        .sheet(isPresented: $showAllConversations, onDismiss: {
            // Navigate after sheet fully dismisses to avoid animation race
            if selectedCanvasId != nil {
                navigateToCanvas = true
            }
        }) {
            AllConversationsSheet { canvasId in
                selectedCanvasId = canvasId
                entryContext = ""
                showAllConversations = false
            }
        }
        .onAppear {
            loadRecentCanvases()
            // Auto-navigate to canvas if coming from onboarding "Adjust with coach"
            if let context = initialCanvasContext, !context.isEmpty {
                selectedCanvasId = nil
                entryContext = context
                // Small delay to let NavigationStack settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    navigateToCanvas = true
                }
            }
        }
        .onChange(of: navigateToCanvas) { _, isActive in
            if !isActive {
                // User navigated back — clear input state
                query = ""
                entryContext = ""
                selectedCanvasId = nil
                loadRecentCanvases()
            }
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        VStack(alignment: .center, spacing: Space.sm) {
            PovverText("What's on the agenda today?", style: .display, align: .center)
        }
    }
    
    // MARK: - Input Bar
    
    private var inputBar: some View {
        AgentPromptBar(text: $query, placeholder: "Ask anything") {
            selectedCanvasId = nil
            entryContext = "freeform:" + query
            navigateToCanvas = true
        }
        .frame(maxWidth: 680)
    }
    
    // MARK: - Quick Actions Grid
    
    private var quickActionsGrid: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PovverText("Quick actions", style: .subheadline, color: Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            let columns = [
                GridItem(.flexible(), spacing: Space.md),
                GridItem(.flexible(), spacing: Space.md)
            ]
            
            LazyVGrid(columns: columns, alignment: .center, spacing: Space.md) {
                QuickActionCard(title: "Plan program", icon: "calendar.badge.plus") {
                    AnalyticsService.shared.quickActionTapped(action: .planProgram)
                    selectedCanvasId = nil
                    entryContext = "quick:Plan program"
                    navigateToCanvas = true
                }

                QuickActionCard(title: "Analyze progress", icon: "chart.bar") {
                    AnalyticsService.shared.quickActionTapped(action: .analyzeProgress)
                    selectedCanvasId = nil
                    entryContext = "quick:Analyze progress"
                    navigateToCanvas = true
                }

                QuickActionCard(title: "Create routine", icon: "figure.strengthtraining.traditional") {
                    AnalyticsService.shared.quickActionTapped(action: .createRoutine)
                    selectedCanvasId = nil
                    entryContext = "quick:Create routine"
                    navigateToCanvas = true
                }

                QuickActionCard(title: "Review plan", icon: "doc.text.magnifyingglass") {
                    AnalyticsService.shared.quickActionTapped(action: .reviewPlan)
                    selectedCanvasId = nil
                    entryContext = "quick:Review plan"
                    navigateToCanvas = true
                }
            }
        }
        .frame(maxWidth: 820)
    }
    
    // MARK: - Canvas Destination
    
    @ViewBuilder
    private var canvasDestination: some View {
        if let uid = AuthService.shared.currentUser?.uid {
            if let resumeId = selectedCanvasId {
                // Resuming an existing conversation
                CanvasScreen(
                    userId: uid,
                    canvasId: resumeId,
                    purpose: nil,
                    entryContext: nil
                )
            } else {
                // Starting a new conversation
                CanvasScreen(
                    userId: uid,
                    canvasId: nil,
                    purpose: "ad_hoc",
                    entryContext: entryContext
                )
            }
        } else {
            EmptyState(title: "Not signed in", message: "Login to view canvas.")
        }
    }
    
    // MARK: - Recent Chats

    private var recentChatsSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PovverText("Recent", style: .subheadline, color: Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: Space.sm) {
                ForEach(recentCanvases.prefix(5)) { canvas in
                    Button {
                        selectedCanvasId = canvas.id
                        entryContext = ""
                        navigateToCanvas = true
                    } label: {
                        SurfaceCard(padding: InsetsToken.all(Space.md)) {
                            HStack(spacing: Space.md) {
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    PovverText(
                                        canvas.title ?? canvas.lastMessage ?? "General chat",
                                        style: .subheadline,
                                        lineLimit: 1
                                    )
                                    if let date = canvas.updatedAt ?? canvas.createdAt {
                                        PovverText(
                                            date.relativeDescription,
                                            style: .caption,
                                            color: Color.textSecondary
                                        )
                                    }
                                }
                                Spacer()
                                Icon("chevron.right", size: .md, color: Color.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            Button {
                showAllConversations = true
            } label: {
                HStack {
                    Spacer()
                    PovverText("See all", style: .subheadline, color: Color.accent)
                    Spacer()
                }
                .padding(.vertical, Space.sm)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: 680)
    }

    // MARK: - Helpers

    private func loadRecentCanvases() {
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        let db = Firestore.firestore()
        db.collection("users").document(uid).collection("canvases")
            .whereField("status", isEqualTo: "active")
            .order(by: "updatedAt", descending: true)
            .limit(to: 5)
            .getDocuments { snapshot, error in
                if let error = error {
                    AppLogger.shared.error(.store, "loadRecentCanvases failed", error)
                }
                guard let docs = snapshot?.documents, error == nil else {
                    DispatchQueue.main.async { self.hasLoadedCanvases = true }
                    return
                }
                let canvases: [RecentCanvas] = docs.compactMap { doc in
                    let data = doc.data()
                    let title = data["title"] as? String
                    let lastMessage = data["lastMessage"] as? String
                    let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
                    // Skip canvases that have never been messaged
                    guard lastMessage != nil || updatedAt != nil else { return nil }
                    return RecentCanvas(
                        id: doc.documentID,
                        title: title,
                        lastMessage: lastMessage,
                        updatedAt: updatedAt,
                        createdAt: createdAt
                    )
                }
                DispatchQueue.main.async {
                    self.recentCanvases = canvases
                    self.hasLoadedCanvases = true
                }
            }
    }
}

// MARK: - Recent Canvas Model

private struct RecentCanvas: Identifiable {
    let id: String
    let title: String?
    let lastMessage: String?
    let updatedAt: Date?
    let createdAt: Date?
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
