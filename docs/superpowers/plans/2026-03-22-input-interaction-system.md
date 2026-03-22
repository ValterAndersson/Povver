# Input Interaction System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a unified interaction system across the Povver iOS app — motion intents, haptic policy, button states, text field states, ghost values, auto-advance, set completion signature, destructive action tiers, error communication, structural loading states, pre-filled contexts, and accessibility compliance.

**Architecture:** Bottom-up — build design system foundation (motion intents, haptic policy, component interaction states) first, then workout-specific interactions (ghost values, auto-advance, signature interaction), then app-wide polish (error communication, loading states, screen-by-screen fixes, accessibility). Each task produces a buildable, committable unit.

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
| `UI/Components/Inputs/PovverTextField.swift` | Styled text field with 5 interaction states (idle, focused, error, success, disabled) |
| `UI/FocusMode/GhostValueResolver.swift` | Pure logic: resolve ghost values from last session / template / blank |
| `UI/FocusMode/SetCompletionEffect.swift` | Radial fill + pulse + stroke draw signature animation with additive intensity layers |
| `UI/Components/Feedback/InlineError.swift` | Reusable inline error with progressive copy and coach escalation |
| `UI/Components/Feedback/DataLoadingErrorView.swift` | Content-area error state with retry button and coach escalation |

### Test Files

| File | Responsibility |
|------|----------------|
| `PovverTests/GhostValueResolverTests.swift` | Unit tests for ghost value resolution priority (last session > template > blank) |
| `PovverTests/AutoAdvanceTests.swift` | Unit tests for auto-advance set/exercise ordering logic |

### Modified Files

| File | Changes |
|------|---------|
| `UI/DesignSystem/Tokens.swift` | Add `InteractionToken` (disabled opacity, press scale, loading thresholds) |
| `UI/Components/PovverButton.swift` | Add `isLoading` binding, press state (scale 0.97 + brightness), haptic, loaded state (emerald flash + success tick), disabled = 40% opacity |
| `Services/HapticManager.swift` | Add `buttonTap(style:)`, rapid succession guard, scroll suppression tracker |
| `UI/FocusMode/FocusModeSetGrid.swift` | Ghost value display (40% opacity), set completion signature trigger, row flash, forgiveness (tap to undo) |
| `UI/FocusMode/FocusModeComponents.swift` | `CompletionCircle` → `SetCompletionCircle`, `ExerciseCardContainer` contextual density, `FinishWorkoutSheet` Tier 3 copy |
| `UI/FocusMode/FocusModeExerciseSection.swift` | Contextual density (active/completed/upcoming), exercise completion choreography |
| `UI/FocusMode/FocusModeWorkoutScreen.swift` | Tier 1 undo for remove-exercise and remove-set, auto-advance scroll, error → inline, finish/discard haptics, pre-filled contexts |
| `Services/FocusModeWorkoutService.swift` | Fetch last session data for ghost values, undo buffer for Tier 1 actions |
| `UI/FocusMode/FocusModeWorkoutHelpers.swift` | `WorkoutCompletionSummary` held beat + staggered timing alignment |
| `UI/Components/Inputs/AgentPromptBar.swift` | Light impact haptic on submit, send arrow Reveal/Exit animation |
| `UI/Components/Feedback/UndoToast.swift` | Add auto-dismiss timer (5s), light impact on undo tap |
| `UI/Components/PovverToggle.swift` (or wherever toggle is defined) | Add selection haptic |
| `UI/Components/Chip.swift` (or wherever chips are defined) | Add selection haptic with rapid succession exception |
| `Views/LoginView.swift` | PovverTextField migration, `isLoading` on PovverButton + SSO buttons, progressive inline error, scroll-to-focus |
| `Views/RegisterView.swift` | Same as LoginView |
| `Views/Tabs/LibraryView.swift` | Search field focus behavior, detail view loading |
| `Views/Tabs/HistoryView.swift` | Load more button loading state |
| `Views/Tabs/CoachTabView.swift` | Structural loading |
| `Views/MainTabsView.swift` | Floating banner tap haptic |
| `UI/Routines/RoutineDetailView.swift` | Tier 3 delete dialog standardization |
| `UI/Templates/TemplateDetailView.swift` | Tier 3 delete dialog standardization |
| `Views/Settings/SecurityView.swift` or `Views/Tabs/MoreView.swift` | Tier 3 sign out dialog standardization |

---

## Phase 1: Design System Foundation

### Task 1: Motion Intent View Modifiers

Build the 5 motion intents as reusable SwiftUI view modifiers with automatic Reduce Motion fallbacks.

**Files:**
- Create: `Povver/Povver/UI/DesignSystem/MotionIntent.swift`
- Modify: `Povver/Povver/UI/DesignSystem/Tokens.swift`

**Reference:** Spec Section 2.1 (Five Motion Intents), Section 1.5 (Reduce Motion fallback)

- [ ] **Step 1: Add InteractionToken to Tokens.swift**

Read `Povver/Povver/UI/DesignSystem/Tokens.swift`. Add after the `MotionToken` enum:

```swift
public enum InteractionToken {
    /// Universal disabled opacity (spec: 40%)
    public static let disabledOpacity: Double = 0.4
    /// Press scale factor
    public static let pressScale: CGFloat = 0.97
    /// Press brightness factor (~90%)
    public static let pressBrightness: Double = -0.08
    /// Loading indicator delay before showing
    public static let loadingDelay: Duration = .milliseconds(300)
    /// Minimum loading indicator display time
    public static let loadingMinDisplay: Duration = .milliseconds(600)
    /// Minimum display for any loading indicator (prevents flash-of-spinner)
    public static let minimumLoadingDisplay: Duration = .milliseconds(400)
}
```

- [ ] **Step 2: Create MotionIntent.swift with all five intents**

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
            .brightness(isPressed ? InteractionToken.pressBrightness : 0)
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
            .offset(
                x: reduceMotion ? 0 : exitOffsetX,
                y: reduceMotion ? 0 : exitOffsetY
            )
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.2)
                    : .easeOut(duration: MotionToken.fast),
                value: isExiting
            )
    }

    /// Vertical offset — slides toward the edge the element exits toward
    private var exitOffsetY: CGFloat {
        guard isExiting else { return 0 }
        switch edge {
        case .top: return -8
        case .bottom: return 8
        case .leading, .trailing: return 0
        }
    }

    /// Horizontal offset — slides toward origin (leading/trailing)
    private var exitOffsetX: CGFloat {
        guard isExiting else { return 0 }
        switch edge {
        case .leading: return -8
        case .trailing: return 8
        case .top, .bottom: return 0
        }
    }
}

// MARK: - Reflow Intent
// Position-only ease-in-out. Never bouncy. Reduce Motion: gentle 0.2s to avoid jarring layout shifts.

struct ReflowEffect: ViewModifier {
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.2) // Gentle position shift, not jarring instant
                    : .easeInOut(duration: MotionToken.medium),
                value: trigger
            )
    }
}

// MARK: - View Extensions

public extension View {
    /// Respond intent: scale + brightness feedback on press
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
brightness, disabled opacity, loading thresholds."
```

---

### Task 2: Haptic Policy System

Enhance HapticManager with rapid succession guard, scroll suppression, and a `.buttonHaptic()` view modifier for declarative haptic assignment.

**Files:**
- Modify: `Povver/Povver/Services/HapticManager.swift`
- Create: `Povver/Povver/UI/DesignSystem/HapticPolicy.swift`

**Reference:** Spec Section 2.3 (Override Rules), Section 4.1 (PovverButton haptic defaults)

- [ ] **Step 1: Read HapticManager.swift**

Read `Povver/Povver/Services/HapticManager.swift` to understand current implementation.

- [ ] **Step 2: Add rapid succession guard, scroll suppression, and buttonTap to HapticManager**

Add to `HapticManager`:

```swift
// MARK: - Rapid Succession Guard

/// Tracks last fire time per category to suppress rapid identical haptics.
/// Spec: "fire haptic on first event only within rapid succession window"
/// @MainActor ensures thread safety — all haptic calls originate from main thread.
@MainActor private static var lastFireTime: [String: Date] = [:]
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

// MARK: - Scroll Suppression

/// Set to true while user is actively scrolling at high velocity.
/// Components check this before firing haptics.
/// Set by scroll views via .onScrollPhaseChange or gesture velocity tracking.
@MainActor static var isScrollingSuppressed = false

/// Check if haptics should be suppressed due to active scrolling.
/// Components call this before firing haptics inside scroll views.
static var shouldSuppressForScroll: Bool { isScrollingSuppressed }

// MARK: - Button Haptics

/// Haptic for button taps. Uses guarded fire to prevent rapid succession.
static func buttonTap(style: ButtonHapticStyle) {
    guard !shouldSuppressForScroll else { return }
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

/// Selection haptic for toggles, segments, chips. Uses guarded fire.
static func selectionChanged() {
    guard !shouldSuppressForScroll else { return }
    guardedFire(category: "selection") {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
```

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

// MARK: - Button Haptic Environment Key

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

// MARK: - Scroll Suppression Modifier

/// Attach to ScrollViews to suppress haptics during fast scrolling.
/// Uses iOS 17+ .onScrollPhaseChange if available, otherwise velocity tracking.
struct ScrollHapticSuppression: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                HapticManager.isScrollingSuppressed = (newPhase == .interacting || newPhase == .decelerating)
            }
        } else {
            // Fallback: suppress during any active scroll gesture
            content
        }
    }
}

public extension View {
    /// Suppress haptics for descendant components while this scroll view is flicking.
    func suppressHapticsWhileScrolling() -> some View {
        modifier(ScrollHapticSuppression())
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/Services/HapticManager.swift Povver/Povver/UI/DesignSystem/HapticPolicy.swift
git commit -m "feat(design): add haptic policy with rapid succession guard and scroll suppression

ButtonHapticStyle enum, .buttonHaptic() environment modifier,
HapticManager.guardedFire() for 200ms rapid succession suppression,
HapticManager.shouldSuppressForScroll for scroll-based suppression,
.suppressHapticsWhileScrolling() modifier for ScrollViews."
```

---

### Task 3: PovverButton Enhancement

Add press state (scale 0.97 + brightness reduction), loading state (300ms delay, pulsing dot, 600ms min display), loaded state (emerald flash + success tick), haptic integration, and 40% disabled opacity.

**Files:**
- Modify: `Povver/Povver/UI/Components/PovverButton.swift`

**Reference:** Spec Section 4.1 (PovverButton — all 5 states)

- [ ] **Step 1: Read PovverButton.swift**

Read `Povver/Povver/UI/Components/PovverButton.swift` completely. Understand current `ButtonStyle` implementation, color logic, and disabled state handling.

- [ ] **Step 2: Search for all PovverButton call sites and theme definitions**

Search the codebase for `PovverButton(` to verify all existing calls remain compatible. Also search for `PovverThemeKey` and `PovverThemeValues` to avoid duplication.

- [ ] **Step 3: Rewrite PovverButton with all 5 interaction states**

The current button takes `action: @escaping () -> Void`. We need:

- Add optional `isLoading: Binding<Bool>?` parameter (for external control)
- Add `asyncAction: (() async -> Void)?` parameter (for automatic loading management)
- Keep existing `action: (() -> Void)?` for backward compat
- Add press state via `ButtonStyle` (scale 0.97 + ~90% brightness via `InteractionToken.pressBrightness`)
- Add haptic via `ButtonHapticStyle` environment value
- Add loaded state: when `isLoading` transitions from true to false AND indicator was shown, brief emerald flash on significant actions + success tick haptic
- Change disabled to 40% opacity

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
    @State private var showLoadedFlash = false
    @State private var loadingShowTime: Date?

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
            .background(backgroundView)
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
                guard isLoading else { return }
                loadingShowTime = Date()
                withAnimation { showIndicator = true }
            }
        } else {
            if showIndicator {
                // Enforce 600ms minimum display
                let elapsed = loadingShowTime.map { Date().timeIntervalSince($0) } ?? 1.0
                let remaining = 0.6 - elapsed

                Task {
                    if remaining > 0 {
                        try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
                    }
                    withAnimation { showIndicator = false }

                    // Loaded state: brief emerald flash for primary/destructive
                    if style == .primary || style == .destructive {
                        HapticManager.confirmAction()
                        withAnimation(.easeOut(duration: 0.15)) { showLoadedFlash = true }
                        try? await Task.sleep(for: .milliseconds(300))
                        withAnimation(.easeOut(duration: 0.2)) { showLoadedFlash = false }
                    }

                    loadingShowTime = nil
                }
            }
        }
    }

    // MARK: - Colors

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
    private var backgroundView: some View {
        ZStack {
            backgroundColor
            // Emerald flash overlay on loaded state
            if showLoadedFlash {
                Color.accent.opacity(0.3)
            }
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

// MARK: - Press Style (Respond intent — scale + brightness)

private struct PovverPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? InteractionToken.pressScale : 1.0)
            .brightness(configuration.isPressed ? InteractionToken.pressBrightness : 0)
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
```

**Important:** Before writing, read the existing file to check if `PovverThemeKey` / `PovverThemeValues` are defined elsewhere (e.g., `Theme.swift`). If so, don't duplicate — import from existing location.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/Components/PovverButton.swift
git commit -m "feat(button): add all 5 interaction states per spec

Idle: full color. Pressed: scale 0.97 + brightness reduction.
Loading: 300ms delay, pulsing dot, 600ms min display.
Loaded: emerald flash + success tick for significant actions.
Disabled: 40% opacity, fully inert. Haptic: light/medium/none
per style, overridable via .buttonHaptic()."
```

---

### Task 4: PovverTextField Component

Create a styled text field with all 5 interaction states: idle, focused, error, success, disabled.

**Files:**
- Create: `Povver/Povver/UI/Components/Inputs/PovverTextField.swift`

**Reference:** Spec Section 4.2 (PovverTextField states)

- [ ] **Step 1: Read existing text field usage patterns**

Search for `TextField` usage in `LoginView.swift`, `RegisterView.swift`, and other forms to understand current patterns. Look for `authTextField` helper in `LoginView.swift`.

- [ ] **Step 2: Create PovverTextField.swift**

```swift
import SwiftUI

/// Text field validation state
public enum TextFieldValidation: Equatable {
    case idle
    case error(String)    // Error message to display below field
    case success          // Brief green border, fades to idle after 1s
}

/// Styled text field with 5 interaction states per spec Section 4.2.
///
/// States:
/// - Idle: hairline border, Color.separatorLine
/// - Focused: accent border, scrolls to field, multi-field forms elevate background
/// - Validation error: destructive border, error message below with Reveal
/// - Validation success: success border, fades to idle after 1s
/// - Disabled: 40% opacity, not focusable
public struct PovverTextField: View {
    let placeholder: String
    @Binding var text: String
    var validation: TextFieldValidation = .idle
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false
    var textContentType: UITextContentType? = nil

    @FocusState private var isFocused: Bool
    @State private var showSuccess = false
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ placeholder: String,
        text: Binding<String>,
        validation: TextFieldValidation = .idle,
        keyboardType: UIKeyboardType = .default,
        isSecure: Bool = false,
        textContentType: UITextContentType? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.validation = validation
        self.keyboardType = keyboardType
        self.isSecure = isSecure
        self.textContentType = textContentType
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textContentType(textContentType)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .textContentType(textContentType)
                }
            }
            .textStyle(.body)
            .focused($isFocused)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .opacity(isEnabled ? 1 : InteractionToken.disabledOpacity)
            .disabled(!isEnabled)

            // Validation error message with Reveal animation
            if case .error(let message) = validation {
                Text(message)
                    .textStyle(.caption)
                    .foregroundStyle(Color.destructive)
                    .revealEffect(isVisible: true)
            }
        }
        .onChange(of: validation) { _, newVal in
            if case .success = newVal {
                showSuccess = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSuccess = false
                    }
                }
            }
        }
        .accessibilityLabel(placeholder)
    }

    private var fieldBackground: Color {
        if isFocused {
            return Color.surfaceElevated
        }
        return Color.surface
    }

    private var borderColor: Color {
        if case .error = validation { return .destructive }
        if showSuccess || (validation == .success) { return .success }
        if isFocused { return .accent }
        return .separatorLine
    }

    private var borderWidth: CGFloat {
        if isFocused || validation != .idle { return StrokeWidthToken.thin }
        return StrokeWidthToken.hairline
    }
}
```

**Scroll-to-focus note:** Forms containing `PovverTextField` should use `ScrollViewReader` to scroll the focused field above the keyboard with `Space.lg` padding. This is the caller's responsibility (not built into PovverTextField). Apply in `LoginView`, `RegisterView`, and any future forms:

```swift
ScrollViewReader { proxy in
    ScrollView {
        VStack {
            PovverTextField("Email", text: $email, validation: emailValidation)
                .id("email")
            // ...
        }
    }
    .onChange(of: focusedField) { _, field in
        if let field {
            withAnimation {
                proxy.scrollTo(field, anchor: .bottom) // Places field above keyboard
            }
        }
    }
    .scrollDismissesKeyboard(.interactively)
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/Components/Inputs/PovverTextField.swift
git commit -m "feat(design): add PovverTextField with 5 interaction states

Idle (hairline border), focused (accent border + elevated bg),
validation error (destructive border + error text with Reveal),
validation success (success border, fades after 1s),
disabled (40% opacity, not focusable). Scroll-to-focus pattern
documented for callers."
```

---

### Task 5: Component Haptics (Toggle, Segmented, Chip, Stepper)

Add selection haptics to all interactive components per spec Section 4.3.

**Files:**
- Modify: Multiple component files (find exact locations by searching)

**Reference:** Spec Section 4.3 (Other Components haptic table)

- [ ] **Step 1: Find all component files**

Search for `PovverToggle`, `Toggle`, `Picker(.segmented)`, `Chip`, `ChipGroup`, `Stepper` across the codebase:

```bash
grep -rn "struct.*Toggle\|struct.*Chip\|struct.*Stepper\|pickerStyle(.segmented)" Povver/Povver/UI/ --include="*.swift" | head -20
```

Also check `FocusModeSetGrid.swift` for the stepper +/- buttons and `FocusModeComponents.swift` for the `ScopeSegmentedControl`.

- [ ] **Step 2: Add selection haptic to toggles**

Wherever a toggle state change is handled, add `HapticManager.selectionChanged()`. If using system `Toggle`, wrap it in an `.onChange` handler:

```swift
Toggle("Label", isOn: $value)
    .onChange(of: value) { _, _ in
        HapticManager.selectionChanged()
    }
```

- [ ] **Step 3: Add selection haptic to segmented controls**

In `ScopeSegmentedControl` and any `Picker(.segmented)`, add `HapticManager.selectionChanged()` on segment change. Replace any existing raw `UISelectionFeedbackGenerator().selectionChanged()` calls.

- [ ] **Step 4: Add selection haptic to Chip/ChipGroup with rapid succession exception**

In the Chip component's tap handler, use `HapticManager.guardedFire`:

```swift
Button {
    HapticManager.guardedFire(category: "chip") {
        HapticManager.selectionChanged()
    }
    // toggle chip state
}
```

The 200ms rapid succession window in `guardedFire` handles the "first tap only within 200ms" spec requirement.

- [ ] **Step 5: Add stepper haptics in FocusModeSetGrid (if not present)**

Read the stepper +/- buttons in `FocusModeSetGrid.swift`. Add `HapticManager.selectionTick()` on each tap if not already present. If they support hold-to-repeat, add logic for "haptic on first tick and every 5th":

**Note:** Navigation list rows must remain silent — do NOT add haptics to list rows.

```swift
// In hold-to-repeat handler:
stepCount += 1
if stepCount == 1 || stepCount % 5 == 0 {
    HapticManager.selectionTick()
}
```

If hold-to-repeat is not currently implemented, skip the "every 5th" part (it's spec guidance for a future feature).

- [ ] **Step 6: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add -A Povver/Povver/UI/
git commit -m "feat(haptics): add selection haptics to toggles, segments, chips, steppers

Toggles: selection feedback on state change.
Segmented controls: selection feedback, replaces raw UIKit calls.
Chips: selection with rapid succession guard (200ms window).
Steppers: already using HapticManager.selectionTick()."
```

---

## Phase 2: Workout Core Interactions

### Task 6: Ghost Value Resolver

Pure logic for resolving what values to show in undone sets: last session > template prescription > blank.

**Files:**
- Create: `Povver/Povver/UI/FocusMode/GhostValueResolver.swift`
- Modify: `Povver/Povver/Services/FocusModeWorkoutService.swift`

**Reference:** Spec Section 3.1 (Ghost values), Section 8 (Ghost Values)

- [ ] **Step 1: Read FocusModeModels.swift to understand set/exercise models**

Read `Povver/Povver/Models/FocusModeModels.swift` to understand `FocusModeExercise`, `FocusModeSet`, and their fields. Note exact field names for weight, reps, rir, isDone, and any prescription fields.

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

    var hasValues: Bool { weight != nil || reps != nil || rir != nil }
    static let empty = GhostValues(weight: nil, reps: nil, rir: nil)
}

struct LastSessionExerciseData {
    let sets: [LastSessionSetData]
}

struct LastSessionSetData {
    let weight: Double?
    let reps: Int
    let rir: Int?
}

/// Resolves ghost values for undone sets.
/// Priority: last session for this exercise > template prescription > blank
enum GhostValueResolver {
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
                result[set.id] = GhostValues(weight: lastSet.weight, reps: lastSet.reps, rir: lastSet.rir)
                continue
            }

            // Priority 2: Template prescription fields on the set
            result[set.id] = GhostValues(weight: set.prescribedWeight, reps: set.prescribedReps, rir: set.prescribedRir)
        }
        return result
    }
}
```

**Note:** Exact field names (`prescribedWeight`, `isDone`, etc.) must match the actual `FocusModeSet` model. Read models first and adjust.

- [ ] **Step 3: Create GhostValueResolver unit tests**

Create `Povver/PovverTests/GhostValueResolverTests.swift`:

```swift
import XCTest
@testable import Povver

final class GhostValueResolverTests: XCTestCase {

    // MARK: - Helpers

    private func makeExercise(sets: [FocusModeSet], exerciseId: String = "ex1") -> FocusModeExercise {
        // Construct a FocusModeExercise with the given sets.
        // Adjust initializer to match actual model.
        FocusModeExercise(id: "section1", exerciseId: exerciseId, name: "Bench Press", sets: sets)
    }

    private func makeUndoneSet(id: String, weight: Double? = nil, reps: Int = 0, prescribedWeight: Double? = nil, prescribedReps: Int? = nil, prescribedRir: Int? = nil) -> FocusModeSet {
        // Adjust fields to match actual FocusModeSet model
        FocusModeSet(id: id, isDone: false, weight: weight, reps: reps, prescribedWeight: prescribedWeight, prescribedReps: prescribedReps, prescribedRir: prescribedRir)
    }

    private func makeDoneSet(id: String) -> FocusModeSet {
        FocusModeSet(id: id, isDone: true, weight: 80, reps: 8)
    }

    // MARK: - Tests

    func testLastSessionTakesPriority() {
        let exercise = makeExercise(sets: [makeUndoneSet(id: "s1"), makeUndoneSet(id: "s2")])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(weight: 80, reps: 8, rir: 2),
            LastSessionSetData(weight: 82.5, reps: 7, rir: 1),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertEqual(result["s1"]?.weight, 80)
        XCTAssertEqual(result["s1"]?.reps, 8)
        XCTAssertEqual(result["s2"]?.weight, 82.5)
    }

    func testTemplatePrescriptionFallback() {
        let exercise = makeExercise(sets: [
            makeUndoneSet(id: "s1", prescribedWeight: 60, prescribedReps: 10, prescribedRir: 3)
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: nil)
        XCTAssertEqual(result["s1"]?.weight, 60)
        XCTAssertEqual(result["s1"]?.reps, 10)
        XCTAssertEqual(result["s1"]?.rir, 3)
    }

    func testBlankFallbackWhenNoPrescription() {
        let exercise = makeExercise(sets: [makeUndoneSet(id: "s1")])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: nil)
        XCTAssertEqual(result["s1"], .empty)
    }

    func testSetsWithUserValuesAreSkipped() {
        let exercise = makeExercise(sets: [makeUndoneSet(id: "s1", weight: 70, reps: 5)])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(weight: 80, reps: 8, rir: 2),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertEqual(result["s1"], .empty)
    }

    func testIndexMismatchFallsToTemplate() {
        // 3 sets in current workout but only 2 in last session
        let exercise = makeExercise(sets: [
            makeUndoneSet(id: "s1"),
            makeUndoneSet(id: "s2"),
            makeUndoneSet(id: "s3", prescribedWeight: 65, prescribedReps: 12),
        ])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(weight: 80, reps: 8, rir: 2),
            LastSessionSetData(weight: 82.5, reps: 7, rir: 1),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        // First two use last session
        XCTAssertEqual(result["s1"]?.weight, 80)
        XCTAssertEqual(result["s2"]?.weight, 82.5)
        // Third falls to template prescription
        XCTAssertEqual(result["s3"]?.weight, 65)
        XCTAssertEqual(result["s3"]?.reps, 12)
    }

    func testDoneSetsAreIgnored() {
        let exercise = makeExercise(sets: [makeDoneSet(id: "s1"), makeUndoneSet(id: "s2")])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(weight: 80, reps: 8, rir: 2),
            LastSessionSetData(weight: 82.5, reps: 7, rir: 1),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertNil(result["s1"]) // Done set not in results
        XCTAssertEqual(result["s2"]?.weight, 82.5) // Index 1 from last session
    }
}
```

**Note:** Adjust `FocusModeExercise` and `FocusModeSet` constructors to match actual model initializers. The test structure is correct — the field names may need adaptation.

- [ ] **Step 4: Run tests to verify they fail (TDD red phase)**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild test -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PovverTests/GhostValueResolverTests 2>&1 | tail -10`
Expected: FAIL (GhostValueResolver not yet importable or tests fail against stub)

- [ ] **Step 5: Read FocusModeWorkoutService.swift and WorkoutRepository.swift**

Read `Povver/Povver/Services/FocusModeWorkoutService.swift` (focus on `startWorkout`, `logSet`) and `Povver/Povver/Repositories/WorkoutRepository.swift` to understand workout data flow and available query methods.

- [ ] **Step 6: Add last session fetch to FocusModeWorkoutService**

Add a `@Published` property and fetch method. If `WorkoutRepository` doesn't have `getLastWorkoutWithExercise`, add it:

```swift
/// In WorkoutRepository:
func getLastWorkoutWithExercise(userId: String, exerciseId: String) async throws -> Workout? {
    // Query workouts ordered by completedAt desc, limit 10 (then filter client-side for exercise)
    // Firestore can't filter on nested array fields, so we fetch recent workouts and check
}
```

```swift
/// In FocusModeWorkoutService:
@Published private(set) var lastSessionData: [String: LastSessionExerciseData] = [:]

func fetchLastSessionData() async {
    guard let workout, let userId = AuthService.shared.currentUser?.uid else { return }
    let exerciseIds = Set(workout.exercises.map { $0.exerciseId })
    var result: [String: LastSessionExerciseData] = [:]

    for exerciseId in exerciseIds {
        if let lastWorkout = try? await WorkoutRepository.shared.getLastWorkoutWithExercise(
            userId: userId, exerciseId: exerciseId
        ),
        let exerciseData = lastWorkout.exercises.first(where: { $0.exerciseId == exerciseId }) {
            result[exerciseId] = LastSessionExerciseData(
                sets: exerciseData.sets.map { LastSessionSetData(weight: $0.weightKg, reps: $0.reps, rir: $0.rir) }
            )
        }
    }
    await MainActor.run { self.lastSessionData = result }
}
```

- [ ] **Step 7: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Run GhostValueResolver tests (TDD green phase)**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild test -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PovverTests/GhostValueResolverTests 2>&1 | tail -10`
Expected: All 6 tests PASS

- [ ] **Step 9: Commit**

```bash
git add Povver/Povver/UI/FocusMode/GhostValueResolver.swift Povver/Povver/Services/FocusModeWorkoutService.swift Povver/Povver/Repositories/WorkoutRepository.swift Povver/PovverTests/GhostValueResolverTests.swift
git commit -m "feat(workout): add ghost value resolver and last session fetch

GhostValueResolver resolves undone set values from last session >
template prescription > blank. FocusModeWorkoutService fetches last
session data for all exercises on workout start.
Includes unit tests for all resolution paths."
```

---

### Task 7: Ghost Value Display in Set Grid

Wire ghost values into FocusModeSetGrid — show at 40% opacity, accept on done tap, replace on field tap. Add forgiveness (tap completed checkmark to undo).

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 3.1 (Ghost values + Forgiveness), Section 8

- [ ] **Step 1: Read FocusModeSetGrid.swift**

Read `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift` completely. Focus on: cell rendering for weight/reps/rir, done cell interaction, and how `onLogSet` is called.

- [ ] **Step 2: Add ghost values parameter to FocusModeSetGrid**

Add `ghostValues: [String: GhostValues]` parameter to `FocusModeSetGrid` init.

In cell rendering for weight/reps/rir:
- If set is undone AND field is empty AND ghost value exists: show the ghost value text at 40% opacity
- If user taps a ghost-value cell: clear the ghost for that field and enter editing mode with empty value
- In `doneCell` tap handler: if set has ghost values and user hasn't manually entered values, call `onLogSet` with the ghost values

- [ ] **Step 3: Add forgiveness — tap completed checkmark to undo**

In the done cell tap handler, add toggle behavior:
- If set is NOT done: mark done (existing behavior + accept ghost values if present)
- If set IS done: mark undone — call a new `onUndoSet` callback that reverts the set status

```swift
// Add to FocusModeSetGrid init:
let onUndoSet: ((String, String) -> Void)? // exerciseId, setId

// In done cell:
if set.isDone {
    // Forgiveness: tap to undo, no confirmation
    onUndoSet?(exercise.id, set.id)
} else {
    // Accept ghost values if present, mark done
    let ghost = ghostValues[set.id]
    onLogSet(exercise.id, set.id, ghost?.weight ?? set.weight, ghost?.reps ?? set.reps ?? 0, ghost?.rir ?? set.rir)
}
```

- [ ] **Step 4: Add onUndoSet to FocusModeWorkoutService**

Add a method to revert a set from done to undone:

```swift
func undoSet(exerciseInstanceId: String, setId: String) {
    // Revert local state: set.isDone = false, clear logged values
    // Sync to backend via patchField
}
```

- [ ] **Step 5: Pass ghost values from FocusModeWorkoutScreen**

Compute and pass ghost values for each exercise section. Call `service.fetchLastSessionData()` after workout starts.

- [ ] **Step 6: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Manual test**

In simulator: start a workout from a template. Verify:
1. Undone sets show ghost values at 40% opacity
2. Tapping done accepts ghost values
3. Tapping a ghost-value cell enters editing with ghost cleared
4. Tapping a completed checkmark unchecks it (forgiveness)

- [ ] **Step 8: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/Services/FocusModeWorkoutService.swift
git commit -m "feat(workout): ghost values at 40% opacity + set completion forgiveness

Undone sets show last-session values as ghost text. Tap done to accept.
Tap field to clear ghost and edit manually. Tap completed checkmark to
undo — no confirmation, instant reversal."
```

---

### Task 8: Set Completion Signature Interaction with Progressive Intensity

Replace the simple checkmark toggle with the full sensory signature: radial fill, pulse, stroke draw, row flash, haptic at peak. Add progressive intensity — the signature escalates for final set of exercise and final set of workout.

**Files:**
- Create: `Povver/Povver/UI/FocusMode/SetCompletionEffect.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` (CompletionCircle)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift` (row flash)

**Reference:** Spec Section 3.3 (Signature Interaction + Progressive Intensity), Section 2.2 (Set/Exercise/Workout completed), Section 6 (Completion Hierarchy)

- [ ] **Step 1: Read CompletionCircle in FocusModeComponents.swift**

Read the `CompletionCircle` struct. Understand current animation.

- [ ] **Step 2: Create SetCompletionEffect.swift**

Create `SetCompletionCircle` with the full choreography AND a `completionLevel` parameter for progressive intensity:

```swift
import SwiftUI

/// Completion significance level — each higher level is additive.
enum CompletionLevel {
    case standard       // Base signature
    case exerciseFinal  // + medium haptic (exercise complete)
    case workoutFinal   // + success notification haptic (workout complete)
}

struct SetCompletionCircle: View {
    let isComplete: Bool
    let completionLevel: CompletionLevel
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
                Circle()
                    .strokeBorder(
                        isComplete || isAnimating ? Color.accent : Color.separatorLine,
                        lineWidth: 2
                    )
                    .frame(width: circleSize, height: circleSize)

                Circle()
                    .fill(Color.accent)
                    .frame(width: circleSize * fillProgress, height: circleSize * fillProgress)
                    .clipShape(Circle())

                CheckmarkShape()
                    .trim(from: 0, to: checkmarkProgress)
                    .stroke(Color.textInverse, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 12)
            }
            .scaleEffect(pulseScale)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .onChange(of: isComplete) { oldValue, newValue in
            if newValue && !oldValue { playCompletionAnimation() }
            else if !newValue && oldValue { resetAnimation() }
        }
        .onAppear {
            if isComplete { fillProgress = 1.0; checkmarkProgress = 1.0 }
        }
    }

    private func handleTap() { onTap() }
    // IMPORTANT: Parent MUST update `isComplete` synchronously after onTap() fires.
    // Async delay will cause animation to lag or not trigger.

    private func playCompletionAnimation() {
        guard !reduceMotion else {
            fillProgress = 1.0; checkmarkProgress = 1.0
            fireHaptics()
            return
        }

        isAnimating = true

        // Phase 1: Radial fill (0.15s)
        withAnimation(.easeOut(duration: 0.15)) { fillProgress = 1.0 }

        // Phase 2: Pulse + haptic at peak
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.bouncy) { pulseScale = 1.15 }
            fireHaptics()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.bouncy) { pulseScale = 1.0 }
            }
        }

        // Phase 3: Checkmark stroke draw
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.2)) { checkmarkProgress = 1.0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isAnimating = false }
    }

    /// Progressive intensity: each level fires its own haptic ON TOP of the base.
    private func fireHaptics() {
        // Level 2: Base — always fires
        HapticManager.setCompleted()

        switch completionLevel {
        case .standard:
            break
        case .exerciseFinal:
            // Level 3: Medium impact for exercise completion (fires after brief delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                HapticManager.modeToggle() // medium impact
            }
        case .workoutFinal:
            // Level 3 + Level 4: Medium then success notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                HapticManager.modeToggle()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                HapticManager.workoutCompleted()
            }
        }
    }

    private func resetAnimation() {
        withAnimation(.easeOut(duration: 0.15)) {
            fillProgress = 0; checkmarkProgress = 0; pulseScale = 1.0; isAnimating = false
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width; let h = rect.height
        path.move(to: CGPoint(x: w * 0.15, y: h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.75))
        path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.25))
        return path
    }
}

// MARK: - Row Flash Effect

struct SetCompletionRowFlash: ViewModifier {
    let trigger: Bool
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Color.accent.opacity(flash ? 0.08 : 0).animation(.easeOut(duration: 0.3), value: flash))
            .onChange(of: trigger) { _, newValue in
                guard newValue, !reduceMotion else { return }
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { flash = false }
            }
    }
}

extension View {
    func setCompletionFlash(trigger: Bool) -> some View { modifier(SetCompletionRowFlash(trigger: trigger)) }
}
```

- [ ] **Step 3: Determine completion level in FocusModeSetGrid/WorkoutScreen**

In `FocusModeWorkoutScreen` or `FocusModeSetGrid`, compute the `CompletionLevel` for each set's done button:

```swift
func completionLevel(for exercise: FocusModeExercise, set: FocusModeSet) -> CompletionLevel {
    guard let workout = service.workout else { return .standard }

    let isLastSetInExercise = exercise.sets.filter { !$0.isDone || $0.id == set.id }.count == 1
    let isLastExercise = workout.exercises.filter { !$0.isComplete || $0.id == exercise.id }.count == 1

    if isLastSetInExercise && isLastExercise { return .workoutFinal }
    if isLastSetInExercise { return .exerciseFinal }
    return .standard
}
```

Pass to `SetCompletionCircle(isComplete:, completionLevel:, onTap:)`.

- [ ] **Step 4: Replace CompletionCircle usage in FocusModeSetGrid**

Replace existing `CompletionCircle` with `SetCompletionCircle`. Add `.setCompletionFlash(trigger:)` on set rows.

- [ ] **Step 5: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/SetCompletionEffect.swift Povver/Povver/UI/FocusMode/FocusModeComponents.swift Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift
git commit -m "feat(workout): set completion signature with progressive intensity

Radial fill -> pulse -> haptic -> checkmark stroke -> row flash.
Progressive: standard (light), exercise final (+medium), workout
final (+success notification). Each level additive."
```

---

### Task 9: Auto-Advance Focus Progression

After set completion, automatically move focus to the next undone set. If next set has ghost values, highlight done button as primary target. Between exercises, scroll to next exercise.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift`

**Reference:** Spec Section 3.1 (Auto-advance), Section 8 (Auto-Advance)

- [ ] **Step 1: Read selectedCell / scrolling in FocusModeWorkoutScreen**

Read `FocusModeWorkoutScreen.swift` focusing on `selectedCell`, `ScrollViewReader`, editing dock presentation.

- [ ] **Step 2: Create testable AutoAdvance helper**

Extract `findNextUndoneSet` as a static function on a new enum so it can be unit tested. Place it in `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift` (at file scope or as a nested enum):

```swift
/// Pure logic for auto-advance — extracted for testability.
enum AutoAdvance {
    struct Target {
        let exerciseIndex: Int
        let exerciseId: String
        let setId: String
    }

    static func findNextUndoneSet(
        exercises: [FocusModeExercise],
        afterExercise exerciseId: String,
        afterSet setId: String
    ) -> Target? {
        guard let currentExerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }) else { return nil }

        let currentExercise = exercises[currentExerciseIndex]

        // Same exercise: next undone set
        if let currentSetIndex = currentExercise.sets.firstIndex(where: { $0.id == setId }) {
            let remaining = currentExercise.sets[(currentSetIndex + 1)...]
            if let next = remaining.first(where: { !$0.isDone }) {
                return Target(exerciseIndex: currentExerciseIndex, exerciseId: exerciseId, setId: next.id)
            }
        }

        // Next exercises
        for i in (currentExerciseIndex + 1)..<exercises.count {
            let ex = exercises[i]
            if let first = ex.sets.first(where: { !$0.isDone }) {
                return Target(exerciseIndex: i, exerciseId: ex.id, setId: first.id)
            }
        }
        return nil
    }
}
```

- [ ] **Step 3: Create AutoAdvance unit tests**

Create `Povver/PovverTests/AutoAdvanceTests.swift`:

```swift
import XCTest
@testable import Povver

final class AutoAdvanceTests: XCTestCase {

    // MARK: - Helpers (adjust constructors to match actual models)

    private func makeExercise(id: String, sets: [FocusModeSet]) -> FocusModeExercise {
        FocusModeExercise(id: id, exerciseId: "eid-\(id)", name: "Ex \(id)", sets: sets)
    }

    private func undoneSet(_ id: String) -> FocusModeSet {
        FocusModeSet(id: id, isDone: false)
    }

    private func doneSet(_ id: String) -> FocusModeSet {
        FocusModeSet(id: id, isDone: true, weight: 80, reps: 8)
    }

    // MARK: - Tests

    func testAdvancesToNextSetInSameExercise() {
        let exercises = [makeExercise(id: "e1", sets: [doneSet("s1"), undoneSet("s2"), undoneSet("s3")])]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s1")
        XCTAssertEqual(target?.setId, "s2")
        XCTAssertEqual(target?.exerciseId, "e1")
    }

    func testAdvancesToNextExercise() {
        let exercises = [
            makeExercise(id: "e1", sets: [doneSet("s1"), doneSet("s2")]),
            makeExercise(id: "e2", sets: [undoneSet("s3"), undoneSet("s4")]),
        ]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s2")
        XCTAssertEqual(target?.exerciseId, "e2")
        XCTAssertEqual(target?.setId, "s3")
    }

    func testReturnsNilWhenAllDone() {
        let exercises = [makeExercise(id: "e1", sets: [doneSet("s1"), doneSet("s2")])]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s2")
        XCTAssertNil(target)
    }

    func testSkipsDoneSetsBetweenUndone() {
        let exercises = [makeExercise(id: "e1", sets: [doneSet("s1"), doneSet("s2"), undoneSet("s3")])]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s1")
        XCTAssertEqual(target?.setId, "s3")
    }

    func testSkipsFullyDoneExercises() {
        let exercises = [
            makeExercise(id: "e1", sets: [doneSet("s1")]),
            makeExercise(id: "e2", sets: [doneSet("s2")]),
            makeExercise(id: "e3", sets: [undoneSet("s3")]),
        ]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s1")
        XCTAssertEqual(target?.exerciseId, "e3")
        XCTAssertEqual(target?.setId, "s3")
    }
}
```

**Note:** Adjust model constructors to match actual initializers.

- [ ] **Step 4: Run tests (red phase)**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild test -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PovverTests/AutoAdvanceTests 2>&1 | tail -10`
Expected: FAIL (AutoAdvance not yet defined)

- [ ] **Step 5: Wire auto-advance into logSet completion**

After `logSet` succeeds, call `AutoAdvance.findNextUndoneSet` and:

1. If next set has ghost values → set `selectedCell` to the done cell (highlight done as primary target)
2. If next set has no ghost values → set `selectedCell` to the weight cell (enter editing)
3. If cross-exercise → scroll to next exercise with Reflow animation

```swift
if let next = AutoAdvance.findNextUndoneSet(
    exercises: service.workout?.exercises ?? [],
    afterExercise: exerciseId,
    afterSet: setId
) {
    let ghostValues = GhostValueResolver.resolve(
        exercise: service.workout!.exercises[next.exerciseIndex],
        lastSession: service.lastSessionData[service.workout!.exercises[next.exerciseIndex].exerciseId]
    )
    let hasGhosts = ghostValues[next.setId]?.hasValues ?? false

    withAnimation(MotionToken.snappy) {
        if hasGhosts {
            selectedCell = .done(exerciseId: next.exerciseId, setId: next.setId)
        } else {
            selectedCell = .weight(exerciseId: next.exerciseId, setId: next.setId)
        }
    }

    // Cross-exercise scroll
    if next.exerciseId != exerciseId {
        withAnimation(.easeInOut(duration: MotionToken.medium)) {
            scrollProxy?.scrollTo(next.exerciseId, anchor: .center) // Active exercise stays centered
        }
    }
}
```

- [ ] **Step 6: Build and run tests (green phase)**

Run build: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Run tests: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild test -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PovverTests/AutoAdvanceTests 2>&1 | tail -10`
Expected: All 5 tests PASS

- [ ] **Step 7: Manual test**

In simulator: start workout, complete sets. Verify auto-advance and cross-exercise scrolling.

- [ ] **Step 8: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift Povver/PovverTests/AutoAdvanceTests.swift
git commit -m "feat(workout): auto-advance focus after set completion

Ghost values present: done button highlighted as primary target.
No ghosts: weight field activates. Cross-exercise: scroll to next.
User can always tap any cell to override auto-advance."
```

---

### Task 10: Exercise Completion Choreography + Contextual Density

Add exercise completion animation (card compression + medium haptic + left-edge indicator) and contextual density (active = 60%, completed = compressed, upcoming = minimal).

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` (ExerciseCardContainer)
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 2.2 (Exercise completed), Section 3.2 (Contextual Density)

- [ ] **Step 1: Read ExerciseCardContainer in FocusModeComponents.swift**

Read the `ExerciseCardContainer` struct to understand current visual hierarchy tiers.

- [ ] **Step 2: Add ExerciseDensity enum and modify ExerciseCardContainer**

```swift
enum ExerciseDensity {
    case active      // Full set grid, 48pt touch targets, ~60% of screen, set values large enough to read at arm's length (use .title3 or equivalent token)
    case completed   // Compressed: name + set count + emerald left-edge. Tappable to expand.
    case upcoming    // Minimal: name + set count, subdued opacity
}
```

Implement the three density modes. Active shows full content. Completed collapses to a single row with a green left-edge accent bar. Upcoming shows exercise name and set count at slightly reduced opacity.

- [ ] **Step 3: Add emerald left-edge indicator for completed exercises**

When all sets done, slide in a 3pt emerald bar on the left edge using Reveal intent. Fire medium impact haptic on the transition. Next exercise expands to active density using Transform intent.

- [ ] **Step 4: Wire density states in FocusModeWorkoutScreen**

```swift
func exerciseDensity(for exercise: FocusModeExercise) -> ExerciseDensity {
    guard let workout = service.workout else { return .active }
    let firstActiveIndex = workout.exercises.firstIndex { !$0.isComplete }
    let exerciseIndex = workout.exercises.firstIndex { $0.id == exercise.id }

    guard let eIdx = exerciseIndex else { return .active }

    if exercise.isComplete { return .completed }
    if eIdx == firstActiveIndex { return .active }
    return .upcoming
}
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeExerciseSection.swift Povver/Povver/UI/FocusMode/FocusModeComponents.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(workout): contextual density + exercise completion choreography

Active: full grid, 48pt targets. Completed: compressed summary +
emerald left-edge + medium haptic. Upcoming: minimal, subdued.
Completed exercises tappable to expand."
```

---

## Phase 3: Destructive Actions & Error Communication

### Task 11: Destructive Action Tiers

Implement all three tiers: Tier 1 (remove set, remove exercise, clear filter, dismiss notification → immediate + undo toast where applicable), Tier 2 (swipe thresholds), Tier 3 (standardize all destructive dialogs across app including delete account).

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeComponents.swift` (FinishWorkoutSheet, SwipeToDeleteRow)
- Modify: `Povver/Povver/UI/Components/Feedback/UndoToast.swift`
- Modify: `Povver/Povver/Services/FocusModeWorkoutService.swift`
- Modify: `Povver/Povver/UI/Routines/RoutineDetailView.swift`
- Modify: `Povver/Povver/UI/Templates/TemplateDetailView.swift`
- Modify: Sign-out view (find exact file)

**Reference:** Spec Section 5 (Destructive Action Tiers)

- [ ] **Step 1: Read exercise/set removal flows**

Read `FocusModeWorkoutScreen.swift` — search for `removeExercise`, `removeSet`, and `confirmationDialog`. Also read `SwipeToDeleteRow` in `FocusModeComponents.swift`.

- [ ] **Step 2: Add undo buffer to FocusModeWorkoutService**

Support undo for both exercise and set removal:

```swift
enum UndoableAction {
    case exerciseRemoved(exercise: FocusModeExercise, index: Int)
    case setRemoved(exerciseId: String, set: FocusModeSet, index: Int)
}

private var undoBuffer: (action: UndoableAction, timer: Timer)?

func removeExerciseWithUndo(exerciseInstanceId: String) { /* ... */ }
func removeSetWithUndo(exerciseInstanceId: String, setId: String) { /* ... */ }
func undoLastRemoval() { /* restore from buffer */ }
```

- [ ] **Step 3: Replace exercise/set removal with Tier 1 (immediate + UndoToast)**

In `FocusModeWorkoutScreen`:
- Remove exercise: immediate removal + UndoToast, no dialog, **no haptic on initial delete**
- Remove set: immediate removal + UndoToast, no dialog, **no haptic on initial delete**
- Clear filter(s): immediate, no toast needed (filter UI updates instantly), no haptic
- Dismiss notification: immediate, no toast needed, no haptic
- If user taps Undo: restore content with **Reveal animation** (opacity 0→1 + 8pt shift) + light impact haptic

Search for filter clear and notification dismiss interactions across the app. Ensure none use confirmation dialogs:

```bash
grep -rn "confirmationDialog\|\.alert" Povver/Povver/ --include="*.swift" | grep -i "filter\|notif\|clear\|dismiss" | head -20
```

Add UndoToast overlay with 5s auto-dismiss. Add light impact haptic on undo tap.

- [ ] **Step 4: Update UndoToast with auto-dismiss and haptic**

Read `Povver/Povver/UI/Components/Feedback/UndoToast.swift`. Add:
- 5-second auto-dismiss timer
- `HapticManager.primaryAction()` on undo tap

- [ ] **Step 5: Verify and adjust Tier 2 swipe thresholds in SwipeToDeleteRow**

Read `SwipeToDeleteRow` in `FocusModeComponents.swift`. Check current threshold values and adjust to match spec:
- Full swipe >150pt: trigger delete + `HapticManager.destructiveAction()` (warning notification)
- Partial swipe >60pt: reveal delete button
- If thresholds differ from spec values, update them. If warning haptic is missing on full swipe, add it.

- [ ] **Step 6: Standardize Tier 3 dialogs across app**

For each Tier 3 action, apply spec copy rules (title = what happens, message = what's lost, destructive button = verb from title, cancel always present). Add `HapticManager.destructiveAction()` after confirm.

**Workout dialogs** in `FinishWorkoutSheet`:
- Finish: "Finish this workout?" / "Your workout will be saved and you'll see a summary." / "Finish"
- Discard: "Discard this workout?" / "Your sets and progress from this session won't be saved." / "Discard"

**Template/Routine delete dialogs** — read `RoutineDetailView.swift` and `TemplateDetailView.swift`, find delete confirmations, apply copy rules:
- Delete template: "Delete this template?" / "This template will be permanently removed." / "Delete"
- Delete routine: "Delete this routine?" / "This routine and its schedule will be permanently removed." / "Delete"

**Settings disabled state** — find weight unit selector (or any custom disabled state in settings). Standardize to `InteractionToken.disabledOpacity` (40% opacity) instead of custom color/style:

```swift
.opacity(isDisabled ? InteractionToken.disabledOpacity : 1.0)
.disabled(isDisabled)
```

**Sign out** — find the sign-out confirmation (likely in `MoreView.swift` or `SecurityView.swift`):
- "Sign out?" / "You'll need to sign in again to access your data." / "Sign Out"

**Delete account** — find the delete account confirmation:
- "Delete your account?" / "All your data will be permanently removed. This cannot be undone." / "Delete Account"

Add `HapticManager.destructiveAction()` after each destructive confirm.

**Rule:** Never disable a destructive button — if the action is irrelevant, hide the button entirely. Disabled states are for fixable conditions only ("fill in email first"), not for hiding irrelevant actions.

Audit for disabled destructive buttons:

```bash
grep -rn "\.disabled\|isEnabled" Povver/Povver/ --include="*.swift" | grep -i "delete\|destructive\|discard\|remove\|sign.out" | head -20
```

If any destructive buttons are conditionally disabled, change to conditionally hidden (use `if` to show/hide, not `.disabled()`).

Also audit all `.confirmationDialog` and `.alert` modifiers with destructive actions to ensure standardized copy.

- [ ] **Step 7: Add deliberate exit fade for Tier 3 destroyed content**

After user confirms a destructive Tier 3 action, the affected content should exit with a slower fade than normal Exit intent — to convey the weight of the action:

```swift
// After confirm:
HapticManager.destructiveAction()
withAnimation(.easeOut(duration: 0.3)) { // Deliberately slower than MotionToken.fast
    // remove/dismiss content
}
```

- [ ] **Step 8: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/UI/FocusMode/FocusModeComponents.swift Povver/Povver/UI/Components/Feedback/UndoToast.swift Povver/Povver/Services/FocusModeWorkoutService.swift Povver/Povver/UI/Routines/RoutineDetailView.swift Povver/Povver/UI/Templates/TemplateDetailView.swift
git commit -m "feat: implement all 3 destructive action tiers across app

Tier 1: remove set/exercise immediate + 5s undo toast.
Tier 2: swipe >150pt confirms, >60pt reveals button.
Tier 3: standardized dialog copy for finish/discard workout, delete
template/routine, sign out. Warning haptic after confirm.
Deliberate exit fade for destroyed content."
```

---

### Task 12: Error Communication System

Create data loading error view, implement all 4 error patterns from spec, add coach escalation path with pre-filled context.

**Files:**
- Create: `Povver/Povver/UI/Components/Feedback/InlineError.swift`
- Create: `Povver/Povver/UI/Components/Feedback/DataLoadingErrorView.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 7 (Error Communication — all 4 patterns)

- [ ] **Step 1: Create InlineError.swift (form submission errors)**

```swift
import SwiftUI

/// Inline error for form submissions with progressive copy and coach escalation.
struct InlineError: View {
    let failureCount: Int
    let firstMessage: String
    let secondMessage: String
    var onCoachTap: (() -> Void)? = nil
    @State private var isVisible = false

    var body: some View {
        if failureCount > 0 {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(failureCount >= 2 ? secondMessage : firstMessage)
                    .textStyle(.caption)
                    .foregroundStyle(Color.destructive)
                if failureCount >= 2, let onCoachTap {
                    Button("Message coach") { onCoachTap() }
                        .textStyle(.caption)
                        .foregroundStyle(Color.accent)
                }
            }
            .revealEffect(isVisible: isVisible)
            .onAppear { isVisible = true }
        }
    }
}
```

- [ ] **Step 2: Create DataLoadingErrorView.swift (data loading errors)**

```swift
import SwiftUI

/// Content-area error state for failed data loads (NOT a toast over empty space).
/// Spec: content area becomes the error state.
struct DataLoadingErrorView: View {
    let failureCount: Int
    let onRetry: () -> Void
    var onCoachTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 32))
                .foregroundStyle(Color.textTertiary)

            Text(failureCount >= 2
                ? "Something's not right. Let us know and we'll sort it out."
                : "Couldn't load right now.")
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Space.sm) {
                PovverButton("Retry", style: .secondary) { onRetry() }

                if failureCount >= 2, let onCoachTap {
                    Button("Message coach") { onCoachTap() }
                        .textStyle(.caption)
                        .foregroundStyle(Color.accent)
                }
            }
        }
        .padding(Space.xl)
    }
}
```

- [ ] **Step 3: Create SyncIndicator for workout sync errors**

Add to InlineError.swift or as a separate view:

```swift
/// Transient sync indicator for workout rows.
/// Optimistic UI stays. Shows subtle indicator, resolves silently on retry success.
/// If persistent (3+ retries / 30s): shows transient toast.
struct SyncIndicator: View {
    let syncState: EntitySyncState // Use existing EntitySyncState from the service

    var body: some View {
        switch syncState {
        case .synced: EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(Color.textTertiary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(Color.warning)
        default: EmptyView()
        }
    }
}
```

- [ ] **Step 4: Add destructive action failure alert pattern**

Create a reusable modifier or approach for destructive action failures:

```swift
// After a destructive action fails:
// Show system alert: "That didn't go through — nothing was deleted. Try again?"
// Buttons: "Try Again" / "Cancel"
.alert("That didn't go through", isPresented: $showDestructiveFailure) {
    Button("Try Again") { retryDestructiveAction() }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("Nothing was deleted. Try again?")
}
```

- [ ] **Step 5: Ensure error transition animations**

When transitioning from loading to error state: use cross-fade (never hard cut). Apply `.transition(.opacity)` on both loading and error views within a shared container:

```swift
if isLoading {
    ProgressView()
        .transition(.opacity)
} else if hasError {
    DataLoadingErrorView(failureCount: failureCount, onRetry: retry)
        .transition(.opacity)
} else {
    ContentView(data: data)
        .revealEffect(isVisible: true)
}
```

When error resolves: error Exits (fade out), content Reveals (opacity + shift in). Apply this pattern everywhere `DataLoadingErrorView` is used.

- [ ] **Step 6: Audit existing error displays for technical language**

Search for places where raw error text might be shown to users:

```bash
grep -rn "\.localizedDescription\|error\.message\|\\\(error\)" Povver/Povver/Views/ Povver/Povver/UI/ --include="*.swift" | head -20
```

Replace any technical error text with user-friendly copy. Spec rule: never show status codes, error class names, or technical identifiers to users.

- [ ] **Step 7: Replace workout error banner with inline sync indicators**

In `FocusModeWorkoutScreen`, change from auto-dismiss banner to:
- Per-row sync indicators using `exerciseSyncState` from `FocusModeWorkoutService`
- Transient toast when EITHER 3+ retries have failed OR 30 seconds have elapsed since first failure (whichever comes first). Copy: "Couldn't save — will retry automatically." Toast slides up from bottom, auto-dismisses.

- [ ] **Step 8: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add Povver/Povver/UI/Components/Feedback/InlineError.swift Povver/Povver/UI/Components/Feedback/DataLoadingErrorView.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(errors): implement all 4 error communication patterns

Form submissions: InlineError with progressive copy + coach escalation.
Data loading: DataLoadingErrorView as content-area error state + cross-fade transitions.
Sync errors: per-row SyncIndicator, toast after 3+/30s threshold.
Destructive failures: system alert with retry/cancel.
Technical error text audited and replaced with user-friendly copy.
Error resolve: Exit animation, content Reveals."
```

---

## Phase 4: Completion Arc & Loading States

### Task 13: Workout Completion Arc

Add held beat before transition, align staggered reveal timing to spec, ensure haptic sequence.

**Constraint (spec Section 6):** Do NOT add confetti, particle effects, sound effects, congratulatory text ("Great job!"), or gamification metrics (streaks, points, XP). The completion arc relies on rhythm and restraint.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`

**Reference:** Spec Section 2.2 (Workout completed), Section 6 (Completion Hierarchy)

- [ ] **Step 1: Read WorkoutCompletionSummary in FocusModeWorkoutHelpers.swift**

Read completely. Focus on `revealPhase` staggering and haptic calls.

- [ ] **Step 2: Add held beat before completion transition**

In `FocusModeWorkoutScreen`, after `completeWorkout()` succeeds:

```swift
// Spec order: final exercise signature → held beat → success haptic → transition
try? await Task.sleep(for: .milliseconds(500)) // Held beat of stillness
HapticManager.workoutCompleted() // Success notification haptic AFTER the beat
completedWorkout = CompletedWorkoutRef(id: archivedId)
```

- [ ] **Step 3: Align staggered reveal timing and content order**

Update reveal phases to spec (0.0s / 0.2s / 0.4s / 0.6s / 0.8s). The five staggered items are:
1. Duration (0.0s)
2. Volume (0.2s)
3. PRs (0.4s)
4. Consistency map (0.6s)
5. Coach reflection (0.8s)

Use `revealEffect(isVisible:)` where possible.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutHelpers.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift
git commit -m "feat(workout): workout completion arc with held beat + staggered reveal

0.5s held beat after final exercise. Success notification haptic.
Staggered summary reveal at 0.0/0.2/0.4/0.6/0.8s intervals."
```

---

### Task 14: Structural Loading States + Sheet Loading

Replace centered `ProgressView()` with structural loading. Add sheet loading pattern. Apply minimum 400ms display for loading indicators.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/Views/Tabs/LibraryView.swift`
- Modify: `Povver/Povver/Views/Tabs/CoachTabView.swift`

**Reference:** Spec Section 1.4 (App is never empty), Section 9 (Navigation & Loading, Sheets)

- [ ] **Step 1: Audit centered ProgressView usage**

```bash
grep -rn "ProgressView()" Povver/Povver/Views/ Povver/Povver/UI/ --include="*.swift" | head -30
```

- [ ] **Step 2: Fix workout start view loading**

Use PovverButton's new loading state:

```swift
PovverButton("Start Session", isLoading: $isStartingWorkout) {
    startWorkout()
}
.buttonHaptic(.medium)
```

Add inline error below CTA on failure using `InlineError`.

- [ ] **Step 3: Fix Library detail view loading**

Replace centered `ProgressView()` with destination view showing immediately, content fading in with Reveal:

```swift
// Show navigation chrome and section structure immediately
// Content area uses revealEffect when data loads
```

- [ ] **Step 4: Fix Library search field focus behavior**

When search field gains focus:
- Border changes to accent color (`StrokeWidthToken.thin`)
- View scrolls to place field visible if needed

Use `PovverTextField` if migrating, or apply focus styling to existing `TextField`.

- [ ] **Step 5: Fix Coach tab loading**

Read `CoachTabView.swift`. Replace centered `ProgressView()` with structural loading — show quick actions and section headers while content loads.

- [ ] **Step 6: Wire minimum 400ms loading display to view transitions**

When a loading indicator appears in any view (not just PovverButton), enforce `InteractionToken.minimumLoadingDisplay` (400ms) before showing content. This prevents flash-of-spinner on fast loads:

```swift
@State private var loadingShowTime: Date?

// When loading starts:
loadingShowTime = Date()

// When data arrives:
let elapsed = Date().timeIntervalSince(loadingShowTime ?? Date())
let remaining = InteractionToken.minimumLoadingDisplay - elapsed
if remaining > 0 {
    try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
}
// Then transition to content with Reveal
```

Apply this pattern to: Library detail views, Coach tab, sheet loading, and any other view where a loading indicator was replaced in Steps 2-5.

- [ ] **Step 7: Add sheet loading pattern**

For sheets that need to load data, show chrome (title, drag indicator) immediately. Show compact `ProgressView()` within the content area, not replacing the sheet:

```swift
.sheet(item: $activeSheet) { sheet in
    NavigationStack {
        if isLoadingSheetData {
            VStack {
                ProgressView()
                    .padding(.top, Space.xxl)
                Spacer()
            }
        } else {
            SheetContent(data: sheetData)
                .revealEffect(isVisible: true)
        }
    }
    .presentationDragIndicator(.visible)
}
```

- [ ] **Step 8: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/Views/Tabs/LibraryView.swift Povver/Povver/Views/Tabs/CoachTabView.swift
git commit -m "feat(loading): structural loading states + 400ms minimum display

Workout start uses PovverButton loading + inline error on failure.
Library: immediate destination view + Reveal on data load + search
focus styling. Coach: section structure during loading. Sheets: chrome
shown immediately, compact spinner in content area. 400ms minimum
loading display enforced before content transition."
```

---

## Phase 5: Screen-by-Screen Polish

### Task 15: Auth Screens Polish

Add PovverTextField migration, PovverButton loading for both login and SSO buttons, progressive inline errors, scroll-to-focus.

**Files:**
- Modify: `Povver/Povver/Views/LoginView.swift`
- Modify: `Povver/Povver/Views/RegisterView.swift`

**Reference:** Spec Section 10 (Auth Screens audit)

- [ ] **Step 1: Read LoginView.swift and RegisterView.swift**

Read both completely. Understand current form structure, `authTextField` helper, error handling, SSO button implementations.

- [ ] **Step 2: Migrate text fields to PovverTextField**

Replace `authTextField` helper with `PovverTextField`:

```swift
PovverTextField("Email", text: $email, validation: emailValidation, keyboardType: .emailAddress, textContentType: .emailAddress)
PovverTextField("Password", text: $password, isSecure: true, textContentType: .password)
```

- [ ] **Step 3: Add PovverButton loading to login AND SSO buttons**

```swift
PovverButton("Log in", isLoading: $isLoading) { await performLogin() }

PovverButton("Continue with Google", style: .secondary, isLoading: $isGoogleLoading,
    leadingIcon: Image("google-icon")) { await signInWithGoogle() }

PovverButton("Continue with Apple", style: .secondary, isLoading: $isAppleLoading,
    leadingIcon: Image(systemName: "apple.logo")) { await signInWithApple() }
```

Disable all buttons while any loading is active.

- [ ] **Step 4: Add progressive inline error**

```swift
@State private var loginFailureCount = 0

// After failed login:
loginFailureCount += 1

// In view, below login button:
InlineError(
    failureCount: loginFailureCount,
    firstMessage: "That didn't work. Try again?",
    secondMessage: "Still not working. Check your connection, or message your coach for help.",
    onCoachTap: { navigateToCoach(withContext: "Hey — I ran into an issue while logging in. Can you help?") }
)
```

Reset count on field edit.

- [ ] **Step 5: Add scroll-to-focus**

Wrap form in `ScrollViewReader`. On field focus, scroll to field above keyboard:

```swift
.onChange(of: focusedField) { _, newField in
    if let field = newField {
        withAnimation { scrollProxy.scrollTo(field, anchor: .center) }
    }
}
```

- [ ] **Step 6: Apply same changes to RegisterView**

- [ ] **Step 7: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add Povver/Povver/Views/LoginView.swift Povver/Povver/Views/RegisterView.swift
git commit -m "feat(auth): PovverTextField, loading states on all buttons, progressive errors

Login/Register use PovverTextField with validation states. All buttons
(login + SSO) use PovverButton loading. Progressive inline errors with
coach escalation. Scroll-to-focus on field activation."
```

---

### Task 16: Coach Tab + AgentPromptBar Polish

Add submit haptic and send arrow Reveal/Exit animation to AgentPromptBar.

**Files:**
- Modify: `Povver/Povver/UI/Components/Inputs/AgentPromptBar.swift`

**Reference:** Spec Section 4.3 (AgentPromptBar)

- [ ] **Step 1: Read AgentPromptBar.swift**

Read `Povver/Povver/UI/Components/Inputs/AgentPromptBar.swift` completely.

- [ ] **Step 2: Add haptic on submit + send arrow animation**

In the submit button:

```swift
Button {
    HapticManager.primaryAction()
    onSubmit()
} label: {
    Image(systemName: "arrow.up.circle.fill")
        // existing styling
}
```

For send arrow appear/disappear, wrap in `revealEffect` / `exitEffect`:

```swift
// When text transitions from empty to non-empty: send arrow Reveals
// When text transitions from non-empty to empty: send arrow Exits
if !text.isEmpty {
    sendButton
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.8)),
            removal: .opacity
        ))
}
```

Use `withAnimation(.easeIn(duration: MotionToken.medium))` for appearance and `withAnimation(.easeOut(duration: MotionToken.fast))` for removal.

- [ ] **Step 3: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/Components/Inputs/AgentPromptBar.swift
git commit -m "feat(coach): submit haptic + send arrow Reveal/Exit animation

Light impact on message submit. Send arrow appears with Reveal (opacity
+ scale) when text entered, disappears with Exit when text cleared."
```

---

### Task 17: Remaining Screen Polish (History, Banner, Haptic Migration, Workout Button Haptics)

Batch of small fixes across History, floating banner, haptic standardization, and workout button haptics.

**Files:**
- Modify: `Povver/Povver/Views/Tabs/HistoryView.swift`
- Modify: `Povver/Povver/Views/MainTabsView.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/Services/FocusModeWorkoutService.swift`

**Reference:** Spec Section 10 (History, Floating Banner, Workout button haptics)

- [ ] **Step 1: Read HistoryView.swift**

Read to check for "Load More" button, empty state, and any raw haptic calls.

- [ ] **Step 2: Redesign History empty state as invitation**

If the empty state is minimal (e.g., just "No workouts yet"), redesign it as an invitation to action:

```swift
VStack(spacing: Space.lg) {
    Image(systemName: "figure.strengthtraining.traditional")
        .font(.system(size: 40))
        .foregroundStyle(Color.textTertiary)
    Text("Your workout history will appear here")
        .textStyle(.secondary)
        .foregroundStyle(Color.textSecondary)
    PovverButton("Start a workout", style: .secondary) {
        // Navigate to Train tab
    }
}
.padding(Space.xl)
```

- [ ] **Step 3: Add loading state to History "Load More"**

If "Load More" uses PovverButton, add `isLoading` binding.

- [ ] **Step 4: Add haptic to floating workout banner**

```swift
FloatingWorkoutBanner(
    onTap: {
        HapticManager.primaryAction()
        selectedTabRaw = MainTab.train.rawValue
    }
)
```

- [ ] **Step 5: Migrate raw UIImpactFeedbackGenerator calls**

Search ALL Swift files for raw UIKit haptic calls (not just workout files — include onboarding, settings, and any other screens):

```bash
grep -rn "UIImpactFeedbackGenerator\|UINotificationFeedbackGenerator\|UISelectionFeedbackGenerator" Povver/Povver/ --include="*.swift" | grep -v "HapticManager"
```

Replace all found instances. Known instances in workout files:
- `toggleReorderMode()` → `HapticManager.modeToggle()`
- `reorderExercisesNew()` → `HapticManager.modeToggle()`
- `addSet()` → `HapticManager.selectionTick()`
- `autofillExercise()` → `HapticManager.modeToggle()`

And 1 in `FocusModeWorkoutService.swift`:
- `addExercise()` → `HapticManager.modeToggle()`

- [ ] **Step 6: Add workout button haptic overrides**

In `FocusModeWorkoutScreen.swift`, add `.buttonHaptic(.medium)` to high-stakes buttons:
- "Start Session" button
- "Finish Workout" button
- "Complete Workout" button (in FinishWorkoutSheet)

- [ ] **Step 7: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add Povver/Povver/Views/Tabs/HistoryView.swift Povver/Povver/Views/MainTabsView.swift Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift Povver/Povver/Services/FocusModeWorkoutService.swift
git commit -m "feat(polish): history empty state, loading, banner haptic, haptic migration

History empty state redesigned as invitation. Load More uses PovverButton
loading. Floating banner fires light impact. ALL raw UIKit haptic calls
migrated to HapticManager (workout, onboarding, settings).
High-stakes workout buttons use .buttonHaptic(.medium)."
```

---

### Task 18: Pre-filled Contexts

Implement the 6 pre-fill rules from spec Section 8 to reduce unnecessary input.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/FocusModeWorkoutScreen.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeSetGrid.swift`
- Modify: `Povver/Povver/UI/FocusMode/FocusModeExerciseSearch.swift`

**Reference:** Spec Section 8 (Pre-filled Contexts table)

- [ ] **Step 1: Audit current pre-fill behavior**

For each of the 6 pre-fill rules, check what currently exists:

| Input | Pre-fill | Current? |
|-------|----------|----------|
| Workout name | Template name if from template, "Workout" if empty start | Check FocusModeWorkoutScreen |
| New set added | Copies weight/reps/RIR from last set in that exercise | Check addSet in service |
| Exercise swap search | Pre-selects same muscle group and equipment | Check FocusModeExerciseSearch |
| Coach message after error | Context about what went wrong | Check coach navigation |
| Coach message from CTA | Entry context (e.g., "Create routine") | Check CoachTabView |
| New exercise in template | 1 working set, 10 reps, no weight, RIR 2 | Check template editing |

- [ ] **Step 2: Implement missing pre-fills**

For each rule that isn't currently implemented:

**Workout name pre-fill:** In `startWorkout()`, if `templateId` is provided, use the template name. If empty start, use "Workout". Check if this already happens.

**New set copies last set:** In `addSet()`, when adding a new set to an exercise, copy weight/reps/RIR from the last existing set:

```swift
func addSet(exerciseInstanceId: String, ...) {
    let exercise = workout.exercises.first { $0.id == exerciseInstanceId }
    let lastSet = exercise?.sets.last
    // Pre-fill new set with lastSet.weight, lastSet.reps, lastSet.rir
}
```

**Exercise swap search pre-select:** In the exercise search sheet (triggered during swap), pre-select the current exercise's muscle group and equipment as default filters.

**Coach message pre-fills:** When navigating to coach after an error, pass context:

```swift
// From error escalation:
navigateToCoach(withMessage: "Hey — I ran into an issue while [saving a template]. Can you help?")

// From CTA (already may exist via entryContext):
navigateToCoach(withMessage: "I'd like to create a routine")
```

**New exercise in template defaults:** When adding an exercise to a template, default to 1 working set, 10 reps, no weight, RIR 2.

- [ ] **Step 3: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A Povver/Povver/
git commit -m "feat(input): implement pre-filled contexts for reduced input

Workout name from template. New set copies last set values.
Exercise swap pre-selects same muscle/equipment. Coach messages
pre-filled with error context. Template exercises default to
1 set, 10 reps, RIR 2."
```

---

## Phase 6: Accessibility & Documentation

### Task 19: Accessibility Audit

Ensure all interactive elements have accessibility labels, Dynamic Type support is verified, and VoiceOver navigation works.

**Files:**
- Modify: Various component and screen files

**Reference:** Spec Section 1.5 (Accessibility is structure, not decoration)

- [ ] **Step 1: Audit accessibility labels on interactive elements**

Search for interactive elements missing accessibility labels:

```bash
grep -rn "Button\|Toggle\|Slider\|Stepper" Povver/Povver/UI/Components/ --include="*.swift" | grep -v "accessibilityLabel\|accessibility" | head -30
```

Focus on:
- `SetCompletionCircle` — needs label: "Mark set [number] complete" / "Undo set [number]"
- `PovverButton` — should inherit title as label (already does via `Text(title)`)
- `PovverTextField` — needs label matching placeholder
- `AgentPromptBar` submit button — needs label: "Send message"
- `FloatingWorkoutBanner` — needs label: "Return to workout"
- Stepper +/- buttons in `FocusModeSetGrid`

- [ ] **Step 2: Add missing accessibility labels**

```swift
// SetCompletionCircle:
.accessibilityLabel(isComplete ? "Undo set completion" : "Mark set complete")
.accessibilityAddTraits(.isButton)

// AgentPromptBar submit:
.accessibilityLabel("Send message")

// FloatingWorkoutBanner:
.accessibilityLabel("Return to \(workoutName)")
.accessibilityHint("Double tap to switch to workout")
```

- [ ] **Step 3: Verify Dynamic Type support**

All text should use `.textStyle()` which maps to system font sizes. Verify that no hardcoded font sizes exist in modified components:

```bash
grep -rn "\.font(.system(size:" Povver/Povver/UI/Components/ --include="*.swift" | head -20
```

For icon-only buttons that use fixed sizes (e.g., the pulsing dot, checkmark), ensure they scale with Dynamic Type by using relative sizing where appropriate.

- [ ] **Step 4: Verify Bold Text and Increased Contrast support**

Bold Text: SwiftUI handles this automatically when using system fonts (`.textStyle()` → Dynamic Type). Verify no custom font weight overrides break bold text rendering:

```bash
grep -rn "\.fontWeight\|\.bold()" Povver/Povver/UI/Components/ --include="*.swift" | head -20
```

Increased Contrast: Check that interactive elements remain distinguishable. Verify design tokens use semantic colors (which adapt to increased contrast mode automatically). If any custom colors are used for state indicators, test with Settings → Accessibility → Increase Contrast.

- [ ] **Step 5: Verify 44pt minimum touch targets outside workout mode**

All interactive elements outside workout mode must meet Apple HIG 44pt minimum. Audit buttons, toggles, and tappable areas:

```bash
grep -rn "\.frame(.*height: [0-3][0-9]\b" Povver/Povver/UI/ --include="*.swift" | grep -v "FocusMode" | head -20
```

If any interactive elements are below 44pt, add `.frame(minHeight: 44)` or adjust padding.

- [ ] **Step 6: Verify Reduce Motion fallbacks**

Confirm that all new animations check `@Environment(\.accessibilityReduceMotion)`:
- `SetCompletionCircle` — already has Reduce Motion path
- `RevealEffect`, `TransformEffect`, `ExitEffect`, `ReflowEffect` — already have fallbacks
- `PovverButton` press/loading — scale is not motion (no fallback needed), pulsing dot could be made static

- [ ] **Step 7: Build and verify**

Run: `cd /Users/valterandersson/Documents/Povver/Povver && xcodebuild -scheme Povver -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add -A Povver/Povver/
git commit -m "feat(a11y): accessibility labels, Dynamic Type, Bold Text, touch targets

Interactive elements: SetCompletionCircle, AgentPromptBar submit,
FloatingWorkoutBanner all have descriptive labels. Dynamic Type via
.textStyle() verified. Bold Text and Increased Contrast verified.
44pt min touch targets outside workout mode. Reduce Motion fallbacks
on all new animations."
```

---

### Task 20: Documentation Update

Update architecture docs to reflect the new interaction system.

**Files:**
- Modify: `Povver/Povver/UI/FocusMode/ARCHITECTURE.md`
- Modify: `docs/IOS_ARCHITECTURE.md`

**Reference:** CLAUDE.md documentation tier guidance

- [ ] **Step 1: Read existing FocusMode ARCHITECTURE.md**

Read `Povver/Povver/UI/FocusMode/ARCHITECTURE.md`.

- [ ] **Step 2: Update FocusMode ARCHITECTURE.md**

Add sections:
- Ghost value resolution flow (last session > template > blank)
- Auto-advance focus progression
- Set completion signature (choreography + progressive intensity)
- Contextual density states (active/completed/upcoming)
- Destructive action tiers (Tier 1 undo, Tier 3 dialogs)
- Forgiveness (tap checkmark to undo)

- [ ] **Step 3: Update IOS_ARCHITECTURE.md Design System section**

Add:
- Motion intents (Respond, Reveal, Transform, Exit, Reflow) with Reduce Motion fallbacks
- Haptic policy (ButtonHapticStyle, rapid succession guard, scroll suppression, `.buttonHaptic()`)
- InteractionToken (press scale, brightness, disabled opacity, loading thresholds)
- PovverButton (5 states: idle, pressed, loading, loaded, disabled)
- PovverTextField (5 states: idle, focused, error, success, disabled)
- Component haptics table
- InlineError + DataLoadingErrorView
- Structural loading pattern
- Pre-filled contexts table

- [ ] **Step 4: Commit**

```bash
git add Povver/Povver/UI/FocusMode/ARCHITECTURE.md docs/IOS_ARCHITECTURE.md
git commit -m "docs: update architecture for input interaction system

FocusMode: ghost values, auto-advance, signature interaction, contextual
density, destructive tiers, forgiveness. Design System: motion intents,
haptic policy, interaction tokens, PovverButton/TextField states,
component haptics, error components, pre-filled contexts."
```

---

## Summary

| Phase | Tasks | Focus |
|-------|-------|-------|
| 1: Foundation | 1-5 | Motion intents, haptic policy, PovverButton, PovverTextField, component haptics |
| 2: Workout Core | 6-10 | Ghost values, forgiveness, auto-advance, signature interaction + progressive intensity, contextual density |
| 3: Destructive & Errors | 11-12 | All 3 tiers across app, all 4 error patterns, coach escalation |
| 4: Completion & Loading | 13-14 | Workout completion arc, structural loading + sheets |
| 5: Screen Polish | 15-18 | Auth (PovverTextField + SSO loading), Coach, History/Banner/haptics, pre-filled contexts |
| 6: Accessibility & Docs | 19-20 | A11y labels, Dynamic Type, Reduce Motion, architecture docs |

**Total: 20 tasks.** Each produces a buildable, committable increment. Tasks within each phase build on each other; phases 2+ depend on Phase 1 foundation.

**Spec coverage:** Every requirement from all 10 sections of the spec is addressed. Section 11 (Out of Scope) items remain out of scope.
