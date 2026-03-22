# Input Interaction System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a unified interaction system across the Povver iOS app — motion intents, haptic policy, button states, ghost values, auto-advance, set completion signature, destructive action tiers, error communication, and structural loading states.

**Architecture:** Bottom-up — build design system foundation (motion intents, haptic policy, press/loading/disabled modifiers) first, then workout-specific interactions (ghost values, auto-advance, signature interaction), then app-wide polish (error communication, loading states, screen-by-screen fixes). Each task produces a buildable, committable unit.

**Tech Stack:** SwiftUI, UIKit haptics (UIImpactFeedbackGenerator, UINotificationFeedbackGenerator), Combine, async/await, Firebase/Firestore.

**Spec:** `docs/superpowers/specs/2026-03-22-input-interaction-system-design.md`

**Build command:** `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`

**Note on testing:** This plan is primarily UI interaction work (animations, haptics, press states). SwiftUI previews and build verification are the primary validation tools. Unit tests are used where pure logic exists (ghost value resolution, auto-advance ordering). Manual testing instructions are provided for sensory interactions.

---

## File Structure

### New Files

| File | Responsibility |
|------|----------------|
| `UI/DesignSystem/MotionIntent.swift` | 5 motion intent view modifiers (Respond, Reveal, Transform, Exit, Reflow) + Reduce Motion fallbacks |
| `UI/DesignSystem/HapticPolicy.swift` | Rapid succession guard, scroll suppression, `.buttonHaptic()` modifier |
| `UI/FocusMode/GhostValueResolver.swift` | Pure logic: resolve ghost values from last session / template / blank |
| `UI/FocusMode/SetCompletionEffect.swift` | Radial fill + pulse + stroke draw signature animation |
| `UI/Components/Feedback/InlineError.swift` | Reusable inline error with progressive copy and coach escalation |

### Modified Files

| File | Changes |
|------|---------|
| `UI/DesignSystem/Tokens.swift` | Add `DisabledOpacity` constant (0.4) |
| `UI/Components/PovverButton.swift` | Add `isLoading` binding, press state (scale 0.97), haptic integration, disabled = 40% opacity |
| `Services/HapticManager.swift` | Add `buttonTap(style:)`, rapid succession guard with timestamp tracking |
| `UI/FocusMode/FocusModeSetGrid.swift` | Ghost value display (40% opacity), set completion signature trigger |
| `UI/FocusMode/FocusModeComponents.swift` | `CompletionCircle` signature animation, `ExerciseCardContainer` contextual density |
| `UI/FocusMode/FocusModeExerciseSection.swift` | Contextual density (active/completed/upcoming), exercise completion choreography |
| `UI/FocusMode/FocusModeWorkoutScreen.swift` | Tier 1 undo for remove-exercise, auto-advance scroll, error banner → inline, workout finish haptic |
| `Services/FocusModeWorkoutService.swift` | Fetch last session data for ghost values, undo buffer for Tier 1 actions |
| `UI/FocusMode/FocusModeWorkoutHelpers.swift` | `WorkoutCompletionSummary` held beat + staggered timing alignment |
| `UI/Components/Inputs/AgentPromptBar.swift` | Light impact haptic on submit |
| `UI/Components/Feedback/Toast.swift` | No code change needed — already usable |
| `UI/Components/Feedback/UndoToast.swift` | Add auto-dismiss timer (5s) |
| `Views/LoginView.swift` | `isLoading` on PovverButton, progressive inline error, scroll-to-focus |
| `Views/RegisterView.swift` | Same as LoginView |
| `Views/Tabs/LibraryView.swift` | Search field focus behavior, detail view loading |
| `Views/Tabs/HistoryView.swift` | Load more button loading state |
| `Views/MainTabsView.swift` | Floating banner tap haptic |

---

## Phase 1: Design System Foundation

### Task 1: Motion Intent View Modifiers

Build the 5 motion intents as reusable SwiftUI view modifiers with automatic Reduce Motion fallbacks.

**Files:**
- Create: `Povver/Povver/UI/DesignSystem/MotionIntent.swift`
- Modify: `Povver/Povver/UI/DesignSystem/Tokens.swift`

**Reference:** Spec Section 2.1 (Five Motion Intents), Section 1.5 (Reduce Motion fallback)

- [ ] **Step 1: Add DisabledOpacity token to Tokens.swift**

Read `Povver/Povver/UI/DesignSystem/Tokens.swift`. Add after the `MotionToken` enum:

```swift
public enum InteractionToken {
    /// Universal disabled opacity (spec: 40%)
    public static let disabledOpacity: Double = 0.4
    /// Press scale factor
    public static let pressScale: CGFloat = 0.97
    /// Loading indicator delay before showing (ms)
    public static let loadingDelay: Duration = .milliseconds(300)
    /// Minimum loading indicator display time (ms)
    public static let loadingMinDisplay: Duration = .milliseconds(600)
}
```

- [ ] **Step 2: Create MotionIntent.swift with Respond modifier**

Create `Povver/Povver/UI/DesignSystem/MotionIntent.swift`:

```swift
import SwiftUI

// MARK: - Respond Intent
// Scale to 0.97 on press, immediate, releases on finger-up.
// Reduce Motion: no change (scale is not motion).

struct RespondEffect: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? InteractionToken.pressScale : 1.0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
    }
}

// MARK: - Reveal Intent
// Opacity 0->1 + 8pt vertical shift. Reduce Motion: opacity only.

struct RevealEffect: ViewModifier {
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (isVisible ? 0 : 8))
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.2)
                    : .easeIn(duration: MotionToken.medium),
                value: isVisible
            )
    }
}

// MARK: - Transform Intent
// System spring, element morphs. Reduce Motion: 0.2s cross-fade.

struct TransformEffect: ViewModifier {
    let isTransformed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.2)
                    : MotionToken.snappy,
                value: isTransformed
            )
    }
}

// MARK: - Exit Intent
// Opacity 1->0 + slide toward origin. Reduce Motion: opacity only.

struct ExitEffect: ViewModifier {
    let isExiting: Bool
    let edge: Edge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isExiting: Bool, edge: Edge = .bottom) {
        self.isExiting = isExiting
        self.edge = edge
    }

    func body(content: Content) -> some View {
        content
            .opacity(isExiting ? 0 : 1)
            .offset(y: reduceMotion ? 0 : exitOffset)
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.2)
                    : .easeOut(duration: MotionToken.fast),
                value: isExiting
            )
    }

    private var exitOffset: CGFloat {
        guard isExiting else { return 0 }
        switch edge {
        case .top: return -8
        case .bottom: return 8
        case .leading: return 0
        case .trailing: return 0
        }
    }
}

// MARK: - Reflow Intent
// Position-only ease-in-out. Never bouncy. Reduce Motion: instant.

struct ReflowEffect: ViewModifier {
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(
                reduceMotion ? nil : .easeInOut(duration: MotionToken.medium),
                value: trigger
            )
    }
}

// MARK: - View Extensions

public extension View {
    /// Respond intent: scale feedback on press
    func respondEffect(isPressed: Bool) -> some View {
        modifier(RespondEffect(isPressed: isPressed))
    }

    /// Reveal intent: fade-in + vertical shift for new content
    func revealEffect(isVisible: Bool) -> some View {
        modifier(RevealEffect(isVisible: isVisible))
    }

    /// Transform intent: spring animation for state changes
    func transformEffect(isTransformed: Bool) -> some View {
        modifier(TransformEffect(isTransformed: isTransformed))
    }

    /// Exit intent: fade-out + slide for removing content
    func exitEffect(isExiting: Bool, edge: Edge = .bottom) -> some View {
        modifier(ExitEffect(isExiting: isExiting, edge: edge))
    }

    /// Reflow intent: smooth position adjustment for layout changes
    func reflowEffect(trigger: Bool) -> some View {
        modifier(ReflowEffect(trigger: trigger))
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/DesignSystem/MotionIntent.swift Povver/Povver/UI/DesignSystem/Tokens.swift
git commit -m "feat(design): add motion intent modifiers and interaction tokens

Five motion intents (Respond, Reveal, Transform, Exit, Reflow) with
automatic Reduce Motion fallbacks. InteractionToken for press scale,
disabled opacity, loading thresholds."
```

---

### Task 2: Haptic Policy System

Enhance HapticManager with rapid succession guard, scroll suppression check, and a `.buttonHaptic()` view modifier for declarative haptic assignment.

**Files:**
- Modify: `Povver/Povver/Services/HapticManager.swift`
- Create: `Povver/Povver/UI/DesignSystem/HapticPolicy.swift`

**Reference:** Spec Section 2.3 (Override Rules), Section 4.1 (PovverButton haptic defaults)

- [ ] **Step 1: Read HapticManager.swift**

Read `Povver/Povver/Services/HapticManager.swift` to understand current implementation.

- [ ] **Step 2: Add rapid succession guard and buttonTap to HapticManager**

Add to `HapticManager`:

```swift
// MARK: - Rapid Succession Guard

/// Tracks last fire time per category to suppress rapid identical haptics.
/// Spec: "fire haptic on first event only within rapid succession window"
private static var lastFireTime: [String: Date] = [:]
private static let suppressionWindow: TimeInterval = 0.2 // 200ms

/// Fire a haptic only if the same category hasn't fired within the suppression window.
static func guardedFire(category: String, action: () -> Void) {
    let now = Date()
    if let last = lastFireTime[category], now.timeIntervalSince(last) < suppressionWindow {
        return // Suppress
    }
    lastFireTime[category] = now
    action()
}

/// Reset suppression state (e.g., when scroll ends or context changes)
static func resetSuppression() {
    lastFireTime.removeAll()
}

// MARK: - Button Haptics

/// Haptic for button taps. Uses guarded fire to prevent rapid succession.
static func buttonTap(style: ButtonHapticStyle) {
    switch style {
    case .light:
        guardedFire(category: "button") {
            lightImpact.prepare()
            lightImpact.impactOccurred()
        }
    case .medium:
        guardedFire(category: "button") {
            mediumImpact.prepare()
            mediumImpact.impactOccurred()
        }
    case .none:
        break
    }
}
```

Also add the `ButtonHapticStyle` enum either in HapticManager or in the new HapticPolicy file. Let's put it in HapticPolicy for cleaner separation.

- [ ] **Step 3: Create HapticPolicy.swift with ButtonHapticStyle and modifier**

Create `Povver/Povver/UI/DesignSystem/HapticPolicy.swift`:

```swift
import SwiftUI

/// Haptic intensity for button interactions.
/// Default per button style: .light (primary), .medium (destructive), .none (secondary/ghost)
public enum ButtonHapticStyle {
    case light
    case medium
    case none
}

// MARK: - Environment Key

private struct ButtonHapticKey: EnvironmentKey {
    static let defaultValue: ButtonHapticStyle? = nil // nil = use component default
}

public extension EnvironmentValues {
    /// Override the default haptic style for PovverButton
    var buttonHapticStyle: ButtonHapticStyle? {
        get { self[ButtonHapticKey.self] }
        set { self[ButtonHapticKey.self] = newValue }
    }
}

public extension View {
    /// Override the haptic feedback style for PovverButton descendants.
    /// - `.light`: subtle tap (default for primary)
    /// - `.medium`: stronger tap (default for destructive, use for high-stakes primary like "Start Session")
    /// - `.none`: silent (default for secondary/ghost)
    func buttonHaptic(_ style: ButtonHapticStyle) -> some View {
        environment(\.buttonHapticStyle, style)
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/Services/HapticManager.swift Povver/Povver/UI/DesignSystem/HapticPolicy.swift
git commit -m "feat(design): add haptic policy system with rapid succession guard

ButtonHapticStyle enum, .buttonHaptic() environment modifier,
HapticManager.guardedFire() for 200ms rapid succession suppression,
HapticManager.buttonTap(style:) for button haptics."
```

---

### Task 3: PovverButton Enhancement

Add press state (scale 0.97), loading state (300ms delay, pulsing dot, 600ms min display), haptic integration, and 40% disabled opacity.

**Files:**
- Modify: `Povver/Povver/UI/Components/PovverButton.swift`

**Reference:** Spec Section 4.1 (PovverButton states)

- [ ] **Step 1: Read PovverButton.swift**

Read `Povver/Povver/UI/Components/PovverButton.swift` completely. Understand current `ButtonStyle` implementation, color logic, and disabled state handling.

- [ ] **Step 2: Rewrite PovverButton with all interaction states**

The current button takes `action: @escaping () -> Void`. We need to support both sync and async actions, plus an external `isLoading` binding. The approach:

- Add optional `isLoading: Binding<Bool>?` parameter (for external control)
- Add `asyncAction: (() async -> Void)?` parameter (for automatic loading management)
- Keep existing `action: (() -> Void)?` for backward compat
- Add press state via `ButtonStyle`
- Add haptic via `ButtonHapticStyle` environment value
- Change disabled to 40% opacity

Replace the button style implementation:

```swift
import SwiftUI

public enum PovverButtonStyleKind {
    case primary, secondary, ghost, destructive

    /// Default haptic for this button style
    var defaultHaptic: ButtonHapticStyle {
        switch self {
        case .primary: return .light
        case .destructive: return .medium
        case .secondary, .ghost: return .none
        }
    }
}

public struct PovverButton: View {
    let title: String
    let style: PovverButtonStyleKind
    let leadingIcon: Image?
    let trailingIcon: Image?
    let action: (() -> Void)?
    let asyncAction: (() async -> Void)?
    @Binding var externalLoading: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonHapticStyle) private var hapticOverride
    @Environment(\.povverTheme) private var theme

    @State private var internalLoading = false
    @State private var showIndicator = false

    /// Whether the button is in loading state (external or internal)
    private var isLoading: Bool { externalLoading || internalLoading }

    /// Resolved haptic style: environment override > style default
    private var hapticStyle: ButtonHapticStyle {
        hapticOverride ?? style.defaultHaptic
    }

    // Sync action init (backward compatible)
    public init(
        _ title: String,
        style: PovverButtonStyleKind = .primary,
        leadingIcon: Image? = nil,
        trailingIcon: Image? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.action = action
        self.asyncAction = nil
        self._externalLoading = .constant(false)
    }

    // Async action init with automatic loading management
    public init(
        _ title: String,
        style: PovverButtonStyleKind = .primary,
        leadingIcon: Image? = nil,
        trailingIcon: Image? = nil,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.style = style
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.action = nil
        self.asyncAction = action
        self._externalLoading = .constant(false)
    }

    // External loading binding init
    public init(
        _ title: String,
        style: PovverButtonStyleKind = .primary,
        isLoading: Binding<Bool>,
        leadingIcon: Image? = nil,
        trailingIcon: Image? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.action = action
        self.asyncAction = nil
        self._externalLoading = isLoading
    }

    public var body: some View {
        Button {
            guard !isLoading else { return }
            HapticManager.buttonTap(style: hapticStyle)
            if let asyncAction {
                Task {
                    internalLoading = true
                    await asyncAction()
                    internalLoading = false
                }
            } else {
                action?()
            }
        } label: {
            HStack(spacing: Space.sm) {
                if let leadingIcon, !showIndicator {
                    leadingIcon.font(.system(size: 16, weight: .semibold))
                }

                if showIndicator {
                    PulsingDot()
                        .transition(.opacity)
                } else {
                    Text(title)
                        .textStyle(.bodyStrong)
                        .transition(.opacity)
                }

                if let trailingIcon, !showIndicator {
                    trailingIcon.font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: theme.buttonHeight)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .overlay(borderOverlay)
        }
        .buttonStyle(PovverPressStyle())
        .opacity(isEnabled ? (isLoading ? 0.7 : 1.0) : InteractionToken.disabledOpacity)
        .allowsHitTesting(isEnabled && !isLoading)
        .animation(.easeInOut(duration: MotionToken.fast), value: isEnabled)
        .animation(.easeInOut(duration: 0.2), value: showIndicator)
        .onChange(of: isLoading) { _, loading in
            handleLoadingChange(loading)
        }
    }

    // MARK: - Loading indicator management

    private func handleLoadingChange(_ loading: Bool) {
        if loading {
            // 300ms delay before showing indicator
            Task {
                try? await Task.sleep(for: InteractionToken.loadingDelay)
                guard isLoading else { return } // Still loading after delay?
                let showTime = Date()
                withAnimation { showIndicator = true }

                // Track show time for minimum display enforcement
                // (handled in the !loading branch)
                UserDefaults.standard.set(showTime.timeIntervalSince1970, forKey: "povver_loading_show_time")
            }
        } else {
            if showIndicator {
                // Enforce 600ms minimum display
                let showTimestamp = UserDefaults.standard.double(forKey: "povver_loading_show_time")
                let showTime = Date(timeIntervalSince1970: showTimestamp)
                let elapsed = Date().timeIntervalSince(showTime)
                let remaining = 0.6 - elapsed

                if remaining > 0 {
                    Task {
                        try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
                        withAnimation { showIndicator = false }
                    }
                } else {
                    withAnimation { showIndicator = false }
                }
            }
        }
    }

    // MARK: - Colors (preserve existing logic)

    private var foregroundColor: Color {
        guard isEnabled else { return .textTertiary }
        switch style {
        case .primary: return .textInverse
        case .secondary: return .textPrimary
        case .ghost: return .accent
        case .destructive: return .textInverse
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return style == .ghost ? .clear : .separatorLine
        }
        switch style {
        case .primary: return .accent
        case .secondary: return .surface
        case .ghost: return .clear
        case .destructive: return .destructive
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if style == .secondary {
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .strokeBorder(Color.separatorLine, lineWidth: StrokeWidthToken.thin)
        }
    }
}

// MARK: - Press Style (Respond intent)

private struct PovverPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? InteractionToken.pressScale : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Pulsing Dot (loading indicator)

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Theme

private struct PovverThemeKey: EnvironmentKey {
    static let defaultValue = PovverThemeValues()
}

struct PovverThemeValues {
    let buttonHeight: CGFloat = 50
    let hitTargetMin: CGFloat = 44
}

extension EnvironmentValues {
    var povverTheme: PovverThemeValues {
        get { self[PovverThemeKey.self] }
        set { self[PovverThemeKey.self] = newValue }
    }
}
```

**Important:** Before writing, read the existing file to check if `PovverThemeKey` / `PovverThemeValues` are defined elsewhere (e.g., `Theme.swift`). If so, don't duplicate — import from existing location. Also check all call sites of `PovverButton` in the codebase to ensure backward compatibility.

- [ ] **Step 3: Search for all PovverButton call sites**

Search the codebase for `PovverButton(` to verify all existing calls remain compatible. The key concern: the sync `action: () -> Void` init must still work without changes at call sites. Also search for `PovverThemeKey` and `PovverThemeValues` to avoid duplication.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/Components/PovverButton.swift
git commit -m "feat(button): add press state, loading indicator, haptic integration

Press: scale 0.97 via Respond intent. Loading: 300ms delay before
pulsing dot, 600ms min display. Haptic: light (primary), medium
(destructive), none (secondary/ghost), overridable via .buttonHaptic().
Disabled: 40% opacity. Supports sync, async, and external isLoading."
```

---

## Phase 2: Workout Core Interactions

### Task 4: Ghost Value Resolver

Pure logic for resolving what values to show in undone sets: last session > template prescription > blank.

**Files:**
- Create: `Povver/Povver/UI/FocusMode/GhostValueResolver.swift`
- Modify: `Povver/Povver/Services/FocusModeWorkoutService.swift`

**Reference:** Spec Section 3.1 (Ghost values), Section 8 (Ghost Values)

- [ ] **Step 1: Read FocusModeModels.swift to understand set/exercise models**

Read `Povver/Povver/Models/FocusModeModels.swift` to understand `FocusModeExercise`, `FocusModeSet`, and their fields.

- [ ] **Step 2: Create GhostValueResolver.swift**

```swift
import Foundation

/// Resolved ghost values for an undone set.
/// Display at 40% opacity. Tapping done accepts all ghost values.
/// Tapping a field replaces ghost with cursor.
struct GhostValues: Equatable {
    let weight: Double?
    let reps: Int?
    let rir: Int?

    /// Whether any ghost value is present
    var hasValues: Bool { weight != nil || reps != nil || rir != nil }

    static let empty = GhostValues(weight: nil, reps: nil, rir: nil)
}

/// Last session data for a specific exercise, used for ghost value resolution.
struct LastSessionExerciseData {
    let sets: [LastSessionSetData]
}

struct LastSessionSetData {
    let weight: Double?
    let reps: Int
    let rir: Int?
}

/// Resolves ghost values for undone sets in a workout exercise.
///
/// Priority: last session for this exercise > template prescription > blank
/// "Last session" = most recent completed workout containing this exercise.
enum GhostValueResolver {

    /// Resolve ghost values for all undone sets in an exercise.
    /// - Parameters:
    ///   - exercise: The current workout exercise
    ///   - lastSession: Data from the most recent session with this exercise (nil if no history)
    /// - Returns: Dictionary mapping set ID to ghost values
    static func resolve(
        exercise: FocusModeExercise,
        lastSession: LastSessionExerciseData?
    ) -> [String: GhostValues] {
        var result: [String: GhostValues] = [:]

        let undoneSets = exercise.sets.enumerated().filter { !$0.element.isDone }

        for (index, set) in undoneSets {
            // Skip sets that already have user-entered values
            if set.weight != nil || set.reps > 0 {
                result[set.id] = .empty
                continue
            }

            // Priority 1: Last session (matched by set index)
            if let lastSession, index < lastSession.sets.count {
                let lastSet = lastSession.sets[index]
                result[set.id] = GhostValues(
                    weight: lastSet.weight,
                    reps: lastSet.reps,
                    rir: lastSet.rir
                )
                continue
            }

            // Priority 2: Template prescription (already on the set as prescription fields)
            // These come from the template the workout was started from.
            // Check if the set model has prescription fields.
            result[set.id] = GhostValues(
                weight: set.prescribedWeight,
                reps: set.prescribedReps,
                rir: set.prescribedRir
            )
        }

        return result
    }
}
```

**Note:** The exact field names (`prescribedWeight`, `prescribedReps`, `prescribedRir`, `isDone`, `weight`, `reps`) must match the actual `FocusModeSet` model. Read `FocusModeModels.swift` first and adjust accordingly.

- [ ] **Step 3: Read FocusModeWorkoutService.swift for workout data flow**

Read `Povver/Povver/Services/FocusModeWorkoutService.swift` (focus on `startWorkout`, `logSet`, and any existing history/template data) to understand where to fetch last session data.

- [ ] **Step 4: Add last session fetch to FocusModeWorkoutService**

Add a method to fetch the most recent workout containing each exercise in the current workout. This data is fetched once when the workout starts and cached.

```swift
/// Cached last-session data for ghost values, keyed by exercise catalog ID.
@Published private(set) var lastSessionData: [String: LastSessionExerciseData] = [:]

/// Fetch last session data for all exercises in the current workout.
/// Called once after workout starts.
func fetchLastSessionData() async {
    guard let workout, let userId = AuthService.shared.currentUser?.uid else { return }

    let exerciseIds = Set(workout.exercises.map { $0.exerciseId })
    var result: [String: LastSessionExerciseData] = [:]

    for exerciseId in exerciseIds {
        // Query most recent completed workout containing this exercise
        if let lastWorkout = try? await WorkoutRepository.shared.getLastWorkoutWithExercise(
            userId: userId,
            exerciseId: exerciseId
        ) {
            if let exerciseData = lastWorkout.exercises.first(where: { $0.exerciseId == exerciseId }) {
                result[exerciseId] = LastSessionExerciseData(
                    sets: exerciseData.sets.map { set in
                        LastSessionSetData(
                            weight: set.weightKg,
                            reps: set.reps,
                            rir: set.rir
                        )
                    }
                )
            }
        }
    }

    await MainActor.run {
        self.lastSessionData = result
    }
}
```

**Note:** Check if `WorkoutRepository` already has a method like `getLastWorkoutWithExercise`. If not, add one that queries `users/{userId}/workouts` ordered by `completedAt` desc, filtered by exercise ID, limited to 1. The exact Firestore query depends on the workout document structure — read `Workout.swift` model and `WorkoutRepository.swift` first.

- [ ] **Step 5: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/GhostValueResolver.swift Povver/Povver/Services/FocusModeWorkoutService.swift
git commit -m "feat(workout): add ghost value resolver and last session fetch

GhostValueResolver resolves undone set values from last session >
template prescription > blank. FocusModeWorkoutService fetches last
session data for all exercises on workout start."
```

---

### Task 5: Ghost Value Display in Set Grid

Wire ghost values into FocusModeSetGrid — show resolved values at 40% opacity, accept on done tap, replace on field tap.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 3.1, Section 8

- [ ] **Step 1: Read FocusModeSetGrid.swift**

Read `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift` completely. Focus on how set values are displayed in cells (weight, reps, rir columns) and how the done cell interaction works.

- [ ] **Step 2: Add ghost values parameter to FocusModeSetGrid**

Add `ghostValues: [String: GhostValues]` parameter to `FocusModeSetGrid` init. In the cell rendering for weight/reps/rir:

- If the set is undone and the field is empty, show the ghost value at 40% opacity
- If the user taps a ghost-value cell, clear the ghost and enter editing mode
- In `doneCell` tap handler: if set has ghost values, call `onLogSet` with the ghost values before marking done

The exact code depends on how cells are currently rendered — this must be determined by reading the file.

- [ ] **Step 3: Pass ghost values from FocusModeWorkoutScreen**

In `FocusModeWorkoutScreen`, compute ghost values for each exercise section:

```swift
let ghostValues = GhostValueResolver.resolve(
    exercise: exercise,
    lastSession: service.lastSessionData[exercise.exerciseId]
)
```

Pass to `FocusModeSetGrid(exercise: exercise, ghostValues: ghostValues, ...)`.

Also call `service.fetchLastSessionData()` after workout starts in the `.task` or after `startWorkout()` completes.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Manual test**

Run the app in simulator. Start a workout from a template. Verify:
1. Undone sets show ghost values at 40% opacity (if prior workout data exists)
2. Tapping done accepts ghost values
3. Tapping a ghost-value cell enters editing with the ghost value cleared

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(workout): display ghost values at 40% opacity in set grid

Undone sets show last-session values as ghost text. Tap done to accept
all ghost values. Tap a field to clear ghost and edit manually."
```

---

### Task 6: Set Completion Signature Interaction

Replace the simple checkmark toggle with the full sensory signature: radial fill, pulse, stroke draw, row flash, haptic at peak.

**Files:**
- Create: `Povver/Povver/UI/FocusMode/SetCompletionEffect.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` (CompletionCircle)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift` (row flash)

**Reference:** Spec Section 3.3 (Signature Interaction), Section 2.2 (Set completed sensory signature)

- [ ] **Step 1: Read CompletionCircle in FocusModeComponents.swift**

Read the `CompletionCircle` struct in `Povver/Povver/UI/FocusMode/FocusModeComponents.swift`. Understand its current animation (spring pulse with emerald fill).

- [ ] **Step 2: Create SetCompletionEffect.swift**

```swift
import SwiftUI

/// The set completion signature animation.
/// Choreography (spec Section 3.3):
/// 1. Circle fills emerald from center outward (radial fill, 0.15s)
/// 2. Pulse scale 1.0 -> 1.15 -> 1.0 (system .bouncy spring)
/// 3. Light impact haptic at pulse peak (1.15)
/// 4. Checkmark draws in during settle (stroke animation, 0.2s)
/// 5. Row background emerald flash fades over 0.3s
struct SetCompletionCircle: View {
    let isComplete: Bool
    let onTap: () -> Void

    @State private var fillProgress: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var checkmarkProgress: CGFloat = 0
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let circleSize: CGFloat = 28

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                // Background circle
                Circle()
                    .strokeBorder(
                        isComplete || isAnimating ? Color.accent : Color.separatorLine,
                        lineWidth: 2
                    )
                    .frame(width: circleSize, height: circleSize)

                // Radial fill (emerald from center)
                Circle()
                    .fill(Color.accent)
                    .frame(
                        width: circleSize * fillProgress,
                        height: circleSize * fillProgress
                    )
                    .clipShape(Circle())

                // Checkmark stroke
                CheckmarkShape()
                    .trim(from: 0, to: checkmarkProgress)
                    .stroke(Color.textInverse, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 12)
            }
            .scaleEffect(pulseScale)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44) // Hit target
        .onChange(of: isComplete) { oldValue, newValue in
            if newValue && !oldValue {
                playCompletionAnimation()
            } else if !newValue && oldValue {
                resetAnimation()
            }
        }
        .onAppear {
            // Set initial state without animation for already-completed sets
            if isComplete {
                fillProgress = 1.0
                checkmarkProgress = 1.0
            }
        }
    }

    private func handleTap() {
        onTap()
    }

    private func playCompletionAnimation() {
        guard !reduceMotion else {
            // Reduce Motion: instant state change, keep haptic
            fillProgress = 1.0
            checkmarkProgress = 1.0
            HapticManager.setCompleted()
            return
        }

        isAnimating = true

        // Phase 1: Radial fill (0.15s)
        withAnimation(.easeOut(duration: 0.15)) {
            fillProgress = 1.0
        }

        // Phase 2: Pulse (at 0.15s, spring bounce) + haptic at peak
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                pulseScale = 1.15
            }
            // Haptic at pulse peak
            HapticManager.setCompleted()

            // Settle back
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    pulseScale = 1.0
                }
            }
        }

        // Phase 3: Checkmark stroke draw (during settle, 0.2s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.2)) {
                checkmarkProgress = 1.0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isAnimating = false
        }
    }

    private func resetAnimation() {
        withAnimation(.easeOut(duration: 0.15)) {
            fillProgress = 0
            checkmarkProgress = 0
            pulseScale = 1.0
            isAnimating = false
        }
    }
}

// MARK: - Checkmark Shape

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.15, y: h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.75))
        path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.25))
        return path
    }
}

// MARK: - Row Flash Effect

/// Subtle emerald flash on the row background after set completion.
struct SetCompletionRowFlash: ViewModifier {
    let trigger: Bool
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                Color.accent.opacity(flash ? 0.08 : 0)
                    .animation(.easeOut(duration: 0.3), value: flash)
            )
            .onChange(of: trigger) { _, newValue in
                guard newValue, !reduceMotion else { return }
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    flash = false
                }
            }
    }
}

extension View {
    func setCompletionFlash(trigger: Bool) -> some View {
        modifier(SetCompletionRowFlash(trigger: trigger))
    }
}
```

- [ ] **Step 3: Replace CompletionCircle usage in FocusModeSetGrid**

In `FocusModeSetGrid`, replace the existing `CompletionCircle` in the done cell with `SetCompletionCircle`. Add `.setCompletionFlash(trigger:)` on the set row.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/FocusMode/SetCompletionEffect.swift Povver/Povver/UI/FocusMode/FocusModeComponents.swift Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift
git commit -m "feat(workout): implement set completion signature interaction

Radial emerald fill (0.15s) -> pulse to 1.15 with bouncy spring ->
light impact haptic at peak -> checkmark stroke draw (0.2s) -> row
background emerald flash (0.3s). Reduce Motion: instant fill + haptic.
Total ~0.5s choreography."
```

---

### Task 7: Auto-Advance Focus Progression

After set completion, automatically move focus to the next undone set. Between exercises, scroll to the next exercise.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift`

**Reference:** Spec Section 3.1 (Auto-advance), Section 8 (Auto-Advance)

- [ ] **Step 1: Read how selectedCell and scrolling work in FocusModeWorkoutScreen**

Read `FocusModeWorkoutScreen.swift` focusing on `selectedCell`, `ScrollViewReader`, and how the editing dock is presented. Understand the current flow when a set is completed.

- [ ] **Step 2: Add auto-advance logic after set completion**

In the `logSet` handler (or the `onLogSet` callback in `FocusModeSetGrid`), after the set is marked done:

1. Find the next undone set in the same exercise
2. If found: set `selectedCell` to that set's weight cell, scroll to it
3. If not found (all sets done in this exercise): find the first undone set in the next exercise, scroll to that exercise section

```swift
/// Find the next undone set after a completion.
/// Returns (exerciseIndex, setId) or nil if workout is complete.
private func findNextUndoneSet(afterExercise exerciseId: String, afterSet setId: String) -> (exerciseIndex: Int, setId: String)? {
    guard let workout = service.workout else { return nil }

    // Find current exercise
    guard let currentExerciseIndex = workout.exercises.firstIndex(where: { $0.id == exerciseId }) else {
        return nil
    }

    let currentExercise = workout.exercises[currentExerciseIndex]

    // Check remaining sets in current exercise
    if let currentSetIndex = currentExercise.sets.firstIndex(where: { $0.id == setId }) {
        let remaining = currentExercise.sets[(currentSetIndex + 1)...]
        if let nextUndone = remaining.first(where: { !$0.isDone }) {
            return (currentExerciseIndex, nextUndone.id)
        }
    }

    // Check subsequent exercises
    for i in (currentExerciseIndex + 1)..<workout.exercises.count {
        let exercise = workout.exercises[i]
        if let firstUndone = exercise.sets.first(where: { !$0.isDone }) {
            return (i, firstUndone.id)
        }
    }

    return nil // Workout complete
}
```

Wire this into the `logSet` completion handler. After calling `service.logSet(...)`, call `findNextUndoneSet` and update `selectedCell` and scroll position.

- [ ] **Step 3: Add scroll animation to next exercise**

Use `ScrollViewReader.scrollTo(id:anchor:)` with the exercise section ID. Apply Reflow animation for the scroll.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Manual test**

In simulator: start a workout, complete sets in sequence. Verify:
1. After completing a set, focus moves to the next set automatically
2. When last set of exercise is done, view scrolls to next exercise
3. User can still tap any cell to jump (auto-advance is not a constraint)

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift
git commit -m "feat(workout): add auto-advance focus progression after set completion

After completing a set, focus automatically moves to the next undone
set. Cross-exercise: scrolls to next exercise when current is complete.
User can always tap any cell to override."
```

---

### Task 8: Exercise Completion Choreography + Contextual Density

Add exercise completion animation (card compression + medium haptic + left-edge indicator) and contextual density (active = 60%, completed = compressed, upcoming = minimal).

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` (ExerciseCardContainer)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 2.2 (Exercise completed), Section 3.2 (Contextual Density)

- [ ] **Step 1: Read ExerciseCardContainer in FocusModeComponents.swift**

Read the `ExerciseCardContainer` struct to understand current visual hierarchy tiers.

- [ ] **Step 2: Add exercise states to ExerciseCardContainer**

Add an `ExerciseDensity` enum and modify `ExerciseCardContainer`:

```swift
enum ExerciseDensity {
    case active      // 60% of screen, full set grid, 48pt touch targets
    case completed   // Single row: name + set count + completion indicator
    case upcoming    // Name + set count only, subdued
}
```

Implement the three density modes in `ExerciseCardContainer`. The active mode shows the full set grid. Completed mode collapses to a summary row (tappable to expand). Upcoming mode shows minimal info.

- [ ] **Step 3: Add emerald left-edge indicator for completed exercises**

When all sets in an exercise are done, slide in a 3pt emerald accent bar on the left edge (Reveal intent). Add medium impact haptic on the transition.

- [ ] **Step 4: Wire density states in FocusModeWorkoutScreen**

Determine each exercise's density based on workout progress:
- The first exercise with undone sets = `.active`
- Exercises before it (all sets done) = `.completed`
- Exercises after it = `.upcoming`

Pass density to `FocusModeExerciseSectionNew`.

- [ ] **Step 5: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift Povver/Povver/UI/FocusMode/FocusModeComponents.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(workout): add contextual density and exercise completion choreography

Three density modes: active (full grid), completed (compressed summary),
upcoming (minimal). Exercise completion: card compression + emerald
left-edge slide + medium haptic. Completed exercises tappable to expand."
```

---

## Phase 3: Destructive Actions & Error Communication

### Task 9: Destructive Action Tiers in Workout

Downgrade remove-exercise from Tier 3 (dialog) to Tier 1 (immediate + undo toast). Standardize Tier 3 dialog copy for finish/discard workout. Add haptics on destructive confirms.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` (FinishWorkoutSheet)
- Modify: `Povver/Povver/UI/Components/Feedback/UndoToast.swift`
- Modify: `Povver/Povver/Services/FocusModeWorkoutService.swift`

**Reference:** Spec Section 5 (Destructive Action Tiers)

- [ ] **Step 1: Read how exercise removal currently works**

Read `FocusModeWorkoutScreen.swift` — search for `removeExercise` and `confirmationDialog` to understand the current Tier 3 removal flow.

- [ ] **Step 2: Add undo buffer to FocusModeWorkoutService**

Add an undo buffer that temporarily stores removed exercises:

```swift
/// Undo buffer for Tier 1 destructive actions
private var undoBuffer: (exercise: FocusModeExercise, index: Int, timer: Timer)?

func removeExerciseWithUndo(exerciseInstanceId: String) {
    guard let workout, let index = workout.exercises.firstIndex(where: { $0.id == exerciseInstanceId }) else { return }

    let removedExercise = workout.exercises[index]

    // Remove locally
    removeExercise(exerciseInstanceId: exerciseInstanceId)

    // Cancel any previous undo timer
    undoBuffer?.timer.invalidate()

    // Store in undo buffer with 5s timer
    let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
        Task { @MainActor in
            self?.undoBuffer = nil
        }
    }
    undoBuffer = (exercise: removedExercise, index: index, timer: timer)
}

func undoLastRemoval() {
    guard let buffer = undoBuffer else { return }
    buffer.timer.invalidate()

    // Re-insert exercise at original position
    // Use addExercise or direct insertion depending on service API
    // This needs to be adapted to the actual service method
    undoBuffer = nil
}
```

- [ ] **Step 3: Replace exercise removal dialog with immediate action + UndoToast**

In `FocusModeWorkoutScreen`, change the remove exercise flow:

```swift
// Before: confirmationDialog asking "Remove exercise?"
// After: immediate removal + UndoToast

service.removeExerciseWithUndo(exerciseInstanceId: exerciseId)
showUndoToast = true
undoToastText = "\(exerciseName) removed"
```

Add UndoToast overlay:

```swift
.overlay(alignment: .bottom) {
    if showUndoToast {
        UndoToast(undoToastText) {
            service.undoLastRemoval()
            showUndoToast = false
        }
        .padding(.bottom, 80)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation { showUndoToast = false }
            }
        }
    }
}
```

- [ ] **Step 4: Standardize Tier 3 dialog copy in FinishWorkoutSheet**

Read `FinishWorkoutSheet` in `FocusModeComponents.swift`. Update dialog copy per spec:
- "Finish Workout" → title: "Finish this workout?", message: "Your workout will be saved and you'll see a summary."
- "Discard Workout" → title: "Discard this workout?", message: "Your sets and progress from this session won't be saved.", destructive button: "Discard"
- Add `HapticManager.destructiveAction()` after user confirms discard

- [ ] **Step 5: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/UI/FocusMode/FocusModeComponents.swift Povver/Povver/UI/Components/Feedback/UndoToast.swift Povver/Povver/Services/FocusModeWorkoutService.swift
git commit -m "feat(workout): implement destructive action tiers

Tier 1: remove exercise is now immediate + 5s undo toast (was dialog).
Tier 3: finish/discard dialogs follow spec copy rules. Warning haptic
on destructive confirm."
```

---

### Task 10: Inline Error Component + Error Communication

Create reusable InlineError component with progressive copy and coach escalation. Replace error banner in workout with inline indicators.

**Files:**
- Create: `Povver/Povver/UI/Components/Feedback/InlineError.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 7 (Error Communication)

- [ ] **Step 1: Create InlineError.swift**

```swift
import SwiftUI

/// Inline error message with progressive copy and optional coach escalation.
///
/// Usage:
/// ```swift
/// InlineError(
///     failureCount: viewModel.loginFailureCount,
///     firstMessage: "That didn't work. Try again?",
///     secondMessage: "Still not working. Check your connection, or message your coach for help.",
///     onCoachTap: { /* navigate to coach */ }
/// )
/// ```
struct InlineError: View {
    let failureCount: Int
    let firstMessage: String
    let secondMessage: String
    var onCoachTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        if failureCount > 0 {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(failureCount >= 2 ? secondMessage : firstMessage)
                    .textStyle(.caption)
                    .foregroundStyle(Color.destructive)

                if failureCount >= 2, onCoachTap != nil {
                    Button("Message coach") {
                        onCoachTap?()
                    }
                    .textStyle(.caption)
                    .foregroundStyle(Color.accent)
                }
            }
            .revealEffect(isVisible: isVisible)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
        }
    }
}

/// Transient sync indicator for workout rows.
/// Shows on the affected row, resolves silently on retry success.
struct SyncIndicator: View {
    let state: SyncState

    enum SyncState {
        case synced
        case syncing
        case failed(retryCount: Int)
    }

    var body: some View {
        switch state {
        case .synced:
            EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(Color.textTertiary)
                .rotationEffect(.degrees(360))
        case .failed(let retryCount):
            if retryCount >= 3 {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }
}
```

- [ ] **Step 2: Replace error banner auto-dismiss in FocusModeWorkoutScreen**

Read the current `showError()` method and error banner overlay. Change from:
- Current: Auto-dismiss after 4 seconds banner overlay
- New: For sync errors, show `SyncIndicator` on affected exercise rows. For action errors (e.g., failed to finish), show inline error below the action button.

Keep the `Banner` overlay for truly transient status messages (non-error).

- [ ] **Step 3: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/Components/Feedback/InlineError.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(errors): add inline error component with progressive copy

InlineError shows escalating messages (1st failure -> 2nd failure with
coach link). SyncIndicator for workout row sync state. Workout error
banner replaced with inline indicators on affected rows."
```

---

## Phase 4: Completion Arc & Loading States

### Task 11: Workout Completion Arc

Add held beat before transition, align staggered reveal timing to spec, ensure haptic sequence.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 2.2 (Workout completed), Section 6 (Completion Hierarchy)

- [ ] **Step 1: Read WorkoutCompletionSummary in FocusModeWorkoutHelpers.swift**

Read `Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift` completely. Focus on the `revealPhase` staggering and haptic calls.

- [ ] **Step 2: Add held beat before completion transition**

In `FocusModeWorkoutScreen`, after `completeWorkout()` succeeds but before showing the completion summary, add a 0.5s delay:

```swift
// After completeWorkout returns the archived workout ID
HapticManager.workoutCompleted()
try? await Task.sleep(for: .milliseconds(500)) // Held beat
completedWorkout = CompletedWorkoutRef(id: archivedId)
```

- [ ] **Step 3: Align staggered reveal timing in WorkoutCompletionSummary**

Update the reveal phases to match spec timing (0.0s / 0.2s / 0.4s / 0.6s / 0.8s):

```swift
// Phase delays (seconds from data loaded):
// 0.0s - Coach presence + "Session Complete" headline
// 0.2s - Core metrics (duration, volume, sets)
// 0.4s - Exercise detail
// 0.6s - Consistency map
// 0.8s - Coach reflection
```

Adjust the `DispatchQueue.main.asyncAfter` delays in the `.task` to match these intervals. Use `revealEffect(isVisible:)` from the motion intent modifiers where possible.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(workout): implement workout completion arc

0.5s held beat after final exercise. Success notification haptic.
Staggered summary reveal at 0.0/0.2/0.4/0.6/0.8s intervals.
Uses Reveal motion intent for each phase."
```

---

### Task 12: Structural Loading States

Replace centered `ProgressView()` patterns with structural loading (navigation chrome visible, content area contextual). Add minimum 400ms display for loading indicators.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift` (workout start view)
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift` (detail views)

**Reference:** Spec Section 1.4 (App is never empty), Section 9 (Navigation & Loading)

- [ ] **Step 1: Audit centered ProgressView usage**

Search the codebase for `ProgressView()` to find all centered spinner patterns. Focus on the ones flagged in the spec audit:
- Workout start view
- Library detail views
- Coach tab loading

```bash
grep -rn "ProgressView()" Povver/Povver/Views/ Povver/Povver/UI/ --include="*.swift" | head -30
```

- [ ] **Step 2: Fix workout start view loading**

In `FocusModeWorkoutScreen`, the template picker / start flow should show `isLoading` on the "Start Session" PovverButton using the new loading state from Task 3:

```swift
PovverButton("Start Session", isLoading: $isStartingWorkout) {
    startWorkout()
}
.buttonHaptic(.medium) // Elevated for high-stakes action
```

- [ ] **Step 3: Fix Library detail view loading**

In `LibraryView` and related detail views, replace centered `ProgressView()` with the destination view showing immediately with content fading in via Reveal when data loads:

```swift
// Instead of:
if isLoading {
    ProgressView()
} else {
    DetailContent(data: data)
}

// Use:
DetailContent(data: data)
    .revealEffect(isVisible: !isLoading)
    .overlay {
        if isLoading {
            // Structural loading: section headers visible, content area shows context
            VStack {
                // Keep navigation chrome and section structure visible
            }
        }
    }
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/Views/Tabs/LibraryView.swift
git commit -m "feat(loading): replace centered spinners with structural loading states

Workout start uses PovverButton loading state. Library detail views
show destination immediately with content Reveal on data load.
No view shows centered ProgressView as its only content."
```

---

## Phase 5: Screen-by-Screen Polish

### Task 13: Auth Screens Polish

Add PovverButton loading states, progressive inline errors, and scroll-to-focus on auth screens.

**Files:**
- Modify: `Povver/Povver/Views/LoginView.swift`
- Modify: `Povver/Povver/Views/RegisterView.swift`

**Reference:** Spec Section 10 (Auth Screens audit)

- [ ] **Step 1: Read LoginView.swift and RegisterView.swift**

Read both files completely to understand current form structure, error handling, and loading state.

- [ ] **Step 2: Add PovverButton loading state to Login**

Replace the current `isLoading` flag approach with PovverButton's new `isLoading` binding:

```swift
PovverButton("Log in", isLoading: $isLoading) {
    await performLogin()
}
```

Convert `performLogin()` to async if not already.

- [ ] **Step 3: Add progressive inline error to Login**

Replace the current error text display with `InlineError`:

```swift
// Track failure count
@State private var loginFailureCount = 0

// After failed login:
loginFailureCount += 1

// In the view:
InlineError(
    failureCount: loginFailureCount,
    firstMessage: "That didn't work. Try again?",
    secondMessage: "Still not working. Check your connection, or message your coach for help.",
    onCoachTap: { /* navigate to coach tab with pre-filled message */ }
)
```

Reset `loginFailureCount` on successful login or when user edits the email/password fields.

- [ ] **Step 4: Add scroll-to-focus behavior**

Wrap the form content in a `ScrollViewReader`. When a text field gains focus, scroll to place it above the keyboard with `Space.lg` padding.

- [ ] **Step 5: Apply same changes to RegisterView**

Repeat steps 2-4 for `RegisterView.swift`.

- [ ] **Step 6: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add Povver/Povver/Views/LoginView.swift Povver/Povver/Views/RegisterView.swift
git commit -m "feat(auth): add loading states, progressive errors, scroll-to-focus

Login/Register buttons use PovverButton loading state. Errors use
InlineError with progressive copy and coach escalation on 2nd failure.
Text fields scroll into view above keyboard on focus."
```

---

### Task 14: Coach Tab + AgentPromptBar Polish

Add submit haptic to AgentPromptBar. Replace centered ProgressView with structural loading on Coach tab.

**Files:**
- Modify: `Povver/Povver/UI/Components/Inputs/AgentPromptBar.swift`
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift` (if centered ProgressView exists)

**Reference:** Spec Section 4.3 (AgentPromptBar), Section 10 (Coach Tab audit)

- [ ] **Step 1: Read AgentPromptBar.swift**

Already analyzed. Add light impact haptic on submit.

- [ ] **Step 2: Add haptic to AgentPromptBar submit**

In the submit button tap handler:

```swift
Button {
    HapticManager.primaryAction()
    onSubmit()
} label: {
    // existing arrow icon
}
```

- [ ] **Step 3: Read CoachTabView and fix loading state if needed**

Read `Povver/Povver/Views/Tabs/CoachTabView.swift`. If it has a centered `ProgressView()`, replace with structural loading (show quick actions and section headers while content loads).

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/Components/Inputs/AgentPromptBar.swift Povver/Povver/Views/Tabs/CoachTabView.swift
git commit -m "feat(coach): add submit haptic and structural loading

AgentPromptBar fires light impact on message submit. Coach tab shows
structural context during loading instead of centered spinner."
```

---

### Task 15: Remaining Screen Polish (Library, History, Settings, Banner)

Batch of small fixes across Library, History, Settings, and the floating workout banner.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift`
- Modify: `Povver/Povver/Views/MainTabsView.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift` (migrate raw UIImpactFeedbackGenerator calls)

**Reference:** Spec Section 10 (History, Settings, Floating Banner audit)

- [ ] **Step 1: Read HistoryView.swift**

Read `Povver/Povver/Views/Tabs/HistoryView.swift` to check for "Load More" button and empty state.

- [ ] **Step 2: Add loading state to History "Load More" button**

If there's a "Load More" button using PovverButton, add `isLoading` binding.

- [ ] **Step 3: Add haptic to floating workout banner**

In `MainTabsView.swift`, add light impact haptic when the floating banner is tapped:

```swift
FloatingWorkoutBanner(
    // existing params
    onTap: {
        HapticManager.primaryAction()
        selectedTabRaw = MainTab.train.rawValue
    }
)
```

- [ ] **Step 4: Migrate raw UIImpactFeedbackGenerator calls in FocusModeWorkoutScreen**

Replace the 4 raw `UIImpactFeedbackGenerator` calls with `HapticManager` methods:
- `toggleReorderMode()`: `UIImpactFeedbackGenerator(style: .medium)` → `HapticManager.modeToggle()`
- `reorderExercisesNew()`: `UIImpactFeedbackGenerator(style: .medium)` → `HapticManager.modeToggle()`
- `addSet()`: `UIImpactFeedbackGenerator(style: .light)` → `HapticManager.selectionTick()`
- `autofillExercise()`: `UIImpactFeedbackGenerator(style: .medium)` → `HapticManager.modeToggle()`

Also migrate the one in `FocusModeWorkoutService.swift`:
- `addExercise()`: `UIImpactFeedbackGenerator(style: .medium)` → `HapticManager.modeToggle()`

- [ ] **Step 5: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/Views/Tabs/HistoryView.swift Povver/Povver/Views/MainTabsView.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/Services/FocusModeWorkoutService.swift
git commit -m "feat(polish): history loading, banner haptic, haptic standardization

History 'Load More' uses PovverButton loading state. Floating workout
banner fires light impact on tap. All raw UIImpactFeedbackGenerator
calls migrated to HapticManager methods."
```

---

### Task 16: Documentation Update

Update architecture docs to reflect the new interaction system.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/ARCHITECTURE.md`
- Modify: `docs/IOS_ARCHITECTURE.md`

**Reference:** CLAUDE.md documentation tier guidance

- [ ] **Step 1: Read existing FocusMode ARCHITECTURE.md**

Read `Povver/Povver/UI/FocusMode/ARCHITECTURE.md` to understand current structure.

- [ ] **Step 2: Update FocusMode ARCHITECTURE.md**

Add sections covering:
- Ghost value resolution flow
- Auto-advance focus progression
- Set completion signature interaction
- Contextual density states
- Destructive action tiers (Tier 1 undo, Tier 3 dialogs)

- [ ] **Step 3: Update IOS_ARCHITECTURE.md Design System section**

Add to the Design System section:
- Motion intents (Respond, Reveal, Transform, Exit, Reflow)
- Haptic policy (ButtonHapticStyle, rapid succession guard, .buttonHaptic() modifier)
- InteractionToken (press scale, disabled opacity, loading thresholds)
- PovverButton states (idle, pressed, loading, loaded, disabled)
- InlineError component
- Structural loading pattern

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/FocusMode/ARCHITECTURE.md docs/IOS_ARCHITECTURE.md
git commit -m "docs: update architecture docs for input interaction system

FocusMode: ghost values, auto-advance, signature interaction, contextual
density, destructive tiers. Design System: motion intents, haptic policy,
interaction tokens, PovverButton states, error components."
```

---

## Summary

| Phase | Tasks | Focus |
|-------|-------|-------|
| 1: Foundation | 1-3 | Motion intents, haptic policy, PovverButton |
| 2: Workout Core | 4-8 | Ghost values, auto-advance, signature interaction, contextual density |
| 3: Destructive & Errors | 9-10 | Undo toast, dialog standardization, inline errors |
| 4: Completion & Loading | 11-12 | Workout completion arc, structural loading |
| 5: Screen Polish | 13-16 | Auth, Coach, Library, History, Settings, docs |

**Total: 16 tasks.** Each produces a buildable, committable increment. Tasks within each phase build on each other; phases 2+ depend on Phase 1 foundation.
