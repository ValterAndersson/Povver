import SwiftUI

/// Main navigation tabs for the app
/// 5-tab structure: Coach / Train / Library / History / More
enum MainTab: String, CaseIterable {
    case coach
    case train
    case library
    case history
    case more

    /// SF Symbol icon name (outline style)
    var iconName: String {
        switch self {
        case .coach: return "bubble.left.and.bubble.right"
        case .train: return "figure.strengthtraining.traditional"
        case .library: return "rectangle.stack"
        case .history: return "clock.arrow.circlepath"
        case .more: return "ellipsis.circle"
        }
    }

    /// Tab label (single word)
    var label: String {
        switch self {
        case .coach: return "Coach"
        case .train: return "Train"
        case .library: return "Library"
        case .history: return "History"
        case .more: return "More"
        }
    }

    /// Migration from old MainTab enum values
    static func migrate(from rawValue: String) -> MainTab {
        switch rawValue {
        case "home": return .coach
        case "workout": return .train
        case "profile": return .more
        default:
            if let tab = MainTab(rawValue: rawValue) {
                return tab
            }
            return .coach
        }
    }
}

struct MainTabsView: View {
    /// One-shot entry context for "Adjust with coach" after onboarding
    var adjustWithCoachContext: String? = nil

    /// Persisted tab selection with migration support
    @AppStorage("selectedTab") private var selectedTabRaw: String = MainTab.coach.rawValue

    /// Computed binding that handles migration from old values
    private var selectedTab: Binding<MainTab> {
        Binding(
            get: { MainTab.migrate(from: selectedTabRaw) },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    @StateObject private var recommendationsVM = RecommendationsViewModel()
    @StateObject private var workoutService = FocusModeWorkoutService.shared
    @State private var bannerElapsedTime: TimeInterval = 0
    @State private var bannerTimer: Timer? = nil

    /// Whether the floating workout banner should be visible
    private var showWorkoutBanner: Bool {
        workoutService.workout != nil && MainTab.migrate(from: selectedTabRaw) != .train
    }

    var body: some View {
        TabView(selection: selectedTab) {
            // Coach Tab
            NavigationStack {
                CoachTabView(switchToTab: switchToTab, initialConversationContext: adjustWithCoachContext)
            }
            .tabItem { Label(MainTab.coach.label, systemImage: MainTab.coach.iconName) }
            .tag(MainTab.coach)

            // Train Tab
            NavigationStack {
                TrainTabView()
            }
            .tabItem { Label(MainTab.train.label, systemImage: MainTab.train.iconName) }
            .tag(MainTab.train)

            // Library Tab
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label(MainTab.library.label, systemImage: MainTab.library.iconName) }
            .tag(MainTab.library)

            // History Tab
            NavigationStack {
                HistoryView()
            }
            .tabItem { Label(MainTab.history.label, systemImage: MainTab.history.iconName) }
            .tag(MainTab.history)

            // More Tab (formerly Profile)
            NavigationStack {
                MoreView(recommendationsVM: recommendationsVM)
            }
            .tabItem { Label(MainTab.more.label, systemImage: MainTab.more.iconName) }
            .tag(MainTab.more)
        }
        .tint(Color.accent)
        .environment(\.workoutActive, workoutService.workout != nil)
        .overlay(alignment: .bottom) {
            if showWorkoutBanner {
                FloatingWorkoutBanner(
                    workoutName: workoutService.workout?.name ?? "Workout",
                    currentExerciseName: workoutService.workout?.exercises.first { !$0.isComplete }?.name,
                    elapsedTime: bannerElapsedTime,
                    onTap: { selectedTabRaw = MainTab.train.rawValue }
                )
                .padding(.horizontal, Space.md)
                .padding(.bottom, 52) // Above tab bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: MotionToken.medium), value: showWorkoutBanner)
        .onChange(of: showWorkoutBanner) { _, visible in
            if visible {
                startBannerTimer()
            } else {
                stopBannerTimer()
            }
        }
        .onAppear {
            if showWorkoutBanner {
                startBannerTimer()
            }
        }
        .onChange(of: selectedTabRaw) { _, newTab in
            AnalyticsService.shared.tabViewed(newTab)
            AppLogger.shared.nav("tab:\(newTab)")
        }
        .task {
            if let userId = AuthService.shared.currentUser?.uid {
                recommendationsVM.startListening(userId: userId)
                // Fallback prefetch — primary trigger is in RootView.onChange(of: flow).
                // No-op if already running/completed (guarded by isPrefetching).
                await FocusModeWorkoutService.shared.prefetchLibraryData()
            }
        }
    }

    /// Switch to a specific tab programmatically
    /// Used by Coach tab to navigate to Train tab
    private func switchToTab(_ tab: MainTab) {
        selectedTabRaw = tab.rawValue
    }

    // MARK: - Banner Timer

    private func startBannerTimer() {
        stopBannerTimer()
        updateBannerElapsed()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                updateBannerElapsed()
            }
        }
    }

    private func stopBannerTimer() {
        bannerTimer?.invalidate()
        bannerTimer = nil
    }

    private func updateBannerElapsed() {
        if let startTime = workoutService.workout?.startTime {
            bannerElapsedTime = Date().timeIntervalSince(startTime)
        }
    }
}

#if DEBUG
struct MainTabsView_Previews: PreviewProvider {
    static var previews: some View { MainTabsView() }
}
#endif
