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
