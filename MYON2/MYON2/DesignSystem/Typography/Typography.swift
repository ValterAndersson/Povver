import SwiftUI

// MARK: - Dynamic Typography System with Accessibility

extension Font {
    
    // MARK: - Display Fonts (Large, attention-grabbing text)
    @frozen
    struct Display {
        static var large: Font { FontToken(57, weight: .regular, category: .display).value }
        static var medium: Font { FontToken(45, weight: .regular, category: .display).value }
        static var small: Font { FontToken(36, weight: .regular, category: .display).value }
        
        // Direct token access for theme switching
        static let largeToken = FontToken(57, weight: .regular, category: .display)
        static let mediumToken = FontToken(45, weight: .regular, category: .display)
        static let smallToken = FontToken(36, weight: .regular, category: .display)
    }
    
    // MARK: - Headline Fonts (Page and section headers)
    @frozen
    struct Headline {
        static var large: Font { FontToken(32, weight: .semibold, category: .headline).value }
        static var medium: Font { FontToken(28, weight: .semibold, category: .headline).value }
        static var small: Font { FontToken(24, weight: .medium, category: .headline).value }
        
        // Tokens
        static let largeToken = FontToken(32, weight: .semibold, category: .headline)
        static let mediumToken = FontToken(28, weight: .semibold, category: .headline)
        static let smallToken = FontToken(24, weight: .medium, category: .headline)
    }
    
    // MARK: - Title Fonts (Content hierarchy)
    @frozen
    struct Title {
        static var large: Font { FontToken(22, weight: .semibold, category: .title).value }
        static var medium: Font { FontToken(20, weight: .medium, category: .title).value }
        static var small: Font { FontToken(18, weight: .medium, category: .title).value }
        
        // Tokens
        static let largeToken = FontToken(22, weight: .semibold, category: .title)
        static let mediumToken = FontToken(20, weight: .medium, category: .title)
        static let smallToken = FontToken(18, weight: .medium, category: .title)
    }
    
    // MARK: - Body Fonts (Main content)
    @frozen
    struct Body {
        static var large: Font { FontToken(17, weight: .regular, category: .body).value }
        static var medium: Font { FontToken(16, weight: .regular, category: .body).value }
        static var small: Font { FontToken(15, weight: .regular, category: .body).value }
        
        // Tokens
        static let largeToken = FontToken(17, weight: .regular, category: .body)
        static let mediumToken = FontToken(16, weight: .regular, category: .body)
        static let smallToken = FontToken(15, weight: .regular, category: .body)
    }
    
    // MARK: - Label Fonts (UI elements, buttons, form labels)
    @frozen
    struct Label {
        static var large: Font { FontToken(17, weight: .semibold, category: .label).value }
        static var medium: Font { FontToken(16, weight: .semibold, category: .label).value }
        static var small: Font { FontToken(15, weight: .semibold, category: .label).value }
        
        // Tokens
        static let largeToken = FontToken(17, weight: .semibold, category: .label)
        static let mediumToken = FontToken(16, weight: .semibold, category: .label)
        static let smallToken = FontToken(15, weight: .semibold, category: .label)
    }
    
    // MARK: - Caption Fonts (Supporting text, metadata)
    @frozen
    struct Caption {
        static var large: Font { FontToken(14, weight: .regular, category: .caption).value }
        static var medium: Font { FontToken(13, weight: .regular, category: .caption).value }
        static var small: Font { FontToken(12, weight: .regular, category: .caption).value }
        
        // Tokens
        static let largeToken = FontToken(14, weight: .regular, category: .caption)
        static let mediumToken = FontToken(13, weight: .regular, category: .caption)
        static let smallToken = FontToken(12, weight: .regular, category: .caption)
    }
    
    // MARK: - Specialized Fonts
    @frozen
    struct Specialized {
        // Monospace for code, numbers, data
        static var code: Font { FontToken(16, weight: .regular, design: .monospaced, category: .body).value }
        static var codeSmall: Font { FontToken(14, weight: .regular, design: .monospaced, category: .caption).value }
        
        // Rounded for playful, modern feel
        static var rounded: Font { FontToken(16, weight: .medium, design: .rounded, category: .body).value }
        static var roundedLarge: Font { FontToken(20, weight: .medium, design: .rounded, category: .title).value }
        
        // Tokens
        static let codeToken = FontToken(16, weight: .regular, design: .monospaced, category: .body)
        static let roundedToken = FontToken(16, weight: .medium, design: .rounded, category: .body)
    }
}

// MARK: - Text Styles with Semantic Meaning

extension Text {
    
    // MARK: - Semantic Text Styles
    func displayLarge() -> some View {
        self.font(.Display.large)
            .lineSpacing(4)
    }
    
    func displayMedium() -> some View {
        self.font(.Display.medium)
            .lineSpacing(3)
    }
    
    func displaySmall() -> some View {
        self.font(.Display.small)
            .lineSpacing(2)
    }
    
    func headlineLarge() -> some View {
        self.font(.Headline.large)
            .lineSpacing(2)
    }
    
    func headlineMedium() -> some View {
        self.font(.Headline.medium)
            .lineSpacing(2)
    }
    
    func headlineSmall() -> some View {
        self.font(.Headline.small)
            .lineSpacing(1)
    }
    
    func titleLarge() -> some View {
        self.font(.Title.large)
            .lineSpacing(1)
    }
    
    func titleMedium() -> some View {
        self.font(.Title.medium)
            .lineSpacing(1)
    }
    
    func titleSmall() -> some View {
        self.font(.Title.small)
            .lineSpacing(1)
    }
    
    func bodyLarge() -> some View {
        self.font(.Body.large)
            .lineSpacing(2)
    }
    
    func bodyMedium() -> some View {
        self.font(.Body.medium)
            .lineSpacing(2)
    }
    
    func bodySmall() -> some View {
        self.font(.Body.small)
            .lineSpacing(1)
    }
    
    func labelLarge() -> some View {
        self.font(.Label.large)
    }
    
    func labelMedium() -> some View {
        self.font(.Label.medium)
    }
    
    func labelSmall() -> some View {
        self.font(.Label.small)
    }
    
    func captionLarge() -> some View {
        self.font(.Caption.large)
            .lineSpacing(1)
    }
    
    func captionMedium() -> some View {
        self.font(.Caption.medium)
            .lineSpacing(1)
    }
    
    func captionSmall() -> some View {
        self.font(.Caption.small)
    }
    
    // MARK: - Specialized Text Styles
    func code() -> some View {
        self.font(.Specialized.code)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.Surface.secondary)
            .cornerRadius(4)
    }
    
    func codeSmall() -> some View {
        self.font(.Specialized.codeSmall)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color.Surface.secondary)
            .cornerRadius(3)
    }
    
    func rounded() -> some View {
        self.font(.Specialized.rounded)
    }
    
    func roundedLarge() -> some View {
        self.font(.Specialized.roundedLarge)
    }
    
    // MARK: - Text Color Styles
    func primaryText() -> some View {
        self.foregroundColor(.Text.primary)
    }
    
    func secondaryText() -> some View {
        self.foregroundColor(.Text.secondary)
    }
    
    func tertiaryText() -> some View {
        self.foregroundColor(.Text.tertiary)
    }
    
    func disabledText() -> some View {
        self.foregroundColor(.Text.disabled)
    }
    
    func inverseText() -> some View {
        self.foregroundColor(.Text.inverse)
    }
    
    func brandText() -> some View {
        self.foregroundColor(.Brand.primary)
    }
    
    func successText() -> some View {
        self.foregroundColor(.Semantic.success)
    }
    
    func warningText() -> some View {
        self.foregroundColor(.Semantic.warning)
    }
    
    func errorText() -> some View {
        self.foregroundColor(.Semantic.error)
    }
    
    func infoText() -> some View {
        self.foregroundColor(.Semantic.info)
    }
}

// MARK: - Text Style Presets for Common Use Cases

extension Text {
    
    // Page titles
    static func pageTitle(_ text: String) -> some View {
        Text(text)
            .headlineLarge()
            .primaryText()
            .multilineTextAlignment(.leading)
    }
    
    // Section headers
    static func sectionHeader(_ text: String) -> some View {
        Text(text)
            .titleMedium()
            .primaryText()
            .multilineTextAlignment(.leading)
    }
    
    // Card titles
    static func cardTitle(_ text: String) -> some View {
        Text(text)
            .titleSmall()
            .primaryText()
            .multilineTextAlignment(.leading)
    }
    
    // Primary content
    static func content(_ text: String) -> some View {
        Text(text)
            .bodyMedium()
            .primaryText()
            .multilineTextAlignment(.leading)
    }
    
    // Supporting content
    static func supportingContent(_ text: String) -> some View {
        Text(text)
            .bodySmall()
            .secondaryText()
            .multilineTextAlignment(.leading)
    }
    
    // Button labels
    static func buttonLabel(_ text: String) -> some View {
        Text(text)
            .labelMedium()
    }
    
    // Form labels
    static func formLabel(_ text: String) -> some View {
        Text(text)
            .labelSmall()
            .secondaryText()
    }
    
    // Metadata and timestamps
    static func metadata(_ text: String) -> some View {
        Text(text)
            .captionMedium()
            .tertiaryText()
    }
}