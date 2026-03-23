import Foundation
import SwiftUI

/// Time-bounded flag for the post-onboarding Coach tab state.
/// Expires after 24 hours or when the first workout is completed.
struct OnboardingCompleteFlag: Codable {
    let timestamp: Date
    let routineName: String
    let conversationId: String?

    private static let key = "onboardingCompleteFlag"
    private static let ttl: TimeInterval = 86400 // 24 hours

    static func set(routineName: String, conversationId: String?) {
        let flag = OnboardingCompleteFlag(
            timestamp: Date(),
            routineName: routineName,
            conversationId: conversationId
        )
        if let data = try? JSONEncoder().encode(flag) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> OnboardingCompleteFlag? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let flag = try? JSONDecoder().decode(OnboardingCompleteFlag.self, from: data),
              Date().timeIntervalSince(flag.timestamp) < ttl
        else {
            return nil
        }
        return flag
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

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
        case routineGeneration
        case showcase
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

    // MARK: - Onboarding State for Deferred Save
    // Persisted to UserDefaults so force-quit doesn't lose them

    @Published var onboardingConversationId: String? {
        didSet { UserDefaults.standard.set(onboardingConversationId, forKey: "onboardingConversationId") }
    }
    @Published var onboardingArtifactId: String? {
        didSet { UserDefaults.standard.set(onboardingArtifactId, forKey: "onboardingArtifactId") }
    }
    @Published var generationFailed = false

    init() {
        // Restore persisted onboarding IDs (survives force-quit)
        onboardingConversationId = UserDefaults.standard.string(forKey: "onboardingConversationId")
        onboardingArtifactId = UserDefaults.standard.string(forKey: "onboardingArtifactId")
    }

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
        if currentStep == .showcase {
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
        case .trainingProfile: return 0.33
        case .equipment: return 0.66
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
            AppLogger.shared.error(.app, "Failed to save user attributes", error)
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

    /// Triggers AI routine generation via the dedicated onboarding endpoint.
    /// Server builds the prompt from structured parameters.
    /// Stores conversationId and artifactId for deferred save_routine after purchase.
    func triggerRoutineGeneration() {
        isGenerating = true
        generationFailed = false
        generationTask = Task {
            guard let uid = AuthService.shared.currentUser?.uid else {
                isGenerating = false
                generationFailed = true
                return
            }

            let level = fitnessLevel ?? "intermediate"
            let freq = selectedFrequency ?? 4
            let equipment = equipmentPreference ?? "full_gym"

            let canvasId = UUID().uuidString
            onboardingConversationId = canvasId

            do {
                var foundArtifact = false
                for try await event in DirectStreamingService.shared.streamOnboardingRoutine(
                    userId: uid,
                    conversationId: canvasId,
                    fitnessLevel: level,
                    frequency: freq,
                    equipment: equipment
                ) {
                    if Task.isCancelled { return }

                    if event.eventType == .artifact {
                        let artifactType = event.content?["artifact_type"]?.value as? String
                        guard artifactType == "routine_summary" else { continue }

                        // Capture artifact ID for deferred save
                        if let artId = event.content?["artifact_id"]?.value as? String {
                            onboardingArtifactId = artId
                        }

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
                    generationFailed = true
                    generationComplete = true
                    isGenerating = false
                    AnalyticsService.shared.onboardingGenerationFailed()
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.shared.error(.app, "Onboarding routine generation failed", error)
                    generationFailed = true
                    generationComplete = true
                    isGenerating = false
                    AnalyticsService.shared.onboardingGenerationFailed()
                }
            }
        }
    }

    /// Auto-saves the generated routine after trial purchase.
    /// Calls the existing save_routine artifact action.
    /// Returns true on success.
    func autoSaveRoutine() async -> Bool {
        guard let uid = AuthService.shared.currentUser?.uid,
              let conversationId = onboardingConversationId,
              let artifactId = onboardingArtifactId else {
            return false
        }

        do {
            _ = try await AgentsApi.artifactAction(
                userId: uid,
                conversationId: conversationId,
                artifactId: artifactId,
                action: "save_routine"
            )
            AnalyticsService.shared.onboardingRoutineAutoSaved()
            return true
        } catch {
            AppLogger.shared.error(.app, "Onboarding auto-save routine failed", error)
            AnalyticsService.shared.onboardingRoutineAutoSaveFailed()
            return false
        }
    }

    /// Cancels any in-progress routine generation.
    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    /// Marks onboarding as complete. Sets OnboardingCompleteFlag only when
    /// generation succeeded (artifactId != nil) so the Coach tab shows
    /// "You're all set" instead of "Let's build your program".
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        if !generationFailed, let routineName = generatedRoutineName {
            OnboardingCompleteFlag.set(
                routineName: routineName,
                conversationId: onboardingConversationId
            )
        }
        // Clear persisted onboarding IDs — no longer needed
        UserDefaults.standard.removeObject(forKey: "onboardingConversationId")
        UserDefaults.standard.removeObject(forKey: "onboardingArtifactId")
    }

    /// Checks if onboarding should be shown.
    static func shouldShowOnboarding() -> Bool {
        return !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
}
