import SwiftUI

struct OnboardingView: View {
    @StateObject private var vm = OnboardingViewModel()
    let onComplete: (_ adjustWithCoach: Bool) -> Void

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
                    vm.advance()
                },
                onSignIn: {
                    // Returning user — check if they already have attributes
                    Task {
                        if await checkExistingAttributes() {
                            vm.completeOnboarding()
                            onComplete(false)
                        } else {
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
                    vm.advance()
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .trial:
            TrialScreen(
                vm: vm,
                onTrialStarted: {
                    vm.advance()
                    triggerRoutineGeneration()
                },
                onSkipped: {
                    vm.skipToBasicLogging()
                    onComplete(false)
                }
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .routineGeneration:
            RoutineGenerationScreen(
                vm: vm,
                onStartTraining: {
                    vm.completeOnboarding()
                    onComplete(false)
                },
                onAdjustWithCoach: {
                    vm.completeOnboarding()
                    onComplete(true)
                }
            )
            .transition(.opacity)
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

    private func triggerRoutineGeneration() {
        Task {
            guard let uid = AuthService.shared.currentUser?.uid else { return }

            SessionPreWarmer.shared.preWarmIfNeeded(userId: uid, trigger: "onboarding_generation")

            let freq = vm.selectedFrequency ?? 4

            // TODO: Wire to actual agent endpoint. For now, use mock data
            // to validate the UI flow end-to-end.
            // When connected: pass vm.fitnessLevel and vm.selectedFrequency to agent
            try? await Task.sleep(for: .seconds(2))

            await MainActor.run {
                vm.generatedRoutineName = freq <= 3
                    ? "Full Body \(freq)x"
                    : "Upper / Lower"
                vm.generatedDays = (1...freq).map { day in
                    let title: String
                    if freq <= 3 {
                        title = "Full Body \(["A", "B", "C", "D", "E", "F"][day - 1])"
                    } else {
                        title = day % 2 == 1 ? "Upper" : "Lower"
                    }
                    return (day: day, title: title, exerciseCount: Int.random(in: 5...7), duration: Int.random(in: 40...55))
                }
                vm.generationComplete = true
            }
        }
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: { _ in })
    }
}
#endif
