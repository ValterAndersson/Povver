import SwiftUI

struct OnboardingView: View {
    @StateObject private var vm = OnboardingViewModel()
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            // Layer 1: Background
            Color.bg.ignoresSafeArea()

            // Layer 2: Atmospheric glow (persistent, never transitions)
            OnboardingGlowLayer(
                intensity: vm.glowIntensity,
                verticalOffset: vm.glowOffset
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: vm.currentStep)

            // Layer 3: Grain texture
            GrainTextureOverlay()
                .ignoresSafeArea()

            // Layer 4: Progress bar (only on profile + equipment screens)
            VStack(spacing: 0) {
                if let progress = vm.progressFraction {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accent)
                            .frame(
                                width: geo.size.width * progress,
                                height: 1
                            )
                            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.6), value: progress)
                    }
                    .frame(height: 1)
                }
                Spacer()
            }
            .ignoresSafeArea(edges: .bottom)

            // Layer 5: Screen content
            screenContent
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(vm.currentStep == .welcome)
        .onDisappear {
            vm.cancelGeneration()
        }
        .onChange(of: vm.currentStep) { _, newStep in
            AnalyticsService.shared.onboardingStepViewed(step: String(describing: newStep))
        }
    }

    @ViewBuilder
    private var screenContent: some View {
        switch vm.currentStep {
        case .welcome:
            WelcomeScreen(
                onGetStarted: { vm.advance() },
                onSignIn: { vm.advance() }
            )
            .transition(.asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .auth:
            OnboardingAuthScreen(
                onAuthenticated: {
                    AnalyticsService.shared.screenViewed("onboarding_auth_completed")
                    // Pre-load StoreKit products early so they're ready for Showcase
                    Task { await SubscriptionService.shared.loadProducts() }
                    vm.advance()
                },
                onSignIn: {
                    // Returning user — check if they already have attributes
                    Task {
                        if await checkExistingAttributes() {
                            vm.completeOnboarding()
                            onComplete()
                        } else {
                            Task { await SubscriptionService.shared.loadProducts() }
                            vm.advance()
                        }
                    }
                }
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .trainingProfile:
            TrainingProfileScreen(vm: vm) {
                vm.advance()
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .equipment:
            EquipmentScreen(vm: vm) {
                Task {
                    let _ = await vm.saveUserAttributes()
                    vm.triggerRoutineGeneration()
                    vm.advance()
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .routineGeneration:
            RoutineGenerationScreen(
                vm: vm,
                onContinue: {
                    vm.advance()
                }
            )
            .transition(.opacity)

        case .showcase:
            ShowcaseScreen(
                vm: vm,
                onTrialStarted: {
                    vm.completeOnboarding()
                    AnalyticsService.shared.onboardingCompleted()
                    onComplete()
                }
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity
            ))
        }
    }

    // MARK: - Helpers

    private func checkExistingAttributes() async -> Bool {
        guard let uid = AuthService.shared.currentUser?.uid else { return false }
        do {
            let attrs = try await UserRepository.shared.getUserAttributes(userId: uid)
            return attrs?.fitnessLevel != nil && attrs?.workoutFrequency != nil
        } catch {
            return false
        }
    }

}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: {})
    }
}
#endif
