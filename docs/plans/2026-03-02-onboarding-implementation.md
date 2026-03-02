# Onboarding Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the first-run onboarding experience — Welcome, Auth, Training Profile, Equipment, Trial, and AI Routine Generation — as described in `docs/plans/2026-03-02-onboarding-design.md`.

**Architecture:** A new `OnboardingView` coordinator manages a step-based flow using `@State` enum. Each step is a standalone screen View driven by a shared `OnboardingViewModel`. Auth reuses existing `AuthService`. Trial uses existing `SubscriptionService`. Routine generation calls the agent via `CanvasScreen` entry context. The `AppFlow` enum in `RootView` gains a new `.onboarding` case that gates new users.

**Tech Stack:** SwiftUI, Firebase Auth (existing), Firestore (existing UserAttributes model), StoreKit 2 (existing SubscriptionService), Vertex AI Agent Engine (existing streaming).

**Design doc:** `docs/plans/2026-03-02-onboarding-design.md` — refer to this for all visual specs, typography, colors, haptics, and animation details.

---

## Task 1: Onboarding Design System Components

Build the two reusable visual components that create the premium atmospheric feel across all onboarding screens.

**Files:**
- Create: `Povver/Povver/UI/Components/GrainTextureOverlay.swift`
- Create: `Povver/Povver/UI/Components/OnboardingGlowLayer.swift`

**Step 1: Create GrainTextureOverlay**

A noise texture overlay matching the landing page's grain effect (2% opacity SVG noise). Applied as a full-screen overlay on every onboarding screen.

```swift
// Povver/Povver/UI/Components/GrainTextureOverlay.swift
import SwiftUI

/// Noise texture overlay matching the landing page grain effect.
/// Apply as `.overlay(GrainTextureOverlay())` on onboarding screens.
struct GrainTextureOverlay: View {
    var body: some View {
        Canvas { context, size in
            // Draw noise pattern using random opacity dots
            for _ in 0..<Int(size.width * size.height * 0.003) {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let opacity = Double.random(in: 0.03...0.08)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        .allowsHitTesting(false)
        .drawingGroup() // Rasterize for performance
    }
}
```

**Step 2: Create OnboardingGlowLayer**

The persistent atmospheric emerald glow. Accepts an `intensity` parameter that varies per screen (0.12 default, 0.18 for trial, 0.25 for generation completion). Includes a breathing animation.

```swift
// Povver/Povver/UI/Components/OnboardingGlowLayer.swift
import SwiftUI

/// Persistent radial emerald glow layer for onboarding screens.
/// Intensity varies per screen to build energy toward the aha moment.
struct OnboardingGlowLayer: View {
    let intensity: Double
    let verticalOffset: CGFloat
    var breathing: Bool = true

    @State private var scale: CGFloat = 1.0

    var body: some View {
        RadialGradient(
            colors: [
                Color(hex: "22C59A").opacity(intensity),
                Color(hex: "22C59A").opacity(intensity * 0.4),
                Color.clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: 250
        )
        .scaleEffect(scale)
        .offset(y: verticalOffset)
        .blur(radius: 60)
        .allowsHitTesting(false)
        .onAppear {
            guard breathing else { return }
            withAnimation(
                .easeInOut(duration: 8)
                .repeatForever(autoreverses: true)
            ) {
                scale = 1.05
            }
        }
    }
}
```

**Step 3: Verify in Xcode preview**

Create a quick preview to confirm the glow and grain render correctly on `Color.bg` background. Both components should be subtle — the grain barely visible, the glow atmospheric, not distracting.

**Step 4: Commit**

```bash
git add Povver/Povver/UI/Components/GrainTextureOverlay.swift Povver/Povver/UI/Components/OnboardingGlowLayer.swift
git commit -m "feat(onboarding): add grain texture overlay and atmospheric glow components"
```

---

## Task 2: OnboardingViewModel

Central state management for the entire onboarding flow. Holds selections, persists UserAttributes, handles trial purchase, and manages flow state.

**Files:**
- Create: `Povver/Povver/ViewModels/OnboardingViewModel.swift`

**Step 1: Create OnboardingViewModel**

```swift
// Povver/Povver/ViewModels/OnboardingViewModel.swift
import SwiftUI
import Foundation

/// Manages onboarding flow state, user selections, and persistence.
@MainActor
final class OnboardingViewModel: ObservableObject {

    // MARK: - Flow State

    enum Step: Int, CaseIterable {
        case welcome, auth, trainingProfile, equipment, trial, routineGeneration
    }

    @Published var currentStep: Step = .welcome
    @Published var isTransitioning = false

    // MARK: - User Selections

    @Published var selectedExperience: String?    // "under_1_year" | "1_3_years" | "3_plus_years"
    @Published var selectedFrequency: Int?        // 2-6
    @Published var selectedEquipment: String?     // "commercial_gym" | "home_gym" | "minimal"

    // MARK: - Trial State

    @Published var isLoadingTrial = false
    @Published var trialError: String?

    // MARK: - Generation State

    @Published var isGenerating = false
    @Published var generatedRoutineName: String?
    @Published var generatedDays: [(day: Int, title: String, exerciseCount: Int, duration: Int)] = []
    @Published var generationComplete = false

    // MARK: - Computed

    var profileComplete: Bool {
        selectedExperience != nil && selectedFrequency != nil
    }

    /// Maps experience selection to fitnessLevel value stored in UserAttributes
    var fitnessLevel: String? {
        switch selectedExperience {
        case "under_1_year": return "beginner"
        case "1_3_years": return "intermediate"
        case "3_plus_years": return "advanced"
        default: return nil
        }
    }

    /// Maps equipment selection to equipment_preference value stored in UserAttributes
    var equipmentPreference: String? {
        switch selectedEquipment {
        case "commercial_gym": return "full_gym"
        case "home_gym": return "home_gym"
        case "minimal": return "bodyweight"
        default: return nil
        }
    }

    /// Glow intensity for current step (per design doc)
    var glowIntensity: Double {
        switch currentStep {
        case .trial: return 0.18
        case .routineGeneration: return generationComplete ? 0.25 : 0.12
        default: return 0.12
        }
    }

    /// Glow vertical offset for current step
    var glowOffset: CGFloat {
        switch currentStep {
        case .auth: return -120
        default: return 0
        }
    }

    /// Progress bar fraction (only shown on profile + equipment)
    var progressFraction: CGFloat? {
        switch currentStep {
        case .trainingProfile: return 0.5
        case .equipment: return 1.0
        default: return nil
        }
    }

    // MARK: - Navigation

    func advance() {
        guard !isTransitioning else { return }
        guard let nextIndex = Step(rawValue: currentStep.rawValue + 1) else { return }
        isTransitioning = true
        // Short delay for animation choreography
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentStep = nextIndex
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.isTransitioning = false
            }
        }
    }

    func goToStep(_ step: Step) {
        guard !isTransitioning else { return }
        isTransitioning = true
        withAnimation(.easeInOut(duration: 0.4)) {
            currentStep = step
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.isTransitioning = false
        }
    }

    // MARK: - Persistence

    /// Saves collected profile data to Firestore as UserAttributes.
    /// Called before trial screen or when skipping trial.
    func saveUserAttributes() async -> Bool {
        guard let userId = AuthService.shared.currentUser?.uid else { return false }

        // Infer unit preferences from device locale
        let isMetric = Locale.current.measurementSystem == .metric
        let weightFmt = isMetric ? "kilograms" : "pounds"
        let heightFmt = isMetric ? "centimeter" : "feet"

        let attrs = UserAttributes(
            id: userId,
            fitnessGoal: nil,
            fitnessLevel: fitnessLevel,
            equipment: equipmentPreference,
            height: nil,
            weight: nil,
            workoutFrequency: selectedFrequency,
            weightFormat: weightFmt,
            heightFormat: heightFmt,
            lastUpdated: nil
        )

        do {
            try await UserRepository.shared.saveUserAttributes(attrs)
            AnalyticsService.shared.log("onboarding_profile_saved", params: [
                "fitness_level": fitnessLevel ?? "unknown",
                "frequency": String(selectedFrequency ?? 0),
                "equipment": equipmentPreference ?? "unknown",
                "weight_format": weightFmt,
            ])
            return true
        } catch {
            AppLogger.shared.error(.app, "Failed to save onboarding attributes: \(error)")
            return false
        }
    }

    // MARK: - Trial

    /// Starts the free trial via StoreKit. Returns true on success.
    func startFreeTrial() async -> Bool {
        isLoadingTrial = true
        trialError = nil

        // Ensure products are loaded
        await SubscriptionService.shared.loadProducts()

        guard let product = SubscriptionService.shared.availableProducts.first else {
            trialError = "Unable to load subscription. Please try again."
            isLoadingTrial = false
            return false
        }

        let success = await SubscriptionService.shared.purchase(product)
        isLoadingTrial = false

        if !success {
            // User cancelled or error — don't block, let them retry or skip
            if let err = SubscriptionService.shared.error {
                switch err {
                case .purchaseCancelled:
                    trialError = nil // User cancelled intentionally, no error
                    return false
                default:
                    trialError = "Something went wrong. You can try again or continue with basic logging."
                }
            }
            return false
        }

        AnalyticsService.shared.log("onboarding_trial_started")
        return true
    }

    // MARK: - Onboarding Completion

    /// Marks onboarding as complete and persists the flag.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        AnalyticsService.shared.log("onboarding_completed", params: [
            "trial_started": String(SubscriptionService.shared.isPremium),
            "fitness_level": fitnessLevel ?? "unknown",
            "frequency": String(selectedFrequency ?? 0),
            "equipment": equipmentPreference ?? "unknown",
        ])
    }

    /// Marks onboarding as skipped (basic logging path).
    func skipToBasicLogging() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        AnalyticsService.shared.log("onboarding_skipped_to_basic")
    }

    // MARK: - Static Helpers

    /// Check if onboarding should be shown for the current user.
    static func shouldShowOnboarding() -> Bool {
        return !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
}
```

**Step 2: Verify it compiles**

Build the project to confirm `OnboardingViewModel` compiles correctly with all referenced types (`AuthService`, `UserRepository`, `SubscriptionService`, `AnalyticsService`, `UserAttributes`).

**Step 3: Commit**

```bash
git add Povver/Povver/ViewModels/OnboardingViewModel.swift
git commit -m "feat(onboarding): add OnboardingViewModel with flow state and persistence"
```

---

## Task 3: Welcome Screen

The brand statement screen — wordmark, subtitle, glow, staggered entrance animation.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/WelcomeScreen.swift`

**Step 1: Create WelcomeScreen**

```swift
// Povver/Povver/Views/Onboarding/WelcomeScreen.swift
import SwiftUI

struct WelcomeScreen: View {
    let onGetStarted: () -> Void
    let onSignIn: () -> Void

    @State private var showWordmark = false
    @State private var showSubtitle = false
    @State private var showCTA = false

    private let brandEasing = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.8)

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Wordmark + subtitle
            VStack(spacing: Space.md) {
                Text("POVVER")
                    .font(.system(size: 16, weight: .bold))
                    .tracking(2.24) // 0.14em at 16pt
                    .foregroundColor(.textPrimary)
                    .opacity(showWordmark ? 1 : 0)
                    .offset(y: showWordmark ? 0 : 20)

                Text("AI STRENGTH COACH")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.32) // 0.12em at 11pt
                    .textCase(.uppercase)
                    .foregroundColor(.accent)
                    .opacity(showSubtitle ? 1 : 0)
            }

            Spacer()

            // Bottom CTA area
            VStack(spacing: Space.lg) {
                PovverButton("Get Started", style: .primary) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onGetStarted()
                }

                Button {
                    onSignIn()
                } label: {
                    HStack(spacing: Space.xs) {
                        Text("Already have an account?")
                            .foregroundColor(.textTertiary)
                        Text("Sign in")
                            .foregroundColor(.accent)
                    }
                    .textStyle(.secondary)
                }
            }
            .opacity(showCTA ? 1 : 0)
            .offset(y: showCTA ? 0 : 20)
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xxl)
        }
        .onAppear {
            // Staggered entrance: glow → wordmark → subtitle → CTA
            withAnimation(brandEasing.delay(0.3)) { showWordmark = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.6)) { showSubtitle = true }
            withAnimation(brandEasing.delay(0.8)) { showCTA = true }
        }
    }
}
```

**Step 2: Preview and verify**

Confirm the staggered entrance animation looks right in Xcode preview on a dark background. The wordmark should slide up, the subtitle should fade in, and the CTA should slide up from below.

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/WelcomeScreen.swift
git commit -m "feat(onboarding): add WelcomeScreen with brand entrance animation"
```

---

## Task 4: Auth Screen (Onboarding Variant)

Wraps the existing auth logic with the onboarding visual treatment. Reuses `AuthService` methods directly.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/OnboardingAuthScreen.swift`

**Step 1: Create OnboardingAuthScreen**

This screen handles Create Account (primary flow) and Sign In (returning user). It reuses `AuthService` methods but with the onboarding dark canvas aesthetic. On successful auth, it calls `onAuthenticated()` which advances to the profile step.

Reference existing patterns from `LoginView.swift` and `RegisterView.swift` for the auth method calls and SSO confirmation flow. The view needs:

- Apple Sign-In button (white fill, Apple HIG)
- Google Sign-In button (dark surface)
- Email Sign-Up button (dark surface)
- Toggle between Create Account / Sign In modes
- SSO new-account confirmation dialog (existing pattern from LoginView)
- Email form sheet (email + password fields)

Keep the auth logic identical to the existing `LoginView`/`RegisterView` — only the visual treatment changes. Use `AuthService.shared.signUp()`, `.signIn()`, `.signInWithGoogle()`, `.signInWithApple()`.

**Step 2: Verify auth flow works**

Test all three auth methods in simulator. Confirm:
- Apple Sign-In → fires callback → onAuthenticated called
- Google Sign-In → fires callback → onAuthenticated called
- Email Sign-Up → form → creates account → onAuthenticated called
- Sign In mode toggle works

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/OnboardingAuthScreen.swift
git commit -m "feat(onboarding): add OnboardingAuthScreen with branded auth flow"
```

---

## Task 5: Training Profile Screen

Two questions (experience + frequency) on one screen with tap-based selection.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/TrainingProfileScreen.swift`

**Step 1: Create TrainingProfileScreen**

```swift
// Povver/Povver/Views/Onboarding/TrainingProfileScreen.swift
import SwiftUI

struct TrainingProfileScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onContinue: () -> Void

    @State private var showContinue = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private let experiences: [(id: String, label: String)] = [
        ("under_1_year", "Under a year"),
        ("1_3_years", "1 – 3 years"),
        ("3_plus_years", "3+ years"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            // Question 1: Experience
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Training experience")
                    .textStyle(.screenTitle)
                    .foregroundColor(.textPrimary)

                VStack(spacing: Space.sm) {
                    ForEach(experiences, id: \.id) { exp in
                        OnboardingSelectionCard(
                            title: exp.label,
                            isSelected: vm.selectedExperience == exp.id
                        ) {
                            haptic.impactOccurred()
                            withAnimation(.easeOut(duration: MotionToken.slow)) {
                                vm.selectedExperience = exp.id
                            }
                            checkShowContinue()
                        }
                    }
                }
            }

            // Question 2: Frequency
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Days per week")
                    .textStyle(.screenTitle)
                    .foregroundColor(.textPrimary)

                HStack(spacing: Space.md) {
                    ForEach(2...6, id: \.self) { n in
                        FrequencyCircle(
                            number: n,
                            isSelected: vm.selectedFrequency == n
                        ) {
                            haptic.impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                vm.selectedFrequency = n
                            }
                            checkShowContinue()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            // Continue button — appears after both selections
            if showContinue {
                PovverButton("Continue", style: .primary) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onContinue()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, Space.xxl)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xl)
    }

    private func checkShowContinue() {
        let shouldShow = vm.profileComplete
        if shouldShow && !showContinue {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                showContinue = true
            }
        }
    }
}

// MARK: - Selection Card

/// Reusable onboarding selection card with emerald left-border accent on selection.
struct OnboardingSelectionCard: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Emerald left indicator
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accent)
                    .frame(width: 3)
                    .opacity(isSelected ? 1 : 0)
                    .padding(.vertical, Space.sm)

                VStack(alignment: .leading, spacing: subtitle != nil ? Space.xs : 0) {
                    Text(title)
                        .textStyle(.bodyStrong)
                        .foregroundColor(isSelected ? .textPrimary : .textSecondary)

                    if let subtitle {
                        Text(subtitle)
                            .textStyle(.secondary)
                            .foregroundColor(.textTertiary)
                    }
                }
                .padding(.leading, Space.lg)
                .padding(.vertical, Space.lg)

                Spacer()
            }
            .background(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                    .fill(isSelected
                          ? Color(hex: "22C59A").opacity(0.06)
                          : Color(hex: "111820"))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Frequency Circle

struct FrequencyCircle: View {
    let number: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundColor(isSelected ? .black : .textSecondary)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accent : Color(hex: "111820"))
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
                                .opacity(isSelected ? 0 : 1)
                        )
                )
                .scaleEffect(isSelected ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
    }
}
```

**Step 2: Preview and verify interactions**

Confirm in preview: card selection shows emerald left-bar + background tint, frequency circles scale up with spring animation, Continue button slides up after both selections.

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/TrainingProfileScreen.swift
git commit -m "feat(onboarding): add TrainingProfileScreen with experience and frequency selectors"
```

---

## Task 6: Equipment Screen

Single question with auto-advance. Three taller cards.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/EquipmentScreen.swift`

**Step 1: Create EquipmentScreen**

```swift
// Povver/Povver/Views/Onboarding/EquipmentScreen.swift
import SwiftUI

struct EquipmentScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onSelected: () -> Void

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private let options: [(id: String, title: String, subtitle: String)] = [
        ("commercial_gym", "Commercial gym", "Full equipment"),
        ("home_gym", "Home gym", "Barbell & dumbbells"),
        ("minimal", "Minimal setup", "Bodyweight focused"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            Text("Where do you train?")
                .textStyle(.screenTitle)
                .foregroundColor(.textPrimary)

            VStack(spacing: Space.sm) {
                ForEach(options, id: \.id) { option in
                    OnboardingSelectionCard(
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: vm.selectedEquipment == option.id
                    ) {
                        haptic.impactOccurred()
                        withAnimation(.easeOut(duration: MotionToken.slow)) {
                            vm.selectedEquipment = option.id
                        }
                        // Auto-advance after 400ms
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            onSelected()
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xl)
    }
}
```

**Step 2: Preview and verify auto-advance**

Confirm card selection triggers emerald treatment, then auto-advances after 400ms delay.

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/EquipmentScreen.swift
git commit -m "feat(onboarding): add EquipmentScreen with auto-advance"
```

---

## Task 7: Trial Screen

AI disclosure, feature list, trial CTA, and skip option.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/TrialScreen.swift`

**Step 1: Create TrialScreen**

```swift
// Povver/Povver/Views/Onboarding/TrialScreen.swift
import SwiftUI

struct TrialScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onTrialStarted: () -> Void
    let onSkipped: () -> Void

    @State private var showFeatures = false

    private let features = [
        "Program generation",
        "Session analysis",
        "Progressive overload tracking",
        "900+ exercises",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Spacer()

            // Heading
            Text("Powered by AI")
                .textStyle(.appTitle)
                .foregroundColor(.textPrimary)

            // Description
            Text("Povver uses AI to build your programs and coach your sessions. A free trial starts today.")
                .textStyle(.body)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Feature list
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: Space.md) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.accent)

                        Text(feature)
                            .textStyle(.body)
                            .foregroundColor(.textPrimary)
                    }
                    .opacity(showFeatures ? 1 : 0)
                    .offset(y: showFeatures ? 0 : 10)
                    .animation(
                        .easeOut(duration: 0.4)
                        .delay(Double(index) * 0.1),
                        value: showFeatures
                    )
                }
            }

            // After-trial note
            Text("After your trial, logging stays free.")
                .textStyle(.secondary)
                .foregroundColor(.textTertiary)

            Spacer()

            // CTA area
            VStack(spacing: Space.lg) {
                // Start Free Trial button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task {
                        let success = await vm.startFreeTrial()
                        if success {
                            onTrialStarted()
                        }
                    }
                } label: {
                    HStack {
                        if vm.isLoadingTrial {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text("Start Free Trial")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                }
                .disabled(vm.isLoadingTrial)

                // Error
                if let error = vm.trialError {
                    Text(error)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                }

                // Legal + skip
                VStack(spacing: Space.md) {
                    Text("Cancel anytime in App Store settings")
                        .textStyle(.micro)
                        .foregroundColor(.textTertiary)

                    Button {
                        onSkipped()
                    } label: {
                        Text("Continue with basic logging")
                            .textStyle(.secondary)
                            .foregroundColor(.textTertiary)
                    }
                }
            }
            .padding(.bottom, Space.xxl)
        }
        .padding(.horizontal, Space.lg)
        .onAppear {
            withAnimation { showFeatures = true }
            // Pre-load StoreKit products while user reads
            Task { await SubscriptionService.shared.loadProducts() }
        }
    }
}
```

**Step 2: Test trial flow**

In simulator with StoreKit sandbox:
- "Start Free Trial" → StoreKit sheet appears → confirm → onTrialStarted called
- Cancel StoreKit → stays on screen, no error shown
- "Continue with basic logging" → onSkipped called

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/TrialScreen.swift
git commit -m "feat(onboarding): add TrialScreen with AI disclosure and trial/skip paths"
```

---

## Task 8: Routine Generation Screen

The aha moment — two-phase animation showing AI building the routine.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/RoutineGenerationScreen.swift`

**Step 1: Create RoutineGenerationScreen**

This screen has two phases:
- **Phase 1:** "Building your program" with thinking indicator and parameter echo
- **Phase 2:** Routine name + day cards materialize, dual CTA appears

The actual routine generation happens via a dedicated onboarding endpoint or by initiating a canvas conversation with the right context. For the initial implementation, simulate the generation with a timer-paced reveal. The agent integration will be wired in Task 10.

```swift
// Povver/Povver/Views/Onboarding/RoutineGenerationScreen.swift
import SwiftUI

struct RoutineGenerationScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onStartTraining: () -> Void
    let onAdjustWithCoach: () -> Void

    @State private var phase: Int = 1  // 1 = building, 2 = reveal
    @State private var showTitle = false
    @State private var revealedDays: Int = 0
    @State private var showCTA = false
    @State private var parameterText = ""

    private let haptic = UINotificationFeedbackGenerator()

    /// Builds the parameter echo string from user selections
    private var parameterSummary: String {
        let level = vm.selectedExperience == "under_1_year" ? "Beginner"
            : vm.selectedExperience == "3_plus_years" ? "Advanced" : "Intermediate"
        let freq = "\(vm.selectedFrequency ?? 4) days"
        let equip = vm.selectedEquipment == "commercial_gym" ? "full equipment"
            : vm.selectedEquipment == "home_gym" ? "home gym" : "bodyweight"
        return "\(level) · \(freq) · \(equip)"
    }

    var body: some View {
        VStack(spacing: Space.xl) {
            if phase == 1 {
                // Phase 1: Building
                Spacer()

                VStack(spacing: Space.lg) {
                    Text("Building your program")
                        .textStyle(.screenTitle)
                        .foregroundColor(.textPrimary)

                    // Thinking dots
                    HStack(spacing: Space.sm) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.accent)
                                .frame(width: 6, height: 6)
                                .opacity(0.5)
                                .animation(
                                    .easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(i) * 0.2),
                                    value: phase
                                )
                        }
                    }

                    Text(parameterText)
                        .textStyle(.secondary)
                        .foregroundColor(.textSecondary)
                }
                .transition(.opacity)

                Spacer()

            } else {
                // Phase 2: Reveal
                VStack(alignment: .leading, spacing: Space.xl) {
                    // Header
                    if showTitle {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Your program")
                                .textStyle(.screenTitle)
                                .foregroundColor(.textSecondary)

                            if let name = vm.generatedRoutineName {
                                Text(name)
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color(hex: "22C59A"), Color(hex: "7CEFCE"), Color(hex: "22C59A")],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Day cards
                    VStack(spacing: Space.sm) {
                        ForEach(0..<min(revealedDays, vm.generatedDays.count), id: \.self) { i in
                            let day = vm.generatedDays[i]
                            HStack {
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Text("Day \(day.day)")
                                        .textStyle(.caption)
                                        .foregroundColor(.textTertiary)
                                    Text(day.title)
                                        .textStyle(.bodyStrong)
                                        .foregroundColor(.textPrimary)
                                }
                                Spacer()
                                Text("\(day.exerciseCount) exercises")
                                    .textStyle(.secondary)
                                    .foregroundColor(.textSecondary)
                            }
                            .padding(Space.lg)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                                    .fill(Color(hex: "111820"))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                                            .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
                                    )
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    Spacer()

                    // Dual CTA
                    if showCTA {
                        VStack(spacing: Space.lg) {
                            PovverButton("Start training", style: .primary) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onStartTraining()
                            }

                            Button {
                                onAdjustWithCoach()
                            } label: {
                                Text("Adjust with coach")
                                    .textStyle(.bodyStrong)
                                    .foregroundColor(.accent)
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, Space.xxl)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xl)
            }
        }
        .onAppear {
            startGenerationSequence()
        }
    }

    private func startGenerationSequence() {
        // Animate parameter text typing
        parameterText = parameterSummary

        // Transition to phase 2 after generation completes (or minimum 3s)
        // The actual generation is triggered by OnboardingView and sets vm.generatedDays
        // This waits for the data or times out with a minimum delay
        Task {
            // Wait for generation to complete with minimum 3s display
            let startTime = Date()
            while !vm.generationComplete {
                try? await Task.sleep(for: .milliseconds(200))
                // Safety timeout after 30s
                if Date().timeIntervalSince(startTime) > 30 { break }
            }

            // Ensure minimum 3s of phase 1
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 3 {
                try? await Task.sleep(for: .seconds(3 - elapsed))
            }

            // Transition to phase 2
            withAnimation(.easeInOut(duration: 0.5)) { phase = 2 }

            // Stagger reveal
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { showTitle = true }

            for i in 1...vm.generatedDays.count {
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    revealedDays = i
                }
            }

            // Completion
            try? await Task.sleep(for: .milliseconds(300))
            haptic.notificationOccurred(.success)
            vm.generationComplete = true

            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                showCTA = true
            }
        }
    }
}
```

**Step 2: Test with mock data**

Before wiring agent integration, test with mock data in the ViewModel:
```swift
// Temporary: set in OnboardingViewModel for testing
generatedRoutineName = "Upper / Lower"
generatedDays = [
    (1, "Upper Push", 6, 45),
    (2, "Lower", 5, 50),
    (3, "Upper Pull", 6, 45),
    (4, "Lower", 5, 50),
]
generationComplete = true
```

Verify: phase 1 shows for at least 3 seconds, phase 2 staggers in day cards, dual CTA appears after all cards land, haptic fires on completion.

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/RoutineGenerationScreen.swift
git commit -m "feat(onboarding): add RoutineGenerationScreen with two-phase reveal animation"
```

---

## Task 9: OnboardingView Coordinator

The root coordinator that ties all screens together with the atmospheric glow layer, grain texture, progress bar, and transitions.

**Files:**
- Create: `Povver/Povver/Views/Onboarding/OnboardingView.swift`

**Step 1: Create OnboardingView**

```swift
// Povver/Povver/Views/Onboarding/OnboardingView.swift
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
                onSignIn: { vm.advance() }  // Both paths go to auth
            )
            .transition(.asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .offset(y: -12))
            ))

        case .auth:
            OnboardingAuthScreen(
                onAuthenticated: {
                    AnalyticsService.shared.log("onboarding_auth_completed")
                    vm.advance()
                },
                onSignIn: {
                    // Returning user who signs in — check if they need onboarding
                    Task {
                        if await checkExistingAttributes() {
                            vm.completeOnboarding()
                            onComplete(false)
                        } else {
                            vm.advance() // New-ish user, continue onboarding
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
                // Save attributes before moving to trial
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
                    vm.advance() // Go to routine generation
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
                    onComplete(true) // Signal to open CanvasScreen
                }
            )
            .transition(.opacity)
        }
    }

    // MARK: - Helpers

    /// Check if user already has populated attributes (returning user)
    private func checkExistingAttributes() async -> Bool {
        guard let uid = AuthService.shared.currentUser?.uid else { return false }
        do {
            let attrs = try await UserRepository.shared.getUserAttributes(userId: uid)
            return attrs?.fitnessLevel != nil && attrs?.workoutFrequency != nil
        } catch {
            return false
        }
    }

    /// Trigger the AI agent to generate a routine based on collected profile data.
    /// Sets vm.generatedDays and vm.generationComplete when done.
    private func triggerRoutineGeneration() {
        Task {
            guard let uid = AuthService.shared.currentUser?.uid else { return }

            // Pre-warm the agent session
            SessionPreWarmer.shared.preWarmIfNeeded(userId: uid, trigger: "onboarding_generation")

            // Build the agent prompt from collected data
            let level = vm.fitnessLevel ?? "intermediate"
            let freq = vm.selectedFrequency ?? 4
            let equipment = vm.equipmentPreference ?? "full_gym"

            let prompt = """
            I just signed up. Here's my profile:
            - Experience: \(level)
            - Training frequency: \(freq) days per week
            - Equipment: \(equipment)

            Create a complete training routine for me. Use propose_routine to build it.
            """

            // For MVP: use a Firebase Function endpoint that calls the agent
            // and returns the generated routine data directly.
            // This avoids needing to set up a full CanvasScreen during onboarding.
            //
            // TODO: Wire to actual agent endpoint. For now, use mock data
            // to validate the UI flow end-to-end.
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
```

**Step 2: Verify the full flow in simulator**

Run through: Welcome → Get Started → Auth (use any method) → Training Profile (select experience + frequency) → Equipment (select, auto-advance) → Trial → Start Free Trial → Routine Generation → Start Training.

Verify:
- Glow persists across all transitions and never flickers
- Grain texture is visible but subtle
- Progress bar animates on profile and equipment screens
- Transitions use the asymmetric fade+offset
- Full flow completes without crashes

**Step 3: Commit**

```bash
git add Povver/Povver/Views/Onboarding/OnboardingView.swift
git commit -m "feat(onboarding): add OnboardingView coordinator with flow management"
```

---

## Task 10: RootView Integration

Wire the onboarding into the app's root navigation. Add `.onboarding` to `AppFlow` and route new users through it.

**Files:**
- Modify: `Povver/Povver/Views/RootView.swift`

**Step 1: Add `.onboarding` case to AppFlow and update RootView**

Changes to `RootView.swift`:
1. Add `.onboarding` to `AppFlow` enum
2. In `LoginView.onLogin` and `RegisterView.onRegister` closures: check `OnboardingViewModel.shouldShowOnboarding()` and route to `.onboarding` instead of `.main`
3. Add `case .onboarding:` to the switch — render `OnboardingView` with `onComplete` callback that transitions to `.main`
4. In `.onboarding`'s `onComplete`, handle the `adjustWithCoach` flag: if true, set state to navigate to `CanvasScreen` after entering `.main`
5. Move pre-warming to also fire on `.onboarding` → `.main` transition

```swift
// Updated AppFlow
enum AppFlow {
    case login
    case register
    case onboarding
    case main
}

// In RootView body, the login/register closures become:
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

// New case in switch:
case .onboarding:
    OnboardingView { adjustWithCoach in
        if adjustWithCoach {
            adjustWithCoachAfterOnboarding = true
        }
        selectedTabRaw = MainTab.coach.rawValue
        flow = .main
    }
```

Add `@State private var adjustWithCoachAfterOnboarding = false` and pass it through to `MainTabsView` or handle navigation via the existing `CoachTabView` entry context pattern.

**Step 2: Handle "Adjust with coach" navigation**

When `adjustWithCoachAfterOnboarding` is true, after transitioning to `.main`, automatically navigate to `CanvasScreen` with:
- `canvasId: nil` (new conversation)
- `purpose: "onboarding"`
- `entryContext: "freeform:I just finished setting up my profile and you generated a routine for me. Here's what I built. What would you change?"`

This can be passed to `MainTabsView` as an initial action, or set via `CoachTabView`'s existing `navigateToCanvas` + `entryContext` state.

**Step 3: Test all paths**

1. Fresh install → Welcome → Auth → Profile → Equipment → Trial → Start Trial → Generation → Start Training → lands on Coach tab
2. Fresh install → ... → Trial → Skip → lands on Coach tab (empty state)
3. Fresh install → ... → Generation → Adjust with coach → lands on Canvas with routine context
4. Existing user (has attributes) → Login → lands on main directly (skips onboarding)
5. Sign out → Sign in → lands on main directly (has `hasCompletedOnboarding` flag)

**Step 4: Commit**

```bash
git add Povver/Povver/Views/RootView.swift
git commit -m "feat(onboarding): integrate onboarding flow into RootView navigation"
```

---

## Task 11: Analytics Events

Add onboarding-specific analytics events to track funnel progression.

**Files:**
- Modify: `Povver/Povver/Services/AnalyticsService.swift`

**Step 1: Add onboarding analytics methods**

Add to AnalyticsService after the existing Authentication domain section (around line 147):

```swift
// =========================================================================
// MARK: - Domain: Onboarding
// =========================================================================

func onboardingStepViewed(step: String) {
    log("onboarding_step_viewed", params: ["step": step])
}

func onboardingProfileCompleted(fitnessLevel: String, frequency: Int, equipment: String) {
    log("onboarding_profile_completed", params: [
        "fitness_level": fitnessLevel,
        "frequency": String(frequency),
        "equipment": equipment,
    ])
}

func onboardingTrialStarted() {
    log("onboarding_trial_started")
}

func onboardingSkippedToBasic() {
    log("onboarding_skipped_to_basic")
}

func onboardingCompleted(trialStarted: Bool, adjustWithCoach: Bool) {
    log("onboarding_completed", params: [
        "trial_started": String(trialStarted),
        "adjust_with_coach": String(adjustWithCoach),
    ])
}

func onboardingRoutineGenerated(routineName: String, dayCount: Int) {
    log("onboarding_routine_generated", params: [
        "routine_name": routineName,
        "day_count": String(dayCount),
    ])
}
```

**Step 2: Wire analytics into OnboardingViewModel and screens**

Update `OnboardingViewModel.advance()` to call `onboardingStepViewed` with the step name. Update `completeOnboarding()` and `skipToBasicLogging()` to use the new specific methods instead of raw `log()` calls.

**Step 3: Commit**

```bash
git add Povver/Povver/Services/AnalyticsService.swift Povver/Povver/ViewModels/OnboardingViewModel.swift
git commit -m "feat(onboarding): add onboarding analytics events and wire into flow"
```

---

## Task 12: Agent Routine Generation Integration

Replace the mock routine data with actual agent-generated routines. This is the final piece — wiring the onboarding to the real AI agent.

**Files:**
- Modify: `Povver/Povver/Views/Onboarding/OnboardingView.swift` (the `triggerRoutineGeneration` method)
- Potentially modify: `Povver/Povver/ViewModels/OnboardingViewModel.swift`

**Step 1: Design the generation approach**

Two options to evaluate:

**Option A: Use existing CanvasScreen infrastructure.** Create a headless canvas (no UI), send the profile-based prompt via `DirectStreamingService.streamQuery()`, parse the `routine_summary` artifact from the SSE stream, extract day/exercise data, and populate the ViewModel. This reuses all existing agent infrastructure but requires premium subscription (which was just started).

**Option B: Create a dedicated Firebase Function.** A new endpoint `generate-onboarding-routine` that takes profile data and returns a routine directly without SSE streaming. Simpler client-side code but requires a new backend endpoint.

**Recommendation: Option A** — reuses existing infrastructure, the user just started their trial so they have premium access, and the SSE stream provides natural "thinking" state for the animation.

**Step 2: Implement agent-based generation**

In `triggerRoutineGeneration()`, replace the mock data with:
1. Create a new canvas via `CanvasService.shared.openCanvas(userId:purpose:)`
2. Initialize session via `CanvasService.shared.initializeSession(canvasId:purpose:)`
3. Stream the prompt via `DirectStreamingService.shared.streamQuery()`
4. Parse `routine_summary` artifact from stream events
5. Extract routine name and day data into `vm.generatedDays`
6. Set `vm.generationComplete = true`

The prompt should include all collected profile data and instruct the agent to use `propose_routine`.

**Step 3: Handle edge cases**

- Agent timeout (>30s): show fallback with "Let's build your routine together" → open Coach chat
- Network error: same fallback
- Agent returns unexpected format: same fallback
- User is not premium (trial failed silently): this path shouldn't be reachable, but guard anyway

**Step 4: Test end-to-end**

Full flow with real agent: verify routine data appears in the generation screen, routine is saved to Firestore, and appears on Coach tab after onboarding.

**Step 5: Commit**

```bash
git add Povver/Povver/Views/Onboarding/OnboardingView.swift
git commit -m "feat(onboarding): wire routine generation to real AI agent via SSE streaming"
```

---

## Task 13: Documentation Updates

Update architecture docs to reflect the new onboarding flow.

**Files:**
- Modify: `docs/SYSTEM_ARCHITECTURE.md` — add onboarding flow to user journey
- Modify: `docs/IOS_ARCHITECTURE.md` — document new Views/Onboarding/ directory and OnboardingViewModel
- Create: `Povver/Povver/Views/Onboarding/ARCHITECTURE.md` — Tier 2 module doc

**Step 1: Create Tier 2 doc for onboarding module**

Document file structure, flow state machine, data flow, and integration points.

**Step 2: Update Tier 1 docs**

Brief additions to system architecture noting the onboarding flow and its cross-layer touchpoints.

**Step 3: Commit**

```bash
git add docs/ Povver/Povver/Views/Onboarding/ARCHITECTURE.md
git commit -m "docs: add onboarding architecture documentation"
```
