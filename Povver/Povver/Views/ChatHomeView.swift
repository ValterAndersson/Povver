import SwiftUI

struct ChatHomeView: View {
    let userId: String?
    @State private var query: String = ""
    @State private var navigateToCanvas = false
    @State private var entryContext: String = ""

    /// Binding to switch tabs from quick actions
    @AppStorage("selectedTab") private var selectedTab: String = "coach"

    private let quickActions: [String] = [
        "Make a training program",
        "Start exercise",
        "Analyze my progress"
    ]

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()

            VStack(alignment: .center, spacing: Space.xl) {
                header
                inputBar
                quickActionsSection
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(maxWidth: LayoutToken.contentMaxWidth)
            .padding(InsetsToken.screen)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToCanvas) {
            canvasDestination
        }
    }

    private var header: some View {
        VStack(alignment: .center, spacing: Space.sm) {
            PovverText("What's on the agenda today?", style: .display, align: .center)
        }
    }

    private var inputBar: some View {
        AgentPromptBar(text: $query, placeholder: "Ask anything") {
            entryContext = "freeform:" + query
            navigateToCanvas = true
        }
        .frame(maxWidth: 680)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PovverText("Quick actions", style: .subheadline, color: Color.textSecondary)
            let columns = [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)]
            LazyVGrid(columns: columns, alignment: .center, spacing: Space.md) {
                QuickActionCard(title: "Plan program", icon: iconForPreset("make a training program")) {
                    entryContext = "quick:Plan program"
                    navigateToCanvas = true
                }
                QuickActionCard(title: "Train", icon: "figure.strengthtraining.traditional") {
                    // Switch to Train tab - tab change is handled via AppStorage
                    selectedTab = "train"
                }
                QuickActionCard(title: "Analyze progress", icon: iconForPreset("analyze my progress")) {
                    entryContext = "quick:Analyze progress"
                    navigateToCanvas = true
                }
            }
        }
        .frame(maxWidth: 820)
    }

    private func greetingTitle() -> String {
        // Placeholder; in future derive first name from profile
        return "Good afternoon!"
    }

    @ViewBuilder private var canvasDestination: some View {
        if let uid = userId {
            CanvasScreen(userId: uid, canvasId: nil, purpose: purposeForEntryContext(entryContext), entryContext: entryContext)
        } else {
            EmptyState(title: "Not signed in", message: "Login to view canvas.")
        }
    }

    private func purposeForEntryContext(_ ctx: String) -> String {
        // Simple mapping: quick and freeform default to ad_hoc; can expand later
        return "ad_hoc"
    }

    private func iconForPreset(_ title: String) -> String {
        switch title.lowercased() {
        case "make a training program": return "figure.strengthtraining.traditional"
        case "start exercise": return "play.fill"
        case "analyze my progress": return "chart.bar"
        default: return "sparkles"
        }
    }
}

#if DEBUG
struct ChatHomeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { ChatHomeView(userId: "demo-user") }
    }
}
#endif
