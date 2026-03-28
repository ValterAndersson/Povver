import SwiftUI

// MARK: - Robust Color System with Caching and Validation

extension Color {
    
    // MARK: - Brand Colors
    @frozen
    struct Brand {
        static let primary = ColorToken("BrandPrimary", fallback: .blue).value
        static let secondary = ColorToken("BrandSecondary", fallback: .indigo).value
        static let tertiary = ColorToken("BrandTertiary", fallback: .teal).value
        
        // Tokens for direct access with fallbacks
        static let primaryToken = ColorToken("BrandPrimary", fallback: .blue)
        static let secondaryToken = ColorToken("BrandSecondary", fallback: .indigo)
        static let tertiaryToken = ColorToken("BrandTertiary", fallback: .teal)
    }
    
    // MARK: - Semantic Colors
    @frozen
    struct Semantic {
        // Success states
        static let success = ColorToken("SemanticSuccess", fallback: .green).value
        static let successLight = ColorToken("SemanticSuccessLight", fallback: .mint).value
        
        // Warning states
        static let warning = ColorToken("SemanticWarning", fallback: .orange).value
        static let warningLight = ColorToken("SemanticWarningLight", fallback: .yellow).value
        
        // Error states
        static let error = ColorToken("SemanticError", fallback: .red).value
        static let errorLight = ColorToken("SemanticErrorLight", fallback: .pink).value
        
        // Info states
        static let info = ColorToken("SemanticInfo", fallback: .blue).value
        static let infoLight = ColorToken("SemanticInfoLight", fallback: .cyan).value
        
        // Tokens for theme switching
        static let successToken = ColorToken("SemanticSuccess", fallback: .green)
        static let warningToken = ColorToken("SemanticWarning", fallback: .orange)
        static let errorToken = ColorToken("SemanticError", fallback: .red)
        static let infoToken = ColorToken("SemanticInfo", fallback: .blue)
    }
    
    // MARK: - Surface Colors
    @frozen
    struct Surface {
        static let primary = ColorToken("SurfacePrimary", fallback: Color(.systemBackground)).value
        static let secondary = ColorToken("SurfaceSecondary", fallback: Color(.secondarySystemBackground)).value
        static let tertiary = ColorToken("SurfaceTertiary", fallback: Color(.tertiarySystemBackground)).value
        static let elevated = ColorToken("SurfaceElevated", fallback: Color(.systemBackground)).value
        static let overlay = ColorToken("SurfaceOverlay", fallback: Color(.systemBackground).opacity(0.8)).value
    }
    
    // MARK: - Text Colors
    @frozen
    struct Text {
        static let primary = ColorToken("TextPrimary", fallback: Color(.label)).value
        static let secondary = ColorToken("TextSecondary", fallback: Color(.secondaryLabel)).value
        static let tertiary = ColorToken("TextTertiary", fallback: Color(.tertiaryLabel)).value
        static let disabled = ColorToken("TextDisabled", fallback: Color(.quaternaryLabel)).value
        static let inverse = ColorToken("TextInverse", fallback: Color(.systemBackground)).value
    }
    
    // MARK: - Border Colors
    @frozen
    struct Border {
        static let primary = ColorToken("BorderPrimary", fallback: Color(.separator)).value
        static let secondary = ColorToken("BorderSecondary", fallback: Color(.opaqueSeparator)).value
        static let focus = ColorToken("BorderFocus", fallback: Brand.primary).value
        static let error = ColorToken("BorderError", fallback: Semantic.error).value
    }
    
    // MARK: - Component Colors (Computed for Performance)
    @frozen
    struct Component {
        static var buttonPrimary: Color { Brand.primary }
        static var buttonSecondary: Color { Surface.secondary }
        static var buttonDestructive: Color { Semantic.error }
        
        static var cardBackground: Color { Surface.primary }
        static var cardBorder: Color { Border.secondary }
        
        static var inputBackground: Color { Surface.secondary }
        static var inputBorder: Color { Border.primary }
        static var inputFocus: Color { Border.focus }
    }
    
    // MARK: - Utility Colors (for gradual migration)
    @frozen
    struct Utility {
        static let blue = ColorToken("UtilityBlue", fallback: .blue).value
        static let red = ColorToken("UtilityRed", fallback: .red).value
        static let green = ColorToken("UtilityGreen", fallback: .green).value
        static let orange = ColorToken("UtilityOrange", fallback: .orange).value
        static let purple = ColorToken("UtilityPurple", fallback: .purple).value
        static let gray = ColorToken("UtilityGray", fallback: .gray).value
    }
}

// MARK: - Color Extensions for easier usage

extension Color {
    /// Primary brand color - use for main actions and branding
    static let brandPrimary = Brand.primary
    
    /// Secondary brand color - use for secondary actions
    static let brandSecondary = Brand.secondary
    
    /// Success color - use for positive feedback
    static let success = Semantic.success
    
    /// Warning color - use for cautionary feedback
    static let warning = Semantic.warning
    
    /// Error color - use for negative feedback
    static let error = Semantic.error
    
    /// Info color - use for informational feedback
    static let info = Semantic.info
}

// MARK: - Performant Gradient System

extension Color {
    @frozen
    struct Gradients {
        static var brandPrimary: LinearGradient {
            DesignTokenCache.shared.gradient(for: "brandPrimary") {
                LinearGradient(
                    colors: [Brand.primary, Brand.primary.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        
        static var success: LinearGradient {
            DesignTokenCache.shared.gradient(for: "success") {
                LinearGradient(
                    colors: [Semantic.success, Semantic.successLight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        
        static var warning: LinearGradient {
            DesignTokenCache.shared.gradient(for: "warning") {
                LinearGradient(
                    colors: [Semantic.warning, Semantic.warningLight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        
        static var error: LinearGradient {
            DesignTokenCache.shared.gradient(for: "error") {
                LinearGradient(
                    colors: [Semantic.error, Semantic.errorLight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        
        // Custom gradient factory for dynamic creation
        static func custom(
            _ colors: [Color],
            startPoint: UnitPoint = .topLeading,
            endPoint: UnitPoint = .bottomTrailing
        ) -> LinearGradient {
            LinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
        }
    }
}

// MARK: - Color Accessibility & Utilities

extension Color {
    
    /// Returns a color with adjusted opacity for better accessibility
    func accessibleOpacity(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .light:
            return self.opacity(0.8)
        case .dark:
            return self.opacity(0.9)
        @unknown default:
            return self.opacity(0.8)
        }
    }
    
    /// Returns a high-contrast version of the color for accessibility
    func highContrast(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .light:
            return self.mix(with: .black, by: 0.2)
        case .dark:
            return self.mix(with: .white, by: 0.2)
        @unknown default:
            return self
        }
    }
    
    /// Mix two colors together
    private func mix(with color: Color, by percentage: Double) -> Color {
        // This is a simplified version - in production, you'd want proper color space mixing
        return self.opacity(1.0 - percentage).overlay(color.opacity(percentage))
    }
    
    /// Returns appropriate text color for this background
    var contrastingTextColor: Color {
        // Simplified contrast calculation - use system label colors which adapt automatically
        return Color(.label)
    }
}

// MARK: - Theme-aware Color Access

extension Color {
    
    /// Access colors through the current theme
    static func themed(_ identifier: String, fallback: Color = .primary) -> Color {
        // This would integrate with the theme system
        return ColorToken(identifier, fallback: fallback).value
    }
    
    /// Create a color that adapts to the current color scheme
    static func adaptive(light: Color, dark: Color) -> Color {
        return Color(UIColor { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .dark:
                return UIColor(dark)
            default:
                return UIColor(light)
            }
        })
    }
}