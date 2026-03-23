# Onboarding Module Architecture

## Overview

First-run onboarding flow: Welcome → Auth → Training Profile → Equipment → Routine Generation → Showcase+Trial. Collects training profile, generates an AI routine (before purchase), presents feature showcase with trial activation, then auto-saves the routine after purchase.

## File Structure

| File | Role |
|------|------|
| `OnboardingView.swift` | Root coordinator — ZStack with atmospheric layers + screen switching |
| `OnboardingViewModel.swift` | `@MainActor` state management — flow state, selections, persistence, AI generation, deferred auto-save, trial purchase |
| `WelcomeScreen.swift` | Brand statement with wordmark and entrance animations |
| `OnboardingAuthScreen.swift` | Apple/Google/Email auth wrapping existing `AuthService` |
| `TrainingProfileScreen.swift` | Experience (3 cards) + frequency (5 circles) on one screen |
| `EquipmentScreen.swift` | Equipment selection with 400ms auto-advance, triggers routine generation |
| `RoutineGenerationScreen.swift` | Two-phase animation: building → reveal with day cards. Graceful failure state. |
| `ShowcaseScreen.swift` | Feature showcase (4 items) + trial purchase CTA. Hard gate. |

Shared components in `UI/Components/`:
- `OnboardingGlowLayer.swift` — Persistent radial emerald glow with breathing animation
- `GrainTextureOverlay.swift` — 2% opacity noise texture via SwiftUI Canvas

## State Machine

```
OnboardingViewModel.Step enum:
  .welcome → .auth → .trainingProfile → .equipment → .routineGeneration → .showcase
```

`advance()` moves forward one step. The `isTransitioning` flag prevents double-advance.

## Data Flow

1. User selections stored in `OnboardingViewModel` published properties
2. On equipment selection → `saveUserAttributes()` writes `UserAttributes` to Firestore
3. On equipment advance → `triggerRoutineGeneration()` calls dedicated `streamOnboardingRoutine` endpoint
4. Server builds prompt, writes conversational first message, proxies to agent
5. Client receives artifact via SSE, stores `conversationId` + `artifactId`
6. On Showcase → `startFreeTrial()` triggers StoreKit purchase
7. On purchase success → `autoSaveRoutine()` calls `artifactAction(save_routine)` to persist routine
8. `completeOnboarding()` sets UserDefaults flag + `OnboardingCompleteFlag`
9. `onComplete()` callback transitions `RootView` from `.onboarding` to `.main`

## Key Design Decisions

- **Dedicated streaming endpoint**: `streamOnboardingRoutine` is isolated from `streamAgentNormalized`. No premium gate. Atomic `usedOnboardingBypass` flag limits to one free call.
- **Server-side prompt**: Client sends structured params (level, frequency, equipment). Server builds the prompt — client can't abuse for arbitrary AI calls.
- **Deferred auto-save**: Routine is displayed during generation but not saved until after purchase. `save_routine` runs when user is premium.
- **No fallback routine**: If generation fails, graceful message shown. After purchase, Coach tab's `.newUser` state handles recovery.

## Integration Points

- **RootView.swift**: `AppFlow.onboarding` case renders `OnboardingView`
- **CoachTabViewModel.swift**: Checks `OnboardingCompleteFlag` for post-onboarding hero state
- **AuthService.shared**: SSO sign-in
- **SubscriptionService.shared**: StoreKit 2 product loading and purchase
- **UserRepository.shared**: Firestore persistence of `UserAttributes`
- **DirectStreamingService.shared**: `streamOnboardingRoutine()` for generation
- **AgentsApi.artifactAction()**: `save_routine` after purchase
- **AnalyticsService.shared**: Onboarding funnel events

## Visual Architecture

OnboardingView renders as a 5-layer ZStack:
1. `Color.bg` background
2. `OnboardingGlowLayer` — intensity/offset animate per step, never transitions out
3. `GrainTextureOverlay` — persistent subtle noise
4. Progress bar — 1pt emerald line, visible only on trainingProfile (33%) and equipment (66%)
5. Screen content — asymmetric transitions (fade+offset)
