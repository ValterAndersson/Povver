import SwiftUI
import OSLog

// MARK: - Design Token Protocols

/// Protocol for all design tokens providing type safety and validation
protocol DesignToken {
    associatedtype Value
    var value: Value { get }
    var fallback: Value { get }
    var identifier: String { get }
}

/// Protocol for themeable design systems
protocol Theme {
    var colorScheme: ColorScheme? { get }
    var identifier: String { get }
    func colorToken(for identifier: String) -> Color
    func fontToken(for identifier: String, size: CGFloat) -> Font
    func spacingToken(for identifier: String) -> CGFloat
}

// MARK: - Token Cache for Performance

@MainActor
final class DesignTokenCache: ObservableObject {
    static let shared = DesignTokenCache()
    
    private var colorCache: [String: Color] = [:]
    private var fontCache: [String: Font] = [:]
    private var gradientCache: [String: LinearGradient] = [:]
    
    private init() {}
    
    func color(for identifier: String, fallback: Color = .primary) -> Color {
        if let cached = colorCache[identifier] {
            return cached
        }
        
        let color = loadColor(identifier: identifier, fallback: fallback)
        colorCache[identifier] = color
        return color
    }
    
    func font(for identifier: String, fallback: Font = .body) -> Font {
        if let cached = fontCache[identifier] {
            return cached
        }
        
        let font = loadFont(identifier: identifier, fallback: fallback)
        fontCache[identifier] = font
        return font
    }
    
    func gradient(for identifier: String, factory: @escaping () -> LinearGradient) -> LinearGradient {
        if let cached = gradientCache[identifier] {
            return cached
        }
        
        let gradient = factory()
        gradientCache[identifier] = gradient
        return gradient
    }
    
    func invalidateCache() {
        colorCache.removeAll()
        fontCache.removeAll()
        gradientCache.removeAll()
    }
    
    private func loadColor(identifier: String, fallback: Color) -> Color {
        // Validate color asset exists
        guard Bundle.main.path(forResource: identifier, ofType: "colorset", inDirectory: "Assets.xcassets") != nil else {
            Logger.designSystem.warning("Color asset '\(identifier)' not found, using fallback")
            return fallback
        }
        
        return Color(identifier)
    }
    
    private func loadFont(identifier: String, fallback: Font) -> Font {
        // For now, return the fallback as we're using system fonts
        return fallback
    }
}

// MARK: - Robust Color Token

@frozen
struct ColorToken: DesignToken {
    let identifier: String
    let fallback: Color
    
    var value: Color {
        DesignTokenCache.shared.color(for: identifier, fallback: fallback)
    }
    
    init(_ identifier: String, fallback: Color = .primary) {
        self.identifier = identifier
        self.fallback = fallback
    }
}

// MARK: - Dynamic Font Token with Accessibility

@frozen
struct FontToken: DesignToken {
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let category: DynamicTypeCategory
    let fallback: Font
    
    var value: Font {
        if UIAccessibility.preferredContentSizeCategory.isAccessibilityCategory {
            return accessibilityFont
        }
        return standardFont
    }
    
    private var standardFont: Font {
        Font.system(size: dynamicSize, weight: weight, design: design)
    }
    
    private var accessibilityFont: Font {
        Font.system(size: min(dynamicSize * 1.5, 34), weight: weight, design: design)
    }
    
    private var dynamicSize: CGFloat {
        let scaleFactor = UIFontMetrics.default.scaledValue(for: baseSize) / baseSize
        return baseSize * scaleFactor
    }
    
    var identifier: String {
        "\(category.rawValue)_\(Int(baseSize))_\(weight)"
    }
    
    init(
        _ baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        category: DynamicTypeCategory = .body
    ) {
        self.baseSize = baseSize
        self.weight = weight
        self.design = design
        self.category = category
        self.fallback = Font.system(size: baseSize, weight: weight, design: design)
    }
}

enum DynamicTypeCategory: String, CaseIterable {
    case display, headline, title, body, label, caption
}

// MARK: - Responsive Spacing Token

@frozen
struct SpacingToken: DesignToken {
    let baseValue: CGFloat
    let scaleCategory: SpacingScale
    let fallback: CGFloat
    
    var value: CGFloat {
        responsiveValue
    }
    
    var identifier: String {
        "\(scaleCategory.rawValue)_\(Int(baseValue))"
    }
    
    private var responsiveValue: CGFloat {
        let screenSize = UIScreen.main.bounds.size
        let baseScreenWidth: CGFloat = 375 // iPhone standard width
        
        if screenSize.width < baseScreenWidth {
            return baseValue * 0.9 // Slightly smaller on smaller screens
        } else if screenSize.width > 414 {
            return baseValue * 1.1 // Slightly larger on larger screens
        }
        
        return baseValue
    }
    
    init(_ baseValue: CGFloat, scale: SpacingScale = .medium) {
        self.baseValue = baseValue
        self.scaleCategory = scale
        self.fallback = baseValue
    }
}

enum SpacingScale: String, CaseIterable {
    case micro, small, medium, large, huge
}

// MARK: - Design System Environment

struct DesignSystemEnvironment {
    var theme: any Theme
    var cache: DesignTokenCache
    var colorScheme: ColorScheme?
    var accessibilityEnabled: Bool
    var preferredContentSizeCategory: UIContentSizeCategory
    
    static var current: DesignSystemEnvironment {
        DesignSystemEnvironment(
            theme: DefaultTheme(),
            cache: .shared,
            colorScheme: nil, // Will use system
            accessibilityEnabled: UIAccessibility.isVoiceOverRunning,
            preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory
        )
    }
}

// MARK: - Environment Key

private struct DesignSystemEnvironmentKey: EnvironmentKey {
    static let defaultValue = DesignSystemEnvironment.current
}

extension EnvironmentValues {
    var designSystem: DesignSystemEnvironment {
        get { self[DesignSystemEnvironmentKey.self] }
        set { self[DesignSystemEnvironmentKey.self] = newValue }
    }
}

// MARK: - Default Theme Implementation

struct DefaultTheme: Theme {
    let identifier = "default"
    let colorScheme: ColorScheme? = nil
    
    func colorToken(for identifier: String) -> Color {
        DesignTokenCache.shared.color(for: identifier)
    }
    
    func fontToken(for identifier: String, size: CGFloat) -> Font {
        DesignTokenCache.shared.font(for: identifier)
    }
    
    func spacingToken(for identifier: String) -> CGFloat {
        SpacingScale.allCases.first { $0.rawValue == identifier }?.baseValue ?? 16
    }
}

extension SpacingScale {
    var baseValue: CGFloat {
        switch self {
        case .micro: return 4
        case .small: return 8
        case .medium: return 16
        case .large: return 24
        case .huge: return 32
        }
    }
}

// MARK: - Logging

extension Logger {
    static let designSystem = Logger(subsystem: "com.myon2.designsystem", category: "DesignSystem")
}

// MARK: - Performance Monitoring

#if DEBUG
struct DesignSystemPerformanceMonitor {
    static var shared = DesignSystemPerformanceMonitor()
    
    private var accessCounts: [String: Int] = [:]
    private var lastResetTime = Date()
    
    mutating func recordAccess(for token: String) {
        accessCounts[token, default: 0] += 1
    }
    
    func printStats() {
        let elapsed = Date().timeIntervalSince(lastResetTime)
        print("🎨 Design System Performance Report (\(String(format: "%.1f", elapsed))s)")
        print("📊 Token Access Counts:")
        
        for (token, count) in accessCounts.sorted(by: { $0.value > $1.value }).prefix(10) {
            print("   \(token): \(count) accesses")
        }
        
        print("🗂 Cache Status:")
        print("   Colors cached: \(DesignTokenCache.shared.colorCache.count)")
        print("   Fonts cached: \(DesignTokenCache.shared.fontCache.count)")
        print("   Gradients cached: \(DesignTokenCache.shared.gradientCache.count)")
    }
    
    mutating func reset() {
        accessCounts.removeAll()
        lastResetTime = Date()
    }
}
#endif