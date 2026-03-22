# iOS Application Architecture (Povver)

> **Document Purpose**: Complete documentation of the Povver iOS application architecture. Written for LLM/agentic coding agents.

---

## Table of Contents

1. [Application Overview](#application-overview)
2. [App Entry and Navigation](#app-entry-and-navigation)
3. [Architecture Layers](#architecture-layers)
4. [Services Layer](#services-layer)
5. [Repositories Layer](#repositories-layer)
6. [Models](#models)
7. [ViewModels](#viewmodels)
8. [Views and UI](#views-and-ui)
9. [Conversation System](#conversation-system)
10. [Design System](#design-system)
11. [Directory Structure](#directory-structure)

---

## Application Overview

Povver is a SwiftUI-based iOS fitness coaching application. The app provides:
- AI-powered workout planning via the Conversation system
- Routine and template management
- Active workout tracking
- Real-time agent streaming with thinking/tool visualization

**Key Architectural Patterns:**
- MVVM (Model-View-ViewModel)
- Repository pattern for data access
- Singleton services for shared state
- Protocol-based abstractions for testability
- Async/await for all network operations

**Primary Technologies:**
- SwiftUI for UI
- Firebase Auth for authentication
- Firebase Firestore for data persistence
- Firebase Functions for backend API
- Firebase Crashlytics for crash reporting (tagged with userId)
- Agent Service on Cloud Run for AI agents (via SSE streaming)

---

## App Entry and Navigation

### Entry Point (`PovverApp.swift`)

```swift
@main
struct PovverApp: App {
    init() {
        FirebaseConfig.shared.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

### Navigation Flow (`RootView.swift`)

```
┌─────────────────┐
│    RootView     │
│                 │
│  AppFlow enum:  │
│  - login        │──► LoginView
│  - register     │──► RegisterView
│  - onboarding   │──► OnboardingView
│  - main         │──► MainTabsView
└─────────────────┘
```

RootView observes `AuthService.isAuthenticated` via `.onChange`. When auth state becomes `false` (sign-out, account deletion, token expiration), the flow reactively resets to `.login`. Login and register views check `OnboardingViewModel.shouldShowOnboarding()` — new users route to `.onboarding`, returning users go to `.main`.

### Onboarding Flow (`Views/Onboarding/`)

Six-screen first-run experience managed by `OnboardingView` (coordinator) and `OnboardingViewModel`:

```
Welcome → Auth → Training Profile → Equipment → Trial → Routine Generation
```

- **OnboardingView** is a ZStack with persistent atmospheric layers (glow, grain texture) and screen content that transitions
- **OnboardingViewModel** (`@StateObject`) holds flow state, user selections, and methods for saving attributes, starting trial, and completing onboarding
- `hasCompletedOnboarding` UserDefaults flag prevents re-showing on subsequent launches
- Post-onboarding paths: "Start training" → Coach tab, "Adjust with coach" → Coach tab with auto-navigation to ConversationScreen, "Skip" → Coach tab (no trial)
- See `Povver/Povver/Views/Onboarding/ARCHITECTURE.md` for module details

### Tab Structure (`MainTabsView.swift`)

| Tab | View | Purpose |
|-----|------|---------|
| Coach | `CoachTabView` | AI coaching with quick actions and recent chats |
| Train | `TrainTabView` | Start workout from routines/templates |
| Library | `LibraryView` | Browse exercise library |
| History | `HistoryView` | Completed workout history |
| More | `MoreView` | Settings hub: profile, activity, preferences, security, subscription |

**Recommendation badge**: `MoreView` shows a badge count on the Activity row when pending recommendations exist (premium only). Navigates to `ActivityView` for recommendation review with contextual auto-pilot toggle.

### Canvas Navigation

Navigation entry points use `conversationId` instead of `canvasId`:

- `ChatHomeView` navigates to `ConversationScreen` with `entryContext` (contains `conversationId`)
- `CoachTabView` navigates to `ConversationScreen` with `entryContext`
- `ConversationScreen` still exists (rename deferred to avoid large refactor)
- `ConversationViewModel` internally uses both `conversationId` and `canvasId` during migration phase

---

## Architecture Layers

```
┌──────────────────────────────────────────────────────────┐
│                        VIEWS                             │
│   SwiftUI Views (ConversationScreen, RoutinesListView, etc.)   │
├──────────────────────────────────────────────────────────┤
│                      VIEWMODELS                          │
│   Observable state + business logic                      │
│   (ConversationViewModel, RoutinesViewModel, etc.)             │
├──────────────────────────────────────────────────────────┤
│                       SERVICES                           │
│   Singleton managers for cross-cutting concerns          │
│   (AuthService, ConversationService, ChatService, etc.)        │
├──────────────────────────────────────────────────────────┤
│                     REPOSITORIES                         │
│   Data access abstraction over Firestore                 │
│   (UserRepository, TemplateRepository, etc.)             │
├──────────────────────────────────────────────────────────┤
│                       MODELS                             │
│   Codable structs matching Firestore schema              │
│   (User, Workout, Routine, Exercise, etc.)               │
└──────────────────────────────────────────────────────────┘
```

---

## Services Layer

### Core Services

| Service | Type | Purpose |
|---------|------|---------|
| `AuthService` | Singleton | Firebase Auth management |
| `SessionManager` | Singleton | User session state |
| `ConversationService` | Class | Canvas CRUD operations via Cloud Functions |
| `ChatService` | Singleton | Chat session management + streaming |
| `DirectStreamingService` | Singleton | SSE streaming to Agent Engine |
| `CloudFunctionService` | Class | Firebase Functions HTTP client |
| `SubscriptionService` | Singleton | StoreKit 2 subscription management: product loading, purchase, entitlement checking, Firestore sync |
| `RecommendationService` | Enum (static) | Accept/reject recommendations via `ApiClient.shared.postJSON("reviewRecommendation", ...)` |
| `AnalyticsService` | Singleton | GA4 analytics: ~53 typed events across 9 domains, 16 user properties, milestone events via `logOnce()`, UserDefaults-persisted counters with daily sync |
| `ApiClient` | Singleton | Generic HTTP client with auth |

### Managers

| Manager | Type | Purpose |
|---------|------|---------|
| `ActiveWorkoutManager` | Singleton | Live workout state management |
| `FocusModeWorkoutService` | ObservableObject | Active workout API: start, logSet, patchField, complete, cancel. Drains pending syncs before completion. |
| `WorkoutSessionLogger` | Singleton | Records every workout event to JSON on disk (`Documents/workout_logs/`). Auto-flushes on app background. Breadcrumbs to Crashlytics for crash correlation. |
| `BackgroundSaveService` | Singleton | Fire-and-forget background saves with observable sync state |
| `TemplateManager` | Singleton | Template editing state |
| `CacheManager` | Actor | Memory + disk caching |
| `DeviceManager` | Singleton | Device registration |
| `TimezoneManager` | Singleton | User timezone handling |

### Key Service Details

#### `AuthService`
- Manages Firebase Auth state via `Auth.auth().addStateDidChangeListener`
- Publishes `isAuthenticated` and `currentUser` — `RootView` reactively navigates to `.login` when `isAuthenticated` becomes false
- Supports three auth providers: Email/Password, Google Sign-In (via GoogleSignIn SDK), Apple Sign-In (via `ASAuthorizationController`)
- Multi-provider account management: link/unlink providers, reauthenticate per provider, provider data refresh via `reloadCurrentUser()`
- SSO flow uses `SSOSignInResult` enum: `.existingUser` (complete sign-in) vs `.newUser(userId, email, name)` (caller shows confirmation dialog before Firestore doc creation)
- Account deletion handles Apple token revocation before Firebase Auth deletion
- `friendlyAuthError(_:)` maps `AuthErrorCode` to user-facing strings
- See [Authentication System](#authentication-system) section for full architecture

#### `AppleSignInCoordinator`
- `@MainActor` class wrapping `ASAuthorizationController` delegate pattern into async/await
- Generates cryptographic nonce (SHA256) for Apple Sign-In security
- Returns `AppleSignInResult` with idToken, rawNonce, authorizationCode, fullName, email
- Stored as `@MainActor private let` on `AuthService` — persists across the sign-in flow to avoid premature deallocation (ASAuthorizationController holds a weak delegate reference)

#### `SubscriptionService`
- StoreKit 2 singleton managing App Store subscriptions
- `loadProducts()` — fetches available products from App Store
- `checkEntitlements()` — iterates `Transaction.currentEntitlements`, derives status, syncs positive entitlements to Firestore (never syncs free/expired to avoid overwriting webhook-set state)
- `purchase(_ product:)` — generates UUID v5 `appAccountToken` from Firebase UID, passes to `product.purchase(options:)`, verifies, finishes, syncs to Firestore
- `restorePurchases()` — `AppStore.sync()` then `checkEntitlements()`
- `isEligibleForTrial(_ product:)` — checks introductory offer eligibility for dynamic CTA text
- `isPremium` computed property: `subscriptionState.isPremium` (checks `override == "premium"` OR `tier == .premium`)
- Publishes `subscriptionState: UserSubscriptionState`, `availableProducts`, `isLoading`, `isTrialEligible`, `error`
- Transaction.updates listener started in `init` — handles renewals, expirations, refunds while app is running
- `loadOverrideFromFirestore()` — reads `subscription_override` field so `isPremium` reflects admin grants
- UUID v5 generation uses DNS namespace (RFC 4122) — same constant used in webhook for deterministic matching

#### `DirectStreamingService`
- Streams to Agent Service (Cloud Run) via Firebase Function proxy (`streamAgentNormalized`)
- **Premium gate**: checks `SubscriptionService.shared.isPremium` before opening SSE connection; throws `StreamingError.premiumRequired` if false
- Parses SSE events into `StreamEvent` objects (maps `error` JSON field to `content` for uniform downstream handling)
- Handles markdown sanitization and deduplication
- Returns `AsyncThrowingStream<StreamEvent, Error>`
- Parameter `conversationId` passed to backend
- SSE contract uses 9 event types: `thinking`, `thought`, `tool_start`, `tool_end`, `message_start`, `text`, `artifact`, `message_end`, `error`

#### `ConversationService` (Partially DEPRECATED)
- ~~`bootstrapCanvas(userId, purpose)`~~ - (REMOVED — canvas system replaced by conversations)
- ~~`openCanvas(userId, purpose)`~~ - (REMOVED — no session init needed)
- ~~`initializeSession(canvasId, purpose)`~~ - (REMOVED — sessions eliminated)
- ~~`purgeCanvas(userId, canvasId)`~~ - (REMOVED)

#### `ActiveWorkoutManager`
- Manages live workout state (`ActiveWorkout`)
- Tracks workout duration, exercises, sets
- Converts `ActiveWorkout` to Firestore `Workout` on completion
- Calculates per-exercise and per-muscle analytics

#### `BackgroundSaveService`
- `@MainActor ObservableObject` singleton decoupling UI from slow backend saves
- Edit views submit an operation via `save(entityId:operation:)` and dismiss immediately
- Publishes `pendingSaves: [String: PendingSave]` — keyed by entity ID, value contains `FocusModeSyncState` (`.pending` / `.failed(message)`)
- List rows observe `isSaving(entityId)` to show a spinner instead of a chevron
- Detail view toolbars switch between Edit / Syncing spinner / Retry based on sync state
- Detail views use `.onChange(of: syncState)` to auto-reload fresh data when the save completes
- Guards against duplicate saves for the same entity — second call is ignored while one is in flight
- Used by: `WorkoutEditView`, `TemplateDetailView`, `RoutineDetailView`, `HistoryView`, `TemplatesListView`, `RoutinesListView`

---

## Repositories Layer

All repositories extend data access with type-safe Firestore operations:

| Repository | Collection(s) | Purpose |
|------------|---------------|---------|
| `UserRepository` | `users`, `users/{id}/attributes` | User profile and preferences |
| `WorkoutRepository` | `users/{id}/workouts` | Completed workout history. `getWorkoutCount()` uses Firestore server-side aggregation for efficient counting. |
| `TemplateRepository` | `users/{id}/templates` | Workout templates |
| `RoutineRepository` | `users/{id}/routines` | Routines (template sequences) |
| `RecommendationRepository` | `users/{id}/agent_recommendations` | Agent recommendation listener (singleton, Firestore snapshot) |
| `ExerciseRepository` | `exercises` | Global exercise catalog |

### `BaseRepository`

Provides retry logic with exponential backoff via `retry.swift`:
```swift
func withRetry<T>(
    maxAttempts: Int = 3,
    operation: @escaping () async throws -> T
) async throws -> T
```

---

## Models

### Core Domain Models

| Model | Purpose | Key Fields |
|-------|---------|------------|
| `AuthProvider` | Firebase provider mapping | `rawValue` (Firebase providerID), `displayName`, `icon`, `firestoreValue` |
| `User` | User profile | `id`, `email`, `displayName`, `createdAt`, `appleAuthorizationCode` |
| `UserAttributes` | User preferences | `weightFormat`, `heightFormat`, `timezone` |
| `Workout` | Completed workout | `id`, `userId`, `exercises`, `startedAt`, `completedAt`, `analytics` |
| `WorkoutTemplate` | Reusable workout plan | `id`, `name`, `exercises`, `userId` |
| `Routine` | Ordered template sequence | `id`, `name`, `templateIds`, `frequency`, `isActive` |
| `Exercise` | Exercise catalog entry | `id`, `name`, `primaryMuscles`, `equipment`, `instructions` |
| `ActiveWorkout` | In-progress workout | `exercises`, `startTime`, `workoutDuration` |
| `ActiveWorkoutDoc` | Firestore-synced active state | `userId`, `canvasId`, `state` |
| `MuscleGroup` | Muscle group enumeration | Used by Exercise model |
| `AgentRecommendation` | Agent recommendation | `id`, `trigger`, `recommendation`, `state`, `target` — nested: `RecommendationTarget`, `RecommendationDetail`, `RecommendationChange` |
| `SubscriptionTier` | Subscription tier enum | `free`, `premium` |
| `SubscriptionStatusValue` | Subscription status enum | `free`, `trial`, `active`, `expired`, `gracePeriod` |
| `UserSubscriptionState` | Aggregated subscription state | `isPremium` computed from override or tier |

### Canvas Models (`UI/Canvas/Models.swift`)

| Model | Purpose |
|-------|---------|
| `CanvasCardModel` | Universal card container |
| `CardType` | Enum: `session_plan`, `routine_summary`, `visualization`, `clarify_questions`, etc. |
| `CardLane` | Enum: `planning`, `analysis`, `execution` |
| `CardStatus` | Enum: `pending`, `active`, `accepted`, `rejected`, `completed` |
| `CanvasCardData` | Tagged union for card-specific content |

### Streaming Models

| Model | Purpose |
|-------|---------|
| `StreamEvent` | SSE event with type, content, metadata |
| `StreamEvent.EventType` | Enum including `.artifact` for proposed cards |
| `ChatMessage` | Chat UI message with author, content, timestamp |
| `AgentProgressState` | Tool execution progress tracking |
| `WorkspaceEvent` | Workspace events from agent |

---

## ViewModels

| ViewModel | Views | Responsibilities |
|-----------|-------|------------------|
| `ConversationViewModel` | `ConversationScreen`, card views | Canvas state, SSE artifact handling, card lifecycle |
| `RoutinesViewModel` | `RoutinesListView`, detail views | Routine CRUD, active routine management |
| `RecommendationsViewModel` | `ActivityView`, `MoreView` (badge) | Pending/recent recommendations, accept/reject actions, premium-gated listener |
| `ExercisesViewModel` | Exercise search | Exercise catalog fetching |

### `ConversationViewModel` (Primary)

**State:**
- `cards: [CanvasCardModel]` - All cards (built from SSE artifact events)
- `cardsByLane: [CardLane: [CanvasCardModel]]` - Cards grouped by lane
- `isLoading`, `isAgentProcessing`, `error`
- `canvasId`, `sessionId`, `userId`
- `agentProgress: AgentProgressState`

**Key Methods:**
- `bootstrap()` - Create/resume canvas, attach minimal listeners
- `sendMessage(_:)` - Invoke agent with message, stream SSE
- `buildCardFromArtifact(data: [String: Any])` - Convert artifact SSE event to `CanvasCardModel` via JSON round-trip decoding
- `handleIncomingStreamEvent(_:)` - Process SSE events, including `.artifact` case
- `acceptCard(_:)` / `dismissCard(_:)` - Proposal handling via `AgentsApi.artifactAction()`
- `startWorkout(from:)` - Begin active workout

**Firestore Listeners:**
- Workspace events (`workspace_events`)
- Active workout doc (`active_workouts/{canvasId}`)

**Notes:**
- No longer subscribes to Firestore `cards` collection — cards now come from SSE artifact events
- Artifact events carry card data in SSE payload, ViewModel decodes to `CanvasCardModel` and appends to `cards` array
- Card renderers unchanged — still take `CanvasCardModel` as input

---

## Views and UI

### Primary Screens

| Screen | File | Purpose |
|--------|------|---------|
| `ConversationScreen` | `Views/ConversationScreen.swift` | Main AI workspace |
| `ChatHomeEntry` | `Views/ChatHomeEntry.swift` | Chat session list |
| `ChatHomeView` | `Views/ChatHomeView.swift` | Chat conversation |
| `RoutinesListView` | `UI/Routines/RoutinesListView.swift` | Routine management |
| `TemplatesListView` | `UI/Templates/TemplatesListView.swift` | Template management |
| `MoreView` | `Views/Tabs/MoreView.swift` | Settings hub: profile, activity, preferences, security |
| `ActivityView` | `Views/Settings/ActivityView.swift` | Recommendations feed with auto-pilot toggle |
| `ProfileEditView` | `Views/Settings/ProfileEditView.swift` | Profile editing (account + body metrics) |
| `RecommendationCardView` | `Views/Recommendations/RecommendationCardView.swift` | Individual recommendation card with accept/decline + auto-pilot notice mode |
| `PaywallView` | `Views/PaywallView.swift` | Full-screen subscription purchase sheet |
| `SubscriptionView` | `Views/Settings/SubscriptionView.swift` | Subscription status and management |
| `LoginView` | `Views/LoginView.swift` | Email + SSO login |
| `RegisterView` | `Views/RegisterView.swift` | Email + SSO registration |

### Canvas Views

| View | Purpose |
|------|---------|
| `ConversationGridView` | Masonry grid layout for cards |
| `CardContainer` | Universal card wrapper with header/actions |
| `CardHeader` | Title, subtitle, status badge |
| `ThinkingBubble` | Gemini-style collapsible thinking process with live progress |
| `WorkoutRailView` | Horizontal workout exercise rail |
| `WorkspaceTimelineView` | Workspace events timeline |
| `StreamOverlay` | Streaming state overlay |

### Card Types

| Card View | Card Type | Purpose |
|-----------|-----------|---------|
| `SessionPlanCard` | `session_plan` | Workout plan with exercises |
| `RoutineSummaryCard` | `routine_summary` | Routine overview |
| `VisualizationCard` | `visualization` | Charts and tables |
| `AnalysisSummaryCard` | `analysis_summary` | Progress analysis |
| `ClarifyQuestionsCard` | `clarify_questions` | Agent clarification |
| `AgentStreamCard` | `agent_stream` | Streaming agent output |
| `ChatCard` | `chat` | Chat message |
| `SuggestionCard` | `suggestion` | Quick action suggestions |
| `SmallContentCard` | `text` | Simple text content |
| `RoutineOverviewCard` | `routine_overview` | Routine overview |
| `ListCardWithExpandableOptions` | `list_card` | Generic expandable list |

---

## Conversation System

The Conversation system is the primary AI interaction surface (renamed from "Canvas" system). It displays messages and inline artifacts, managing agent SSE streaming. Artifacts (workout plans, routines, analyses) are delivered via SSE events.

### Conversation Lifecycle

```
1. User opens Coach tab or starts new conversation
2. User sends first message → sendMessage()
3. Conversation doc created lazily on first message (no session init needed)
4. Agent streams SSE response → 9 event types
5. handleIncomingStreamEvent() processes events
6. Artifact events converted to CanvasCardModel (reuses renderers)
7. Cards appended to local state → UI refreshes
```

### Session Management (REMOVED)

Session pre-warming and initialization have been eliminated. The agent service is fully stateless. Conversations are created on first message — no `initializeSession`, `preWarmSession`, or `SessionPreWarmer` calls needed.

**Removed components**:
- `SessionPreWarmer.swift` (REMOVED)
- `ConversationService.initializeSession()` (REMOVED)
- `ConversationService.openCanvas()` (REMOVED)

### Card Actions

Cards can define actions in their `actions` and `menuItems` arrays:

| Action Type | Purpose |
|-------------|---------|
| `accept` | Accept proposed card via `artifactAction()` |
| `dismiss` | Dismiss proposed card via `artifactAction()` |
| `save_routine` | Save routine via `artifactAction()` |
| `start_workout` | Start workout via `artifactAction()` |
| `edit` | Open edit interface |
| `refine` | Open refinement sheet |
| `swap` | Open exercise swap sheet |

### Artifact Action Flow

Card lifecycle actions (accept, dismiss, save_routine, start_workout) now use `AgentsApi.artifactAction()`:

```
User taps Accept/Dismiss → ConversationViewModel.acceptCard() / dismissCard()
        │
        ▼
AgentsApi.artifactAction(artifactId: cardId, action: "accept" | "dismiss" | ...)
        │
        ▼
Backend processes action, returns result
        │
        ▼
ViewModel updates card status or removes from local state
```

### Artifact SSE Event Structure

Artifact events carry card data in SSE payload:

```json
{
  "type": "artifact",
  "artifact_id": "card-uuid",
  "data": {
    "id": "card-uuid",
    "type": "session_plan",
    "lane": "execution",
    "status": "pending",
    "title": "Push Day Workout",
    "data": { ... }
  }
}
```

`buildCardFromArtifact(data:)` converts `data` to `CanvasCardModel` via JSON round-trip:
1. Serialize `data` dict to JSON
2. Decode as `CanvasCardModel` (which is `Codable`)
3. Append to `cards` array

---

## Design System

### Design Principles

1. **Earned Color** — Emerald accent is reserved for meaningful moments: progress, achievements, CTAs, coach presence. Neutral tones dominate the baseline UI. Tab bar, chips, and avatars use neutral colors.
2. **Card Hierarchy** — Three tiers: Tier 0 (flat, no card), Tier 1 (surface + hairline stroke), Tier 2 (elevated + shadow + accent stroke for active items).
3. **Context-Aware Motion** — Snappy (0.3s) during workouts, gentle (0.5s) for browsing, bouncy (0.4s) for celebrations. Spring presets: `MotionToken.snappy`, `.gentle`, `.bouncy`.
4. **Agent Presence** — `CoachPresenceIndicator` provides a breathing emerald glow (8s cycle, 2s when thinking) to represent the AI coach as a living entity.

### Tokens (`UI/DesignSystem/Tokens.swift`)

Centralized design tokens — all visual values should reference tokens, not hard-coded values.

| Category | Token Enum | Key Values |
|----------|-----------|------------|
| Spacing | `Space` | `.xs(4)`, `.sm(8)`, `.md(12)`, `.lg(16)`, `.xl(24)`, `.xxl(32)` |
| Corner Radius | `CornerRadiusToken` | `.radiusIcon(10)`, `.radiusControl(12)`, `.radiusCard(16)`, `.pill(999)` |
| Typography | `TextStyle` enum + `.textStyle()` modifier | `.appTitle`, `.screenTitle`, `.sectionHeader`, `.body`, `.bodyStrong`, `.secondary`, `.caption`, `.micro`, `.sectionLabel`, `.metricL/M/S` |
| Colors | `Color` extensions | `.bg`, `.surface`, `.surfaceElevated`, `.accent`, `.textPrimary/Secondary/Tertiary`, `.bgWorkout` |
| Shadows | `ShadowsToken` | `.level1` (subtle), `.level2` (raised), `.level3` (prominent) |
| Motion | `MotionToken` | `.snappy`, `.gentle`, `.bouncy` (spring presets) |

**Typography:** Use `Text("...").textStyle(.body)` — the `TextStyle` enum is the single source of truth. `PovverTextStyle` and `PovverText` are deprecated.

**Corner Radius:** Use `radiusCard/radiusControl/radiusIcon/pill`. Legacy `small/medium/large/card` are deprecated.

### Interaction Tokens (`UI/DesignSystem/Tokens.swift`)

| Token | Value | Purpose |
|-------|-------|---------|
| `InteractionToken.disabledOpacity` | 0.4 | All disabled states |
| `InteractionToken.pressScale` | 0.97 | Button press feedback |
| `InteractionToken.pressBrightness` | -0.08 | Button press darkening |
| `InteractionToken.loadingDelay` | 300ms | Delay before showing spinner |
| `InteractionToken.buttonLoadingMinDisplay` | 600ms | Min spinner display on buttons |
| `InteractionToken.contentLoadingMinDisplay` | 400ms | Min spinner display in content |

### Motion Intents (`UI/DesignSystem/MotionIntent.swift`)

Five named animation intents, each with Reduce Motion fallbacks:

| Intent | Modifier | Animation | Reduce Motion |
|--------|----------|-----------|---------------|
| Respond | `.respondEffect(isPressed:)` | Scale 0.97 + brightness -0.08 | Same (not motion) |
| Reveal | `.revealEffect(isVisible:)` | Opacity + 8pt vertical shift | Opacity only |
| Morph | `.morphEffect(isTransformed:)` | Spring transition | 0.2s cross-fade |
| Exit | `.exitEffect(isExiting:edge:)` | Fade + slide to edge | Opacity only |
| Reflow | `.reflowEffect(trigger:)` | Position-only spring | Gentle 0.2s |

### Haptic Policy (`UI/DesignSystem/HapticPolicy.swift`, `Services/HapticManager.swift`)

- `ButtonHapticStyle` enum: `.light`, `.medium`, `.none`
- Default per button style: `.light` (primary), `.medium` (destructive), `.none` (secondary/ghost)
- `.buttonHaptic(_:)` view modifier overrides default for descendants
- **Rapid succession guard**: 200ms suppression window per category
- **Scroll suppression**: haptics suppressed during active scrolling via `.suppressHapticsWhileScrolling()`
- All haptic calls go through `HapticManager` — no raw `UIImpactFeedbackGenerator` usage

### Error Communication

| Pattern | Component | Behavior |
|---------|-----------|----------|
| Form submission | `InlineError` | Progressive copy (1st → 2nd attempt), coach escalation on 2nd failure |
| Data loading | `DataLoadingErrorView` | Content-area replacement, retry button, coach escalation |
| Sync errors | `SyncIndicator` | Per-row indicator (syncing/failed), bottom toast after 3+ retries |
| Destructive failure | System alert | "Try Again" / "Cancel" |

### Environment Values

| Key | Type | Purpose |
|-----|------|---------|
| `workoutActive` | `Bool` | Whether the view hierarchy is inside an active workout session. Injected by `MainTabsView`. |

### Services (Training Intelligence)

| Service | Purpose |
|---------|---------|
| `TrainingDataService` | Reads pre-computed training analytics from Firestore (`weekly_reviews`, `analysis_insights`, `analytics_rollups`). 5-minute in-memory cache. Singleton. |
| `CoachTabViewModel` | State machine for Coach tab: `newUser`, `workoutDay`, `restDay`, `postWorkout`, `returningAfterInactivity`. Derives state from routine cursor, training snapshot, and post-workout flag. |
| `HapticManager` | Centralized haptics with rapid succession guard, scroll suppression, guarded fire. `buttonTap()`, `selectionChanged()`, `modeToggle()`, `confirmAction()`, etc. |

### Components (`UI/Components/`)

| Component | Purpose |
|-----------|---------|
| `PovverButton` | Button with 5 states: idle, pressed, loading, loaded, disabled. Sync/async/external-loading inits. |
| `SurfaceCard` | Card container with elevation tiers |
| `CoachPresenceIndicator` | Breathing emerald glow — agent presence indicator |
| `TrainingConsistencyMap` | 12-week training consistency grid (signature visual) |
| `TrendDelta` / `PRBadge` | Earned-color trend indicators |
| `StaggeredEntrance` | View modifier for fade+slide entrance animations |
| `ProfileComponents` | ProfileRow, ProfileRowToggle, ProfileRowLinkContent, BadgeView |
| `AgentPromptBar` | Chat input with send button |
| `Banner` / `Toast` | Feedback components |
| `Chip` / `ChipGroup` | Filter chips (neutral selected state) |
| `PovverTextField` | Text field with 5 states: idle, focused, error, success, disabled |
| `InlineError` | Progressive error messages with coach escalation |
| `DataLoadingErrorView` | Content-area error state with retry |
| `UndoToast` | Timed undo action with auto-dismiss |
| `Spinner` / `StatusTag` | Auxiliary indicators |

---

## Authentication System

### Overview

Multi-provider authentication via Firebase Auth with three providers: Email/Password, Google Sign-In, Apple Sign-In. Accounts can have multiple linked providers. Firebase's "One account per email" setting auto-links providers that share an email address.

### Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ AuthService (singleton, ObservableObject)                      │
│                                                                │
│  @Published isAuthenticated: Bool                              │
│  @Published currentUser: FirebaseAuth.User?                    │
│  linkedProviders: [AuthProvider] (computed from providerData)  │
│                                                                │
│  ┌─────────────┐  ┌──────────────────────┐  ┌──────────────┐  │
│  │ Email/Pass  │  │ Google (GIDSignIn)   │  │ Apple (ASAuth│  │
│  │ signUp()    │  │ signInWithGoogle()   │  │ signInWith   │  │
│  │ signIn()    │  │ reauthWithGoogle()   │  │ Apple()      │  │
│  │ changePass()│  │ linkGoogle()         │  │ reauthWith   │  │
│  │ setPass()   │  │                      │  │ Apple()      │  │
│  │ resetPass() │  │                      │  │ linkApple()  │  │
│  └─────────────┘  └──────────────────────┘  └──────────────┘  │
│                                                                │
│  Shared: createUserDocument(), deleteAccount(), signOut()      │
│  Shared: reloadCurrentUser(), friendlyAuthError()              │
│  Shared: confirmSSOAccountCreation()                           │
└────────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────┐              ┌─────────────────────────┐
│  RootView       │              │  AppleSignInCoordinator  │
│  .onChange(of:   │              │  @MainActor              │
│  isAuthenticated)│              │  ASAuthorizationDelegate│
└─────────────────┘              │  nonce + SHA256          │
                                  └─────────────────────────┘
```

### AuthProvider Enum (`Models/AuthProvider.swift`)

Maps Firebase provider IDs to app-level identifiers. Three values:

| Case | rawValue | firestoreValue | Firebase providerID |
|------|----------|----------------|---------------------|
| `.email` | `"password"` | `"email"` | `password` |
| `.google` | `"google.com"` | `"google.com"` | `google.com` |
| `.apple` | `"apple.com"` | `"apple.com"` | `apple.com` |

- `rawValue` matches `currentUser.providerData[].providerID` — used by `AuthProvider.from()` and `unlinkProvider()`
- `firestoreValue` is written to `users/{uid}.provider` on account creation — uses `"email"` for readability instead of Firebase's `"password"`
- `displayName` and `icon` provide human-readable label and SF Symbol for UI

### SSO Sign-In Flow (Google and Apple)

Both Google and Apple follow the same `SSOSignInResult` pattern:

```
User taps "Sign in with Google/Apple"
        │
        ▼
AuthService.signInWithGoogle() / signInWithApple()
        │ Authenticate with provider SDK
        │ Sign in to Firebase Auth with credential
        │ Refresh user.providerData via reload()
        ▼
Check: Does Firestore user document exist?
        │
        ├─ YES → return .existingUser
        │         (complete sign-in, register device, init timezone)
        │
        └─ NO  → return .newUser(userId, email, name)
                  (caller shows confirmation dialog)
                          │
                          ▼
                  User confirms → confirmSSOAccountCreation()
                          │ Creates Firestore user doc
                          │ Stores apple_authorization_code if Apple
                          │
                  User cancels → authService.signOut()
                          │ Cleans up the Firebase Auth session
```

**Why the confirmation step**: Firebase creates the Auth account immediately on SSO sign-in. If the user didn't intend to create a Povver account, we sign them out. The Firestore user document is only created after explicit confirmation.

### Provider Data Refresh

Firebase's `currentUser.providerData` can be stale after sign-in or linking operations. This caused a bug where LinkedAccountsView showed Google as "available to link" when Firebase had already auto-linked it.

**Fix**: Call `user.reload()` followed by `self.currentUser = Auth.auth().currentUser` after every auth state change:
- After `signInWithGoogle()` and `signInWithApple()` — refreshes provider list after potential auto-linking
- After `linkGoogle()` and `linkApple()` — reflects the newly linked provider
- `reloadCurrentUser()` — utility called by `ProfileView.loadProfile()` and `LinkedAccountsView.task`

### Account Deletion Flow

```
DeleteAccountView
        │ Tap "Delete My Account"
        ▼
ReauthenticationView (required by Firebase)
        │ Verify with email/Google/Apple
        ▼
Confirmation dialog ("Delete Everything?")
        │
        ▼
AuthService.deleteAccount()
        │
        ├─ If Apple linked: read apple_authorization_code from Firestore
        │                    → Auth.auth().revokeToken() (App Store 5.1.1(v))
        │
        ├─ UserRepository.shared.deleteUser() (all subcollections)
        │
        ├─ user.delete() (Firebase Auth account)
        │
        └─ SessionManager.shared.endSession()
                │
                ▼
        RootView reactively navigates to .login
```

### Reauthentication

Sensitive operations (email change, password change, account deletion) require recent authentication. `ReauthenticationView` is a half-sheet that:
1. Reads `authService.linkedProviders` to determine which verification options to show
2. Shows password field if `.email` is linked
3. Shows "Verify with Google" / "Verify with Apple" buttons for SSO providers
4. On success, calls the `onSuccess` callback (which proceeds with the sensitive operation)

Email change and account deletion auto-trigger the reauth sheet when Firebase returns `requiresRecentLogin`.

### Password Management

Two modes based on linked providers:
- **Change Password** (has `.email` provider): Current password → reauthenticate → update password
- **Set Password** (SSO-only, no `.email`): New password → `user.link(with: EmailAuthProvider.credential)` — adds email/password as an additional provider

### Forgot Password

Standalone sheet from login screen. Sends Firebase password reset email via `Auth.auth().sendPasswordReset(withEmail:)`. Has two states: form (email input) and sent confirmation with "try again" option.

### Google Sign-In Setup

**Dependencies**: `GoogleSignIn` and `GoogleSignInSwift` SPM packages.

**Configuration**:
- URL scheme in `Info.plist`: reversed client ID from `GoogleService-Info.plist` (e.g., `com.googleusercontent.apps.919326069447-...`)
- `PovverApp.swift`: `.onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }` for redirect handling
- `UIApplication+RootVC.swift`: extension providing `rootViewController` for `GIDSignIn.signIn(withPresenting:)`

**Auth flow**: `GIDSignIn.signIn()` → extract `idToken` + `accessToken` → `GoogleAuthProvider.credential()` → `Auth.auth().signIn(with:)`

### Apple Sign-In Setup

**Dependencies**: `AuthenticationServices` framework (built-in), `CryptoKit` for SHA256 nonce.

**Configuration**:
- "Sign in with Apple" capability added in Xcode (Signing & Capabilities)
- Apple Developer portal: Services ID, Key with Sign in with Apple enabled
- Firebase Console: Apple provider configured with Services ID, Team ID, Key ID, private key

**Auth flow**: `ASAuthorizationController` → delegate callbacks → extract `identityToken` + `authorizationCode` → `OAuthProvider.appleCredential(withIDToken:rawNonce:fullName:)` → `Auth.auth().signIn(with:)`

**Apple-specific concerns**:
- `apple_authorization_code` stored in Firestore for token revocation on account deletion
- "Hide My Email" users get a private relay address — Firebase won't auto-link to existing email accounts
- Apple Private Email Relay requires registering the Firebase sender address in Apple Developer portal for email delivery

### Linked Accounts Management

`LinkedAccountsView` (push from ProfileView Security section):
- Shows currently linked providers with unlink option (disabled if only 1 provider remains)
- Shows available providers with link buttons
- Linking: calls `authService.linkGoogle()` / `linkApple()` / shows `PasswordChangeView` for email
- Unlinking: confirmation dialog → `authService.unlinkProvider()` → validates `providerData.count > 1`

### Error Handling

`AuthService.friendlyAuthError(_:)` maps `AuthErrorCode` to user-facing messages:

| AuthErrorCode | User Message |
|---------------|-------------|
| `.wrongPassword` | "Incorrect password. Please try again." |
| `.requiresRecentLogin` | "For your security, please sign in again to continue." |
| `.emailAlreadyInUse` | "This email is already in use by another account." |
| `.weakPassword` | "Password must be at least 6 characters." |
| `.accountExistsWithDifferentCredential` | "An account with this email already exists. Please sign in with your original method, then link this provider in Settings." |
| `.invalidCredential` | "The sign-in credentials are invalid. Please try again." |
| `.networkError` | "Network error. Please check your connection and try again." |
| `.credentialAlreadyInUse` | "This account is already linked to a different Povver account." |
| `.userNotFound` | "No account found with this email. Please register first." |
| default | "Something went wrong. Please try again." |

### File Map

| File | Purpose |
|------|---------|
| `Models/AuthProvider.swift` | Provider enum (email, google, apple) |
| `Services/AuthService.swift` | All auth logic: sign-in, sign-up, SSO, link/unlink, reauth, delete |
| `Services/AppleSignInCoordinator.swift` | ASAuthorizationController async/await wrapper |
| `Services/SessionManager.swift` | UserDefaults session persistence |
| `Extensions/UIApplication+RootVC.swift` | Root view controller for Google SDK |
| `UI/Components/ProfileComponents.swift` | Shared row components (ProfileRow, ProfileRowToggle, ProfileRowLinkContent, BadgeView) |
| `Views/RootView.swift` | Reactive auth state → navigation flow |
| `Views/LoginView.swift` | Email login + SSO buttons + forgot password |
| `Views/RegisterView.swift` | Email registration + SSO buttons |
| `Views/Tabs/MoreView.swift` | More tab hub with navigation to settings views |
| `Views/Settings/ActivityView.swift` | Recommendations feed + auto-pilot toggle |
| `Views/Settings/ProfileEditView.swift` | Profile editing (account + body metrics) |
| `Views/Settings/PreferencesView.swift` | Timezone, week start preferences |
| `Views/Settings/SecurityView.swift` | Security hub (linked accounts, password, delete) |
| `Views/Settings/ConnectedAppsView.swift` | MCP API key management (premium-gated) |
| `Views/Settings/ReauthenticationView.swift` | Multi-provider reauthentication sheet |
| `Views/Settings/EmailChangeView.swift` | Email change with verification |
| `Views/Settings/PasswordChangeView.swift` | Change or set password |
| `Views/Settings/ForgotPasswordView.swift` | Password reset email flow |
| `Views/Settings/LinkedAccountsView.swift` | Link/unlink provider management |
| `Views/Settings/DeleteAccountView.swift` | Account deletion with reauth + confirmation |

---

## Canvas to Conversations Migration

### Overview

The Canvas system has been migrated from Firestore-based card storage to SSE artifact events. This enables real-time card delivery without polling Firestore listeners.

### Key Changes

| Component | Before | After |
|-----------|--------|-------|
| Card source | Firestore `cards` subcollection | SSE artifact events |
| Card delivery | Firestore snapshot listeners | `StreamEvent.EventType.artifact` |
| Card conversion | Direct Firestore decode | `buildCardFromArtifact()` JSON round-trip |
| Card actions | `ConversationService.applyAction()` | `AgentsApi.artifactAction()` |
| Bootstrap | `openCanvas()` + Firestore listeners | `openCanvas()` + minimal listeners + SSE |
| Navigation param | `canvasId` | `conversationId` (with backward-compat `canvasId`) |

### Deleted Files

- `Repositories/ConversationRepository.swift` - No longer needed, cards from SSE
- `Services/PendingAgentInvoke.swift` - Dead code, `.take()` never called

### Renamed Parameters

- `DirectStreamingService.stream()`: `canvasId` → `conversationId`
- POST body includes both `conversationId` and `canvasId` for backward compatibility during backend migration

### Completed Renames

The Canvas → Conversation rename is complete:

- `CanvasViewModel` → `ConversationViewModel`
- `CanvasScreen` → `ConversationScreen`
- `CanvasGridView` → `ConversationGridView`
- `CanvasService` → `ConversationService`
- `CanvasRepository` → `ConversationRepository`
- Navigation uses `conversationId` (with backward-compat `canvasId` support in backend)
- Firestore schema migrated from `canvases` → `conversations`

---

## Directory Structure

```
Povver/Povver/
├── PovverApp.swift                 # App entry point
├── GoogleService-Info.plist        # Firebase config
├── Config/
│   ├── FirebaseConfig.swift        # Firebase initialization
│   └── StrengthOSConfig.swift      # Environment config
├── Extensions/
│   ├── String+Extensions.swift     # String helpers
│   └── UIApplication+RootVC.swift  # Root VC for Google Sign-In
├── Models/
│   ├── ActiveWorkout.swift
│   ├── ActiveWorkoutDoc.swift
│   ├── AuthProvider.swift          # Auth provider enum (email/google/apple)
│   ├── ChatMessage.swift
│   ├── Exercise.swift
│   ├── FocusModeModels.swift
│   ├── AgentRecommendation.swift  # Recommendation model + nested types
│   ├── MuscleGroup.swift
│   ├── Routine.swift
│   ├── StreamEvent.swift
│   ├── SubscriptionStatus.swift   # SubscriptionTier, SubscriptionStatusValue, UserSubscriptionState
│   ├── User.swift
│   ├── UserAttributes.swift
│   ├── Workout.swift
│   ├── WorkoutTemplate.swift
│   └── WorkspaceEvent.swift
├── Repositories/
│   ├── BaseRepository.swift
│   ├── ExerciseRepository.swift
│   ├── RecommendationRepository.swift  # Firestore listener for agent_recommendations
│   ├── retry.swift
│   ├── RoutineRepository.swift
│   ├── TemplateRepository.swift
│   ├── UserRepository.swift
│   └── WorkoutRepository.swift
├── Services/
│   ├── ActiveWorkoutManager.swift  # Live workout state
│   ├── AgentProgressState.swift    # Tool progress tracking
│   ├── AgentsApi.swift             # Agent invocation
│   ├── AnyCodable.swift            # Dynamic JSON coding
│   ├── ApiClient.swift             # HTTP client
│   ├── AppleSignInCoordinator.swift # Apple Sign-In async wrapper
│   ├── AuthService.swift           # Firebase Auth (multi-provider)
│   ├── CacheManager.swift          # Memory/disk cache
│   ├── CanvasActions.swift         # Action builders
│   ├── CanvasDTOs.swift            # Canvas data types
│   ├── ConversationService.swift         # Canvas API
│   ├── ChatService.swift           # Chat management
│   ├── CloudFunctionService.swift  # Firebase Functions
│   ├── DebugLogger.swift           # Logging utilities
│   ├── DeviceManager.swift         # Device registration
│   ├── ConversationService.swift   # Artifact actions
│   ├── DirectStreamingService.swift # SSE streaming
│   ├── Errors.swift                # Error types
│   ├── FirebaseService.swift       # Firestore abstraction
│   ├── Idempotency.swift           # Idempotency keys
│   ├── RecommendationService.swift # Accept/reject recommendations via API
│   ├── SessionManager.swift        # Session state
│   ├── SessionPreWarmer.swift      # (REMOVED — sessions eliminated)
│   ├── SubscriptionService.swift   # StoreKit 2 subscription management
│   ├── FocusModeWorkoutService.swift # Active workout API
│   ├── WorkoutSessionLogger.swift  # On-device event log
│   ├── TemplateManager.swift       # Template editing
│   └── TimezoneManager.swift       # Timezone handling
├── ViewModels/
│   ├── ConversationViewModel.swift       # Primary canvas VM
│   ├── ExercisesViewModel.swift
│   ├── RecommendationsViewModel.swift  # Recommendation state + accept/reject
│   ├── RoutinesViewModel.swift
│   └── WorkoutCoachViewModel.swift # Workout chat state
├── Views/
│   ├── ConversationScreen.swift          # Main canvas screen
│   ├── ChatHomeEntry.swift         # Chat entry
│   ├── ChatHomeView.swift          # Chat conversation
│   ├── ComponentGallery.swift      # Dev component gallery
│   ├── ConversationView.swift      # Main chat UI with inline artifacts
│   ├── LoginView.swift             # Email + SSO login
│   ├── MainTabsView.swift          # Tab navigation (5 tabs)
│   ├── RegisterView.swift          # Email + SSO registration
│   ├── Recommendations/
│   │   └── RecommendationCardView.swift   # Individual recommendation card (interactive + notice modes)
│   ├── PaywallView.swift           # Subscription purchase sheet
│   ├── RootView.swift              # App root (reactive auth nav)
│   ├── Tabs/
│   │   └── MoreView.swift          # Settings hub (profile, activity, preferences, security)
│   └── Settings/
│       ├── ARCHITECTURE.md              # Module architecture
│       ├── ActivityView.swift           # Recommendations feed + auto-pilot toggle
│       ├── ProfileEditView.swift        # Profile editing (account + body metrics)
│       ├── PreferencesView.swift        # Timezone, week start preferences
│       ├── SecurityView.swift           # Linked accounts, password, delete
│       ├── ReauthenticationView.swift   # Multi-provider reauth sheet
│       ├── EmailChangeView.swift        # Email change + verification
│       ├── PasswordChangeView.swift     # Change or set password
│       ├── ForgotPasswordView.swift     # Password reset flow
│       ├── LinkedAccountsView.swift     # Link/unlink providers
│       ├── DeleteAccountView.swift      # Account deletion
│       └── SubscriptionView.swift       # Subscription status & management
└── UI/
    ├── Canvas/
    │   ├── Models.swift            # Canvas card models
    │   ├── ConversationGridView.swift    # Masonry layout
    │   ├── CardContainer.swift     # Card wrapper
    │   ├── CardHeader.swift
    │   ├── ThinkingBubble.swift     # Agent thinking bubble
    │   ├── WorkoutRailView.swift
    │   ├── WorkspaceTimelineView.swift
    │   ├── Charts/                 # Chart components
    │   │   ├── BarChartView.swift
    │   │   ├── LineChartView.swift
    │   │   ├── RankedTableView.swift
    │   │   └── VisualizationModels.swift
    │   └── Cards/
    │       ├── SessionPlanCard.swift
    │       ├── RoutineSummaryCard.swift
    │       ├── VisualizationCard.swift
    │       ├── AnalysisSummaryCard.swift
    │       ├── ClarifyQuestionsCard.swift
    │       ├── SmallContentCard.swift
    │       ├── RoutineOverviewCard.swift
    │       ├── ListCardWithExpandableOptions.swift
    │       ├── PlanCardSkeleton.swift
    │       ├── SetGridView.swift
    │       ├── ExerciseDetailSheet.swift
    │       └── Shared/
    │           ├── ExerciseActionsRow.swift
    │           ├── ExerciseRowView.swift
    │           ├── ExerciseSwapSheet.swift
    │           └── IterationActionsRow.swift
    ├── FocusMode/
    │   ├── ARCHITECTURE.md            # Module architecture
    │   ├── FocusModeWorkoutScreen.swift # Main workout screen
    │   ├── FocusModeSetGrid.swift      # Set grid + editing dock
    │   ├── FocusModeComponents.swift   # Shared components
    │   ├── FocusModeExerciseSearch.swift # Exercise search
    │   └── WorkoutCoachView.swift      # Compact gym chat UI
    ├── Components/
    │   ├── PovverButton.swift          # Button styles
    │   ├── MyonText.swift
    │   ├── SurfaceCard.swift
    │   ├── ProfileComponents.swift     # ProfileRow, ProfileRowToggle, ProfileRowLinkContent, BadgeView
    │   ├── DropdownMenu.swift
    │   └── ... (component library)
    ├── DesignSystem/
    │   ├── Tokens.swift            # Design tokens
    │   ├── Theme.swift             # Theme provider
    │   └── Validation.swift        # Input validation
    ├── Routines/
    │   ├── RoutinesListView.swift
    │   ├── RoutineDetailView.swift
    │   └── RoutineEditView.swift
    ├── Templates/
    │   ├── TemplatesListView.swift
    │   └── TemplateDetailView.swift
    └── Schemas/
        └── ... (JSON schemas for card types)
```
