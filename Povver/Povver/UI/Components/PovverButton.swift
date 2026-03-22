import SwiftUI

public enum PovverButtonStyleKind {
    case primary
    case secondary
    case ghost
    case destructive

    var defaultHaptic: ButtonHapticStyle {
        switch self {
        case .primary: return .light
        case .destructive: return .medium
        case .secondary, .ghost: return .none
        }
    }
}

public struct PovverButton: View {
    private let title: String
    private let style: PovverButtonStyleKind
    private let leadingIcon: Image?
    private let trailingIcon: Image?

    // Action variants: exactly one is non-nil
    private let syncAction: (() -> Void)?
    private let asyncAction: (() async -> Void)?

    // Loading state — either internally managed (async init) or externally bound
    @State private var internalLoading = false
    private let externalLoading: Binding<Bool>?

    // Visual sub-states for the loading lifecycle
    @State private var showingIndicator = false
    @State private var showingSuccess = false

    @Environment(\.povverTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonHapticStyle) private var hapticOverride

    private var isLoading: Bool {
        externalLoading?.wrappedValue ?? internalLoading
    }

    private var resolvedHapticStyle: ButtonHapticStyle {
        hapticOverride ?? style.defaultHaptic
    }

    // MARK: - Inits

    /// Synchronous action (backward-compatible with all 36 existing call sites)
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
        self.syncAction = action
        self.asyncAction = nil
        self.externalLoading = nil
    }

    /// Async action — button manages its own loading state
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
        self.syncAction = nil
        self.asyncAction = action
        self.externalLoading = nil
    }

    /// External loading binding — caller controls when loading starts/stops
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
        self.syncAction = action
        self.asyncAction = nil
        self.externalLoading = isLoading
    }

    // MARK: - Body

    public var body: some View {
        Button(action: handleTap) {
            HStack(spacing: Space.sm) {
                if showingIndicator && !showingSuccess {
                    PulsingDot()
                } else if showingSuccess {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    if let leadingIcon {
                        leadingIcon
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: IconSizeToken.md, height: IconSizeToken.md)
                    }
                }
                SwiftUI.Text(title).font(TypographyToken.button)
                if let trailingIcon, !showingIndicator, !showingSuccess {
                    trailingIcon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: IconSizeToken.md, height: IconSizeToken.md)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: theme.buttonHeight)
            .contentShape(Rectangle())
            .frame(minHeight: theme.hitTargetMin)
            .padding(.horizontal, Space.lg)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: StrokeWidthToken.hairline)
            )
        }
        .buttonStyle(PovverPressStyle())
        .disabled(isLoading)
        .opacity(isEnabled ? 1.0 : InteractionToken.disabledOpacity)
        .accessibilityAddTraits(.isButton)
        .onChange(of: isLoading) { _, newValue in
            if newValue {
                startLoadingSequence()
            } else if showingIndicator {
                endLoadingSequence()
            }
        }
    }

    // MARK: - Colors (moved from MappedButtonStyle)

    private var foregroundColor: Color {
        guard isEnabled else { return .textTertiary }
        if showingSuccess && (style == .primary || style == .destructive) {
            return .textInverse
        }
        switch style {
        case .primary: return .textInverse
        case .secondary: return .textPrimary
        case .ghost: return .textPrimary
        case .destructive: return .textInverse
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return .separatorLine }
        if showingSuccess && (style == .primary || style == .destructive) {
            return .success
        }
        switch style {
        case .primary: return .accent
        case .secondary: return .surface
        case .ghost: return .clear
        case .destructive: return .destructive
        }
    }

    private var borderColor: Color {
        guard isEnabled else { return .separatorLine }
        if showingSuccess { return .clear }
        switch style {
        case .primary: return .clear
        case .secondary: return .separatorLine
        case .ghost: return .clear
        case .destructive: return .clear
        }
    }

    // MARK: - Action handling

    private func handleTap() {
        HapticManager.buttonTap(style: resolvedHapticStyle)

        if let asyncAction {
            internalLoading = true
            Task {
                await asyncAction()
                internalLoading = false
            }
        } else {
            syncAction?()
        }
    }

    // MARK: - Loading lifecycle

    private func startLoadingSequence() {
        // Wait loadingDelay before showing indicator (prevents flash for fast ops)
        Task {
            try? await Task.sleep(for: InteractionToken.loadingDelay)
            guard isLoading else { return } // Already finished — skip indicator
            withAnimation(.easeInOut(duration: MotionToken.fast)) {
                showingIndicator = true
            }
        }
    }

    private func endLoadingSequence() {
        Task {
            // Enforce minimum display time once indicator is visible
            try? await Task.sleep(for: InteractionToken.buttonLoadingMinDisplay)

            // Show success flash for primary/destructive
            if style == .primary || style == .destructive {
                withAnimation(.easeInOut(duration: MotionToken.fast)) {
                    showingSuccess = true
                }
                HapticManager.confirmAction()
                try? await Task.sleep(for: .milliseconds(600))
            }

            withAnimation(.easeInOut(duration: MotionToken.fast)) {
                showingIndicator = false
                showingSuccess = false
            }
        }
    }
}

// MARK: - Press Style (scale + brightness only — colors are in the button body)

private struct PovverPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? InteractionToken.pressScale : 1.0)
            .brightness(configuration.isPressed ? InteractionToken.pressBrightness : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Pulsing Dot

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.primary)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 0.8)
            .opacity(isPulsing ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

#if DEBUG
struct PovverButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.md) {
            PovverButton("Primary") {}
            PovverButton("Secondary", style: .secondary) {}
            PovverButton("Ghost", style: .ghost) {}
            PovverButton("Delete", style: .destructive) {}
        }
        .padding(InsetsToken.screen)
    }
}
#endif
