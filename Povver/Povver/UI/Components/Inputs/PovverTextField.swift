import SwiftUI

/// Styled text field with 5 interaction states per spec Section 4.2.
///
/// States:
/// - Idle: hairline border, Color.separatorLine
/// - Focused: accent border, elevated background
/// - Validation error: destructive border, error message below with Reveal
/// - Validation success: success border, fades to idle after 1s
/// - Disabled: 40% opacity, not focusable
public struct PovverTextField: View {
    private let title: String
    @Binding private var text: String
    private let placeholder: String
    private let validation: ValidationState
    private let keyboard: UIKeyboardType
    private let autocapitalization: TextInputAutocapitalization
    private let isSecure: Bool
    private let textContentType: UITextContentType?

    @FocusState private var focused: Bool
    @State private var showSuccess = false
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "",
        validation: ValidationState = .normal,
        keyboard: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .sentences,
        isSecure: Bool = false,
        textContentType: UITextContentType? = nil
    ) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.validation = validation
        self.keyboard = keyboard
        self.autocapitalization = autocapitalization
        self.isSecure = isSecure
        self.textContentType = textContentType
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textContentType(textContentType)
                } else {
                    TextField(placeholder, text: $text)
                        .textContentType(textContentType)
                }
            }
            .textInputAutocapitalization(autocapitalization)
            .keyboardType(keyboard)
            .textStyle(.body)
            .focused($focused)
            .padding(.vertical, Space.sm)
            .padding(.horizontal, Space.md)
            .background(fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .opacity(isEnabled ? 1 : InteractionToken.disabledOpacity)

            // Validation error message with Reveal animation
            if let message = validation.message, validation.isError {
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
        .accessibilityLabel(title)
    }

    private var fieldBackground: Color {
        focused ? Color.surfaceElevated : Color.surface
    }

    private var borderColor: Color {
        if validation.isError { return .destructive }
        if showSuccess || validation.isSuccess { return .success }
        if focused { return .accent }
        return .separatorLine
    }

    private var borderWidth: CGFloat {
        if focused || !validation.isNormal { return StrokeWidthToken.thin }
        return StrokeWidthToken.hairline
    }
}

// MARK: - ValidationState Helpers

private extension ValidationState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }
}

#if DEBUG
struct PovverTextField_Previews: PreviewProvider {
    static var previews: some View {
        StatefulPreviewWrapper("") { binding in
            VStack(alignment: .leading, spacing: Space.lg) {
                PovverTextField("Email", text: binding, placeholder: "you@example.com")
                PovverTextField("Password", text: binding, placeholder: "••••••••", validation: .error(message: "Invalid password"), isSecure: true)
                PovverTextField("Name", text: binding, placeholder: "Jane Doe", validation: .success(message: "Looks good"))
                PovverTextField("Disabled", text: binding, placeholder: "Not editable")
                    .disabled(true)
            }
            .padding(InsetsToken.screen)
        }
    }
}

/// Helper to provide @State bindings in Previews
struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State var value: Value
    var content: (Binding<Value>) -> Content
    init(_ value: Value, content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: value)
        self.content = content
    }
    var body: some View { content($value) }
}
#endif
