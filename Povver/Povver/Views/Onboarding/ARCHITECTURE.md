# Onboarding Module Architecture

## Overview

First-run onboarding flow: Welcome → Auth → Training Profile → Equipment → Trial → Routine Generation. Collects training profile, starts free trial, and generates an AI routine as the first "aha moment."

## File Structure

| File | Role |
|------|------|
| `OnboardingView.swift` | Root coordinator — ZStack with atmospheric layers + screen switching |
| `OnboardingViewModel.swift` | `@MainActor` state management — flow state, selections, persistence, trial, AI routine generation |
| `WelcomeScreen.swift` | Brand statement with wordmark and entrance animations |
| `OnboardingAuthScreen.swift` | Apple/Google/Email auth wrapping existing `AuthService` |
| `TrainingProfileScreen.swift` | Experience (3 cards) + frequency (5 circles) on one screen |
| `EquipmentScreen.swift` | Equipment selection with 400ms auto-advance |
| `TrialScreen.swift` | AI disclosure, feature list, trial CTA, skip option |
| `RoutineGenerationScreen.swift` | Two-phase animation: building → reveal with day cards |

Shared components in `UI/Components/`:
- `OnboardingGlowLayer.swift` — Persistent radial emerald glow with breathing animation
- `GrainTextureOverlay.swift` — 2% opacity noise texture via SwiftUI Canvas

## State Machine

```
OnboardingViewModel.Step enum:
  .welcome → .auth → .trainingProfile → .equipment → .trial → .routineGeneration
```

`advance()` moves forward one step with 0.3s transition guard. `goToStep()` jumps to any step. The `isTransitioning` flag prevents double-advance.

## Data Flow

1. User selections stored in `OnboardingViewModel` published properties
2. On equipment selection → `saveUserAttributes()` writes `UserAttributes` to Firestore
3. On "Start Free Trial" → `startFreeTrial()` triggers StoreKit purchase via `SubscriptionService`
4. On trial success → `triggerRoutineGeneration()` opens a canvas via `CanvasService`, streams a hyper-specific prompt via `DirectStreamingService`, and parses the `routine_summary` artifact. Falls back to static data on failure. The generation task is stored for cancellation on view disappear.
5. On completion → `completeOnboarding()` sets `hasCompletedOnboarding` UserDefaults flag
6. `onComplete(adjustWithCoach: Bool)` callback transitions `RootView` from `.onboarding` to `.main`

## Integration Points

- **RootView.swift**: `AppFlow.onboarding` case renders `OnboardingView`
- **MainTabsView.swift**: Accepts `adjustWithCoachContext` for post-onboarding canvas navigation
- **CoachTabView.swift**: Checks `initialCanvasContext` on appear for auto-navigation
- **AuthService.shared**: SSO sign-in with confirmation dialog for new accounts
- **SubscriptionService.shared**: StoreKit 2 product loading and purchase
- **UserRepository.shared**: Firestore persistence of `UserAttributes`
- **CanvasService**: Opens canvas conversations for agent routine generation
- **DirectStreamingService.shared**: SSE streaming for agent queries (60s timeout)
- **AnalyticsService.shared**: Onboarding funnel events (`onboardingStepViewed`, `onboardingProfileCompleted`, etc.)

## Visual Architecture

OnboardingView renders as a 5-layer ZStack:
1. `Color.bg` background
2. `OnboardingGlowLayer` — intensity/offset animate per step, never transitions out
3. `GrainTextureOverlay` — persistent subtle noise
4. Progress bar — 1pt emerald line, visible only on trainingProfile (50%) and equipment (100%)
5. Screen content — asymmetric transitions (fade+offset)
