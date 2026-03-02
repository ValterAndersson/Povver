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

        isLoadingTrial = false
        return true
    }

    /// Marks onboarding as complete and logs analytics.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        AnalyticsService.shared.screenViewed("onboarding_completed")
    }

    /// Skips to basic logging and marks onboarding as complete.
    func skipToBasicLogging() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        AnalyticsService.shared.screenViewed("onboarding_skipped")
    }

    /// Checks if onboarding should be shown.
    static func shouldShowOnboarding() -> Bool {
        return !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
}
