import SwiftUI
import Combine

// MARK: - Component State Management

@MainActor
final class ComponentStateManager: ObservableObject {
    @Published var buttonStates: [String: ButtonState] = [:]
    @Published var cardStates: [String: CardState] = [:]
    
    func buttonState(for id: String) -> ButtonState {
        buttonStates[id] ?? ButtonState()
    }
    
    func updateButtonState(for id: String, state: ButtonState) {
        buttonStates[id] = state
    }
    
    func cardState(for id: String) -> CardState {
        cardStates[id] ?? CardState()
    }
    
    func updateCardState(for id: String, state: CardState) {
        cardStates[id] = state
    }
}

// MARK: - Component States

struct ButtonState: Equatable {
    var isPressed: Bool = false
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var lastTapTime: Date = Date()
}

struct CardState: Equatable {
    var isSelected: Bool = false
    var isPressed: Bool = false
    var lastInteractionTime: Date = Date()
}

// MARK: - Highly Optimized Button Component

struct DSButton: View, Equatable {
    
    // MARK: - Configuration
    struct Configuration: Equatable {
        let title: String
        let style: Style
        let size: Size
        let isDisabled: Bool
        let isLoading: Bool
        let icon: String?
        let hapticFeedback: Bool
        
        init(
            title: String,
            style: Style = .primary,
            size: Size = .medium,
            isDisabled: Bool = false,
            isLoading: Bool = false,
            icon: String? = nil,
            hapticFeedback: Bool = true
        ) {
            self.title = title
            self.style = style
            self.size = size
            self.isDisabled = isDisabled
            self.isLoading = isLoading
            self.icon = icon
            self.hapticFeedback = hapticFeedback
        }
    }
    
    enum Style: Equatable {
        case primary, secondary, destructive, ghost, link
    }
    
    enum Size: Equatable {
        case small, medium, large
        
        var font: Font {
            switch self {
            case .small: return .Label.small
            case .medium: return .Label.medium
            case .large: return .Label.large
            }
        }
        
        var padding: EdgeInsets {
            switch self {
            case .small: return EdgeInsets(top: Spacing.xs, leading: Spacing.sm, bottom: Spacing.xs, trailing: Spacing.sm)
            case .medium: return EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)
            case .large: return EdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg)
            }
        }
    }
    
    // MARK: - Properties
    let id: String
    let configuration: Configuration
    let action: () -> Void
    
    @Environment(\.designSystem) private var designSystem
    @StateObject private var stateManager = ComponentStateManager()
    @State private var buttonState = ButtonState()
    
    // MARK: - Initialization
    init(
        _ title: String,
        id: String? = nil,
        style: Style = .primary,
        size: Size = .medium,
        isDisabled: Bool = false,
        isLoading: Bool = false,
        icon: String? = nil,
        hapticFeedback: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.configuration = Configuration(
            title: title,
            style: style,
            size: size,
            isDisabled: isDisabled,
            isLoading: isLoading,
            icon: icon,
            hapticFeedback: hapticFeedback
        )
        self.action = action
    }
    
    // MARK: - Body
    var body: some View {
        Button(action: handleTap) {
            buttonContent
                .padding(configuration.size.padding)
                .frame(maxWidth: configuration.size == .small ? nil : .infinity)
                .frame(minHeight: minHeight)
                .background(backgroundColor)
                .foregroundColor(textColor)
                .overlay(borderOverlay)
                .cornerRadius(cornerRadius)
                .scaleEffect(scaleEffect)
                .opacity(opacity)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isInteractionDisabled)
        .animation(.easeInOut(duration: 0.15), value: buttonState.isPressed)
        .animation(.easeInOut(duration: 0.2), value: configuration.isLoading)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            buttonState.isPressed = pressing && !isInteractionDisabled
        }, perform: {})
    }
    
    // MARK: - Computed Properties
    
    private var buttonContent: some View {
        HStack(spacing: Spacing.sm) {
            if configuration.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(textColor)
            }
            
            if let icon = configuration.icon, !configuration.isLoading {
                Image(systemName: icon)
                    .font(configuration.size.font)
            }
            
            Text(configuration.title)
                .font(configuration.size.font)
                .fontWeight(.medium)
        }
    }
    
    private var backgroundColor: Color {
        switch configuration.style {
        case .primary:
            return Color.Component.buttonPrimary
        case .secondary:
            return Color.Component.buttonSecondary
        case .destructive:
            return Color.Component.buttonDestructive
        case .ghost, .link:
            return Color.clear
        }
    }
    
    private var textColor: Color {
        switch configuration.style {
        case .primary, .destructive:
            return Color.Text.inverse
        case .secondary:
            return Color.Text.primary
        case .ghost, .link:
            return Color.Brand.primary
        }
    }
    
    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(borderColor, lineWidth: borderWidth)
    }
    
    private var borderColor: Color {
        switch configuration.style {
        case .primary, .destructive:
            return Color.clear
        case .secondary:
            return Color.Border.primary
        case .ghost:
            return Color.Brand.primary
        case .link:
            return Color.clear
        }
    }
    
    private var borderWidth: CGFloat {
        configuration.style == .ghost ? 1 : 0
    }
    
    private var cornerRadius: CGFloat {
        switch configuration.size {
        case .small: return Spacing.xs
        case .medium: return Spacing.sm
        case .large: return Spacing.md
        }
    }
    
    private var minHeight: CGFloat {
        switch configuration.size {
        case .small: return 32
        case .medium: return 44
        case .large: return 56
        }
    }
    
    private var scaleEffect: CGFloat {
        buttonState.isPressed ? 0.96 : 1.0
    }
    
    private var opacity: Double {
        isInteractionDisabled ? 0.6 : 1.0
    }
    
    private var isInteractionDisabled: Bool {
        configuration.isDisabled || configuration.isLoading
    }
    
    // MARK: - Actions
    
    private func handleTap() {
        guard !isInteractionDisabled else { return }
        
        // Haptic feedback
        if configuration.hapticFeedback {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        }
        
        // Debounce rapid taps
        let now = Date()
        guard now.timeIntervalSince(buttonState.lastTapTime) > 0.1 else { return }
        buttonState.lastTapTime = now
        
        action()
    }
    
    // MARK: - Equatable
    static func == (lhs: DSButton, rhs: DSButton) -> Bool {
        lhs.id == rhs.id && lhs.configuration == rhs.configuration
    }
}

// MARK: - Optimized Card Component

struct DSCard<Content: View>: View, Equatable {
    
    // MARK: - Configuration
    struct Configuration: Equatable {
        let isSelected: Bool
        let elevation: Elevation
        let cornerRadius: CGFloat
        let padding: EdgeInsets
        let borderWidth: CGFloat
        let hapticFeedback: Bool
        
        init(
            isSelected: Bool = false,
            elevation: Elevation = .medium,
            cornerRadius: CGFloat = Spacing.Component.cardCornerRadius,
            padding: EdgeInsets? = nil,
            borderWidth: CGFloat = 1,
            hapticFeedback: Bool = true
        ) {
            self.isSelected = isSelected
            self.elevation = elevation
            self.cornerRadius = cornerRadius
            self.padding = padding ?? EdgeInsets(
                top: Spacing.md,
                leading: Spacing.md,
                bottom: Spacing.md,
                trailing: Spacing.md
            )
            self.borderWidth = borderWidth
            self.hapticFeedback = hapticFeedback
        }
    }
    
    enum Elevation: Equatable {
        case none, low, medium, high
        
        var shadowRadius: CGFloat {
            switch self {
            case .none: return 0
            case .low: return 1
            case .medium: return 3
            case .high: return 6
            }
        }
        
        var shadowOffset: CGSize {
            switch self {
            case .none: return .zero
            case .low: return CGSize(width: 0, height: 1)
            case .medium: return CGSize(width: 0, height: 2)
            case .high: return CGSize(width: 0, height: 4)
            }
        }
    }
    
    // MARK: - Properties
    let id: String
    let configuration: Configuration
    let content: Content
    let onTap: (() -> Void)?
    
    @State private var cardState = CardState()
    
    // MARK: - Initialization
    init(
        id: String? = nil,
        isSelected: Bool = false,
        elevation: Elevation = .medium,
        cornerRadius: CGFloat = Spacing.Component.cardCornerRadius,
        padding: EdgeInsets? = nil,
        borderWidth: CGFloat = 1,
        hapticFeedback: Bool = true,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id ?? UUID().uuidString
        self.configuration = Configuration(
            isSelected: isSelected,
            elevation: elevation,
            cornerRadius: cornerRadius,
            padding: padding,
            borderWidth: borderWidth,
            hapticFeedback: hapticFeedback
        )
        self.content = content()
        self.onTap = onTap
    }
    
    // MARK: - Body
    var body: some View {
        Group {
            if let onTap = onTap {
                Button(action: handleTap) {
                    cardContent
                }
                .buttonStyle(PlainButtonStyle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
                    cardState.isPressed = pressing
                }, perform: {})
            } else {
                cardContent
            }
        }
    }
    
    private var cardContent: some View {
        content
            .padding(configuration.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay(borderOverlay)
            .cornerRadius(configuration.cornerRadius)
            .shadow(
                color: shadowColor,
                radius: shadowRadius,
                x: shadowOffset.width,
                y: shadowOffset.height
            )
            .scaleEffect(scaleEffect)
            .animation(.easeInOut(duration: 0.15), value: cardState.isPressed)
            .animation(.easeInOut(duration: 0.2), value: configuration.isSelected)
    }
    
    // MARK: - Computed Properties
    
    private var backgroundColor: Color {
        Color.Component.cardBackground
    }
    
    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: configuration.cornerRadius)
            .stroke(borderColor, lineWidth: configuration.borderWidth)
    }
    
    private var borderColor: Color {
        configuration.isSelected ? Color.Brand.primary : Color.Component.cardBorder
    }
    
    private var shadowColor: Color {
        Color.black.opacity(0.1)
    }
    
    private var shadowRadius: CGFloat {
        let baseRadius = configuration.elevation.shadowRadius
        return configuration.isSelected ? baseRadius * 1.5 : baseRadius
    }
    
    private var shadowOffset: CGSize {
        let baseOffset = configuration.elevation.shadowOffset
        return configuration.isSelected ? 
            CGSize(width: baseOffset.width, height: baseOffset.height * 1.5) : 
            baseOffset
    }
    
    private var scaleEffect: CGFloat {
        if cardState.isPressed {
            return 0.98
        } else if configuration.isSelected {
            return 1.02
        } else {
            return 1.0
        }
    }
    
    // MARK: - Actions
    
    private func handleTap() {
        guard let onTap = onTap else { return }
        
        // Haptic feedback
        if configuration.hapticFeedback {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        }
        
        // Debounce rapid taps
        let now = Date()
        guard now.timeIntervalSince(cardState.lastInteractionTime) > 0.1 else { return }
        cardState.lastInteractionTime = now
        
        onTap()
    }
    
    // MARK: - Equatable
    static func == (lhs: DSCard<Content>, rhs: DSCard<Content>) -> Bool {
        lhs.id == rhs.id && lhs.configuration == rhs.configuration
    }
}

// MARK: - Performance Optimized TextField

struct DSTextField: View, Equatable {
    
    struct Configuration: Equatable {
        let label: String
        let placeholder: String
        let isSecure: Bool
        let isDisabled: Bool
        let errorMessage: String?
        let helpText: String?
        let maxLength: Int?
        let keyboardType: UIKeyboardType
        let autocapitalization: TextInputAutocapitalization
        
        init(
            label: String,
            placeholder: String = "",
            isSecure: Bool = false,
            isDisabled: Bool = false,
            errorMessage: String? = nil,
            helpText: String? = nil,
            maxLength: Int? = nil,
            keyboardType: UIKeyboardType = .default,
            autocapitalization: TextInputAutocapitalization = .sentences
        ) {
            self.label = label
            self.placeholder = placeholder
            self.isSecure = isSecure
            self.isDisabled = isDisabled
            self.errorMessage = errorMessage
            self.helpText = helpText
            self.maxLength = maxLength
            self.keyboardType = keyboardType
            self.autocapitalization = autocapitalization
        }
    }
    
    let id: String
    let configuration: Configuration
    @Binding var text: String
    
    @FocusState private var isFocused: Bool
    @State private var internalText: String = ""
    
    init(
        _ label: String,
        text: Binding<String>,
        id: String? = nil,
        placeholder: String = "",
        isSecure: Bool = false,
        isDisabled: Bool = false,
        errorMessage: String? = nil,
        helpText: String? = nil,
        maxLength: Int? = nil,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .sentences
    ) {
        self.id = id ?? label
        self._text = text
        self.configuration = Configuration(
            label: label,
            placeholder: placeholder,
            isSecure: isSecure,
            isDisabled: isDisabled,
            errorMessage: errorMessage,
            helpText: helpText,
            maxLength: maxLength,
            keyboardType: keyboardType,
            autocapitalization: autocapitalization
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Label
            Text(configuration.label)
                .font(.Label.small)
                .foregroundColor(.Text.secondary)
            
            // Input Field
            Group {
                if configuration.isSecure {
                    SecureField(configuration.placeholder, text: $internalText)
                } else {
                    TextField(configuration.placeholder, text: $internalText)
                        .keyboardType(configuration.keyboardType)
                        .textInputAutocapitalization(configuration.autocapitalization)
                }
            }
            .focused($isFocused)
            .padding(Spacing.sm)
            .background(Color.Component.inputBackground)
            .overlay(inputBorder)
            .cornerRadius(Spacing.sm)
            .disabled(configuration.isDisabled)
            .opacity(configuration.isDisabled ? 0.6 : 1.0)
            .onChange(of: internalText) { newValue in
                // Apply max length if specified
                if let maxLength = configuration.maxLength {
                    let limitedValue = String(newValue.prefix(maxLength))
                    if limitedValue != newValue {
                        internalText = limitedValue
                    }
                }
                text = internalText
            }
            .onAppear {
                internalText = text
            }
            
            // Help/Error Text
            if let errorMessage = configuration.errorMessage {
                Text(errorMessage)
                    .font(.Caption.small)
                    .foregroundColor(.Semantic.error)
            } else if let helpText = configuration.helpText {
                Text(helpText)
                    .font(.Caption.small)
                    .foregroundColor(.Text.tertiary)
            }
        }
    }
    
    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: Spacing.sm)
            .stroke(borderColor, lineWidth: 1)
    }
    
    private var borderColor: Color {
        if configuration.errorMessage != nil {
            return Color.Border.error
        } else if isFocused {
            return Color.Component.inputFocus
        } else {
            return Color.Component.inputBorder
        }
    }
    
    static func == (lhs: DSTextField, rhs: DSTextField) -> Bool {
        lhs.id == rhs.id && lhs.configuration == rhs.configuration
    }
}