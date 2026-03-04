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
                    AnalyticsService.shared.onboardingCompleted(trialStarted: true, adjustWithCoach: false)
                    onComplete(false)
                },
                onAdjustWithCoach: {
                    vm.completeOnboarding()
                    AnalyticsService.shared.onboardingCompleted(trialStarted: true, adjustWithCoach: true)
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

    /// Triggers AI routine generation via the shell agent.
    /// Opens a canvas, streams a hyper-specific prompt, and parses the routine_summary artifact.
    /// Falls back to opening Coach chat if generation fails.
    private func triggerRoutineGeneration() {
        vm.isGenerating = true
        Task {
            guard let uid = AuthService.shared.currentUser?.uid else {
                vm.isGenerating = false
                return
            }

            let level = vm.fitnessLevel ?? "intermediate"
            let freq = vm.selectedFrequency ?? 4
            let equipment = vm.equipmentPreference ?? "full_gym"

            // Hyper-specific prompt: gives the agent all context upfront so it can
            // call propose_routine directly without follow-up questions.
            let prompt = """
            New user onboarding. Create a training routine with these exact parameters:
            - Experience level: \(level)
            - Training frequency: \(freq) days per week
            - Equipment access: \(equipment)
            - Goal: hypertrophy (muscle building)

            Use propose_routine to build it. Pick an appropriate split for the frequency \
            (\(freq <= 3 ? "full body" : freq <= 4 ? "upper/lower" : "push/pull/legs or upper/lower")). \
            Choose exercises from the catalog appropriate for the equipment level. \
            Set reps in the 8-12 range, RIR 2-3 for \(level) level. \
            Do not ask any questions — generate the routine immediately.
            """

            do {
                // Create a canvas for the onboarding conversation
                let canvasService = CanvasService()
                let (canvasId, sessionId) = try await canvasService.openCanvas(
                    userId: uid,
                    purpose: "onboarding"
                )

                let correlationId = UUID().uuidString

                // Stream the prompt and parse events
                var foundArtifact = false
                for try await event in DirectStreamingService.shared.streamQuery(
                    userId: uid,
                    conversationId: canvasId,
                    message: prompt,
                    correlationId: correlationId,
                    sessionId: sessionId,
                    timeoutSeconds: 60
                ) {
                    if event.eventType == .artifact {
                        let artifactType = event.content?["artifact_type"]?.value as? String
                        guard artifactType == "routine_summary" else { continue }

                        let artifactContent = event.content?["artifact_content"]?.value as? [String: Any] ?? [:]

                        let routineName = artifactContent["name"] as? String ?? "Your Program"
                        let workoutsRaw = artifactContent["workouts"] as? [[String: Any]] ?? []

                        let days: [(day: Int, title: String, exerciseCount: Int, duration: Int)] = workoutsRaw.enumerated().map { index, workout in
                            let title = workout["title"] as? String ?? "Day \(index + 1)"
                            let exerciseCount = workout["exercise_count"] as? Int
                                ?? (workout["exercises"] as? [[String: Any]])?.count
                                ?? (workout["blocks"] as? [[String: Any]])?.count
                                ?? 5
                            let duration = workout["estimated_duration"] as? Int ?? 45
                            return (day: index + 1, title: title, exerciseCount: exerciseCount, duration: duration)
                        }

                        await MainActor.run {
                            vm.generatedRoutineName = routineName
                            vm.generatedDays = days
                            vm.generationComplete = true
                            vm.isGenerating = false
                        }

                        AnalyticsService.shared.onboardingStepViewed(step: "routine_generated")
                        foundArtifact = true
                    }

                    if event.eventType == .done && foundArtifact {
                        break
                    }
                }

                // If stream finished without an artifact, fall back to mock data
                if !foundArtifact {
                    AppLogger.shared.error(.app, "Onboarding routine generation: no artifact received")
                    await MainActor.run { applyFallbackRoutine(freq: freq) }
                }
            } catch {
                AppLogger.shared.error(.app, "Onboarding routine generation failed", error)
                await MainActor.run { applyFallbackRoutine(freq: freq) }
            }
        }
    }

    /// Fallback routine data when agent generation fails.
    /// Ensures the user still sees a result and can proceed.
    private func applyFallbackRoutine(freq: Int) {
        vm.generatedRoutineName = freq <= 3 ? "Full Body \(freq)x" : "Upper / Lower"
        vm.generatedDays = (1...freq).map { day in
            let title: String
            if freq <= 3 {
                title = "Full Body \(["A", "B", "C"][min(day - 1, 2)])"
            } else {
                title = day % 2 == 1 ? "Upper" : "Lower"
            }
            return (day: day, title: title, exerciseCount: 5, duration: 45)
        }
        vm.generationComplete = true
        vm.isGenerating = false
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: { _ in })
    }
}
#endif
