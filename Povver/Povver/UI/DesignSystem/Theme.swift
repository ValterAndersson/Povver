import SwiftUI

/// Povver theme container to allow future theming overrides via Environment.
public struct PovverTheme: Equatable {
    public var cornerRadiusSmall: CGFloat = CornerRadiusToken.radiusIcon
    public var cornerRadiusMedium: CGFloat = CornerRadiusToken.radiusControl
    public var cornerRadiusLarge: CGFloat = CornerRadiusToken.radiusCard
    public var buttonHeight: CGFloat = 48
    public var hitTargetMin: CGFloat = 44
    public var stackSpacing: CGFloat = LayoutToken.stackSpacing
    public init() {}
}

private struct PovverThemeKey: EnvironmentKey {
    static let defaultValue: PovverTheme = PovverTheme()
}

public extension EnvironmentValues {
    var povverTheme: PovverTheme {
        get { self[PovverThemeKey.self] }
        set { self[PovverThemeKey.self] = newValue }
    }
}

public extension View {
    func povverTheme(_ theme: PovverTheme) -> some View {
        environment(\.povverTheme, theme)
    }
}
