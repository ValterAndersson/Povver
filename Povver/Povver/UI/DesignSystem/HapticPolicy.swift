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
    func buttonHaptic(_ style: ButtonHapticStyle) -> some View {
        environment(\.buttonHapticStyle, style)
    }
}

// MARK: - Scroll Suppression Modifier

struct ScrollHapticSuppression: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                HapticManager.isScrollingSuppressed = (newPhase == .interacting || newPhase == .decelerating)
            }
        } else {
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
