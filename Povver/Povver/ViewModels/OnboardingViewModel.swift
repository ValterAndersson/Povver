import Foundation
import SwiftUI

/// Central state management for the onboarding flow.
/// Holds user selections, persists to Firestore, handles trial purchase, and manages flow state.
@MainActor
final class OnboardingViewModel: ObservableObject {

    // MARK: - Flow State

    enum Step: Int, CaseIterable {
        case welcome
        case auth
        case trainingProfile
        case equipment
        case trial
        case routineGeneration
    }

    @Published var currentStep: Step = .welcome
    @Published var isTransitioning = false

    // MARK: - User Selections

    @Published var selectedExperience: String?  // "under_1_year" | "1_3_years" | "3_plus_years"
    @Published var selectedFrequency: Int?      // 2-6
    @Published var selectedEquipment: String?   // "commercial_gym" | "home_gym" | "minimal"

    // MARK: - Trial State

    @Published var isLoadingTrial = false
    @Published var trialError: String?

    // MARK: - Generation State

    @Published var isGenerating = false
    @Published var generatedRoutineName: String?
    @Published var generatedDays: [(day: Int, title: String, exerciseCount: Int, duration: Int)] = []
    @Published var generationComplete = false

    // MARK: - Computed Properties

    var profileComplete: Bool {
        selectedExperience != nil && selectedFrequency != nil
    }

    var fitnessLevel: String? {
        guard let experience = selectedExperience else { return nil }
        switch experience {
        case "under_1_year": return "beginner"
        case "1_3_years": return "intermediate"
        case "3_plus_years": return "advanced"
        default: return nil
        }
    }

    var equipmentPreference: String? {
        guard let equipment = selectedEquipment else { return nil }
        switch equipment {
        case "commercial_gym": return "full_gym"
        case "home_gym": return "home_gym"
        case "minimal": return "bodyweight"
        default: return nil
        }
    }

    var glowIntensity: Double {
        if currentStep == .trial {
            return 0.18
        } else if currentStep == .routineGeneration && generationComplete {
            return 0.25
        }
        return 0.12
    }

    var glowOffset: CGFloat {
        return currentStep == .auth ? -120 : 0
    }

    var progressFraction: CGFloat? {
        switch currentStep {
        case .trainingProfile: return 0.5
        case .equipment: return 1.0
        default: return nil
        }
    }

    // MARK: - Generation Task (for cancellation)

    private var generationTask: Task<Void, Never>?

    // MARK: - Methods

    /// Advances to the next step with animation.
    /// Guards against double-advance with isTransitioning flag.
    func advance() {
        guard !isTransitioning else { return }

        let allSteps = Step.allCases
        guard let currentIndex = allSteps.firstIndex(of: currentStep),
              currentIndex < allSteps.count - 1 else { return }

        isTransitioning = true
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = allSteps[currentIndex + 1]
        }

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            isTransitioning = false
        }
    }

    /// Jumps to a specific step with animation.
    func goToStep(_ step: Step) {
        guard !isTransitioning else { return }

        isTransitioning = true
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
        }

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isTransitioning = false
        }
    }

    /// Creates UserAttributes from selections and saves to Firestore.
    /// Infers unit preferences from Locale.
    /// Returns true on success, false on failure.
    func saveUserAttributes() async -> Bool {
        guard let userId = AuthService.shared.currentUser?.uid else {
            return false
        }

        // Infer unit preferences from locale
        let isMetric = Locale.current.measurementSystem == .metric
        let weightFormat = isMetric ? "kilograms" : "pounds"
        let heightFormat = isMetric ? "centimeter" : "feet"

        let attributes = UserAttributes(
            id: userId,
            fitnessGoal: nil,
            fitnessLevel: fitnessLevel,
            equipment: equipmentPreference,
            height: nil,
            weight: nil,
            workoutFrequency: selectedFrequency,
            weightFormat: weightFormat,
            heightFormat: heightFormat,
            lastUpdated: Date()
        )

        do {
            try await UserRepository.shared.saveUserAttributes(attributes)

            // Log profile completion with all collected data
            if let level = fitnessLevel, let freq = selectedFrequency, let equip = equipmentPreference {
                AnalyticsService.shared.onboardingProfileCompleted(
                    fitnessLevel: level,
                    frequency: freq,
                    equipment: equip
                )
            }

            // Update analytics user property if fitness level is set
            if let level = fitnessLevel {
                AnalyticsService.shared.updateFitnessLevel(level)
            }

            return true
        } catch {
            print("[OnboardingViewModel] Failed to save user attributes: \(error)")
            return false
        }
    }

    /// Loads products and purchases the first available subscription.
    /// Handles trial purchase flow with error states.
    /// Returns true on successful purchase, false otherwise.
    func startFreeTrial() async -> Bool {
        guard AuthService.shared.currentUser != nil else {
            trialError = "Please sign in to start your trial"
            return false
        }

        isLoadingTrial = true
        trialError = nil

        // Load products
        await SubscriptionService.shared.loadProducts()

        guard let product = SubscriptionService.shared.availableProducts.first else {
            trialError = "Unable to load subscription options"
            isLoadingTrial = false
            return false
        }

        // Attempt purchase
        let success = await SubscriptionService.shared.purchase(product)

        // Handle errors (but not cancellation)
        if !success {
            if let error = SubscriptionService.shared.error {
                // Don't show error for cancellation
                if case .purchaseCancelled = error {
                    trialError = nil
                } else {
                    trialError = error.errorDescription
                }
            }
            isLoadingTrial = false
            return false
        }

        AnalyticsService.shared.onboardingTrialStarted()
        isLoadingTrial = false
        return true
    }

    /// Triggers AI routine generation via the shell agent.
    /// Opens a canvas, streams a hyper-specific prompt, and parses the routine_summary artifact.
    /// Falls back to fallback data if generation fails.
    func triggerRoutineGeneration() {
        isGenerating = true
        generationTask = Task {
            guard let uid = AuthService.shared.currentUser?.uid else {
                isGenerating = false
                return
            }

            let level = fitnessLevel ?? "intermediate"
            let freq = selectedFrequency ?? 4
            let equipment = equipmentPreference ?? "full_gym"

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
                let canvasService = CanvasService()
                let (canvasId, sessionId) = try await canvasService.openCanvas(
                    userId: uid,
                    purpose: "onboarding"
                )

                let correlationId = UUID().uuidString

                var foundArtifact = false
                for try await event in DirectStreamingService.shared.streamQuery(
                    userId: uid,
                    conversationId: canvasId,
                    message: prompt,
                    correlationId: correlationId,
                    sessionId: sessionId,
                    timeoutSeconds: 60
                ) {
                    // Check for cancellation between events
                    if Task.isCancelled { return }

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

                        generatedRoutineName = routineName
                        generatedDays = days
                        generationComplete = true
                        isGenerating = false

                        AnalyticsService.shared.onboardingStepViewed(step: "routine_generated")
                        foundArtifact = true
                    }

                    if event.eventType == .done && foundArtifact {
                        break
                    }
                }

                if !foundArtifact {
                    AppLogger.shared.error(.app, "Onboarding routine generation: no artifact received")
                    applyFallbackRoutine(freq: freq)
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.shared.error(.app, "Onboarding routine generation failed", error)
                    applyFallbackRoutine(freq: freq)
                }
            }
        }
    }

    /// Cancels any in-progress routine generation.
    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    /// Fallback routine data when agent generation fails.
    private func applyFallbackRoutine(freq: Int) {
        generatedRoutineName = freq <= 3 ? "Full Body \(freq)x" : "Upper / Lower"
        generatedDays = (1...freq).map { day in
            let title: String
            if freq <= 3 {
                title = "Full Body \(["A", "B", "C"][min(day - 1, 2)])"
            } else {
                title = day % 2 == 1 ? "Upper" : "Lower"
            }
            return (day: day, title: title, exerciseCount: 5, duration: 45)
        }
        generationComplete = true
        isGenerating = false
    }

    /// Marks onboarding as complete and logs analytics.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    /// Skips to basic logging and marks onboarding as complete.
    func skipToBasicLogging() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        AnalyticsService.shared.onboardingSkippedToBasic()
    }

    /// Checks if onboarding should be shown.
    static func shouldShowOnboarding() -> Bool {
        return !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
}
