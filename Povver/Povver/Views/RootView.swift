import SwiftUI
import FirebaseFirestore

enum AppFlow {
    case login
    case register
    case onboarding
    case main
}

struct RootView: View {
    @StateObject private var session = SessionManager.shared
    @ObservedObject private var authService = AuthService.shared
    @State private var flow: AppFlow = .login
    @AppStorage("selectedTab") private var selectedTabRaw: String = MainTab.coach.rawValue
    @State private var adjustWithCoachAfterOnboarding = false

    var body: some View {
        NavigationStack {
            switch flow {
            case .login:
                LoginView(onLogin: { _ in
                    selectedTabRaw = MainTab.coach.rawValue
                    if OnboardingViewModel.shouldShowOnboarding() {
                        flow = .onboarding
                    } else {
                        flow = .main
                    }
                }, onRegister: {
                    flow = .register
                })
            case .register:
                RegisterView(onRegister: { _ in
                    selectedTabRaw = MainTab.coach.rawValue
                    if OnboardingViewModel.shouldShowOnboarding() {
                        flow = .onboarding
                    } else {
                        flow = .main
                    }
                }, onBackToLogin: {
                    flow = .login
                })
            case .onboarding:
                OnboardingView { adjustWithCoach in
                    if adjustWithCoach {
                        adjustWithCoachAfterOnboarding = true
                    }
                    selectedTabRaw = MainTab.coach.rawValue
                    flow = .main
                }
            case .main:
                MainTabsView(adjustWithCoachContext: adjustWithCoachAfterOnboarding ? "freeform:I just finished setting up my profile and you generated a routine for me. Here's what I built. What would you change?" : nil)
                    .onAppear {
                        // Clear the one-shot flag after MainTabsView has consumed it
                        if adjustWithCoachAfterOnboarding {
                            adjustWithCoachAfterOnboarding = false
                        }
                    }
            }
        }
        // Reactively reset to login when auth state becomes unauthenticated.
        // Handles sign-out, account deletion, and token expiration.
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                flow = .login
            }
        }
        .onChange(of: flow) { _, newFlow in
            AnalyticsService.shared.screenViewed(String(describing: newFlow))
            AppLogger.shared.nav("screen:\(String(describing: newFlow))")
        }
        // Prefetch workout data after successful auth
        .onChange(of: flow) { _, newFlow in
            if newFlow == .main {
                // Prefetch templates, routines, next workout, and active workout in parallel.
                // Fires here (before MainTabsView.task) so data is ready when user taps Train.
                Task { await FocusModeWorkoutService.shared.prefetchLibraryData() }
            }
        }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
    }
}
