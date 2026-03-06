import SwiftUI

// MARK: - MYON2 Design System
/**
 * MYON2 Design System
 * 
 * A comprehensive design system providing consistent colors, typography, spacing,
 * and components throughout the MYON2 application.
 *
 * ## Quick Start
 * 
 * Import this file in your views to access the design system:
 * ```swift
 * import SwiftUI
 * // DesignSystem is automatically available
 * ```
 *
 * ## Usage Examples
 *
 * ### Colors
 * ```swift
 * Text("Hello")
 *     .foregroundColor(.Brand.primary)
 *     .background(.Surface.primary)
 * ```
 *
 * ### Typography
 * ```swift
 * Text("Page Title")
 *     .headlineLarge()
 *     .primaryText()
 * ```
 *
 * ### Spacing
 * ```swift
 * VStack {
 *     // content
 * }
 * .paddingMD()
 * .screenMargins()
 * ```
 *
 * ### Components
 * ```swift
 * DSButton("Primary Action", style: .primary) {
 *     // action
 * }
 * 
 * DSCard {
 *     Text("Card content")
 * }
 * ```
 */

// MARK: - Public Design System Interface

public struct DesignSystem {
    
    // MARK: - Version
    public static let version = "1.0.0"
    
    // MARK: - Color Tokens
    public enum ColorTokens {
        // Brand colors
        public static let brandPrimary = Color.Brand.primary
        public static let brandSecondary = Color.Brand.secondary
        public static let brandTertiary = Color.Brand.tertiary
        
        // Semantic colors
        public static let success = Color.Semantic.success
        public static let warning = Color.Semantic.warning
        public static let error = Color.Semantic.error
        public static let info = Color.Semantic.info
        
        // Surface colors
        public static let surfacePrimary = Color.Surface.primary
        public static let surfaceSecondary = Color.Surface.secondary
        public static let surfaceTertiary = Color.Surface.tertiary
        
        // Text colors
        public static let textPrimary = Color.Text.primary
        public static let textSecondary = Color.Text.secondary
        public static let textTertiary = Color.Text.tertiary
    }
    
    // MARK: - Typography Tokens
    public enum TypographyTokens {
        public static let displayLarge = Font.Display.large
        public static let headlineLarge = Font.Headline.large
        public static let titleMedium = Font.Title.medium
        public static let bodyMedium = Font.Body.medium
        public static let labelMedium = Font.Label.medium
        public static let captionMedium = Font.Caption.medium
    }
    
    // MARK: - Spacing Tokens
    public enum SpacingTokens {
        public static let xs = Spacing.xs
        public static let sm = Spacing.sm
        public static let md = Spacing.md
        public static let lg = Spacing.lg
        public static let xl = Spacing.xl
        
        // Component spacing
        public static let cardPadding = Spacing.Component.cardPadding
        public static let buttonPadding = Spacing.Component.buttonPaddingHorizontal
        public static let screenMargin = Spacing.Layout.screenMargin
    }
    
    // MARK: - Component Tokens
    public enum ComponentTokens {
        public static let cardCornerRadius = Spacing.Component.cardCornerRadius
        public static let buttonHeight: CGFloat = 44
        public static let iconSize = Spacing.lg
        public static let shadowRadius: CGFloat = 2
    }
}

// MARK: - Design System Preview
#if DEBUG
struct DesignSystemPreview: View {
    var body: some View {
        NavigationView {
            List {
                Section("Colors") {
                    ColorSampleRow(name: "Brand Primary", color: .Brand.primary)
                    ColorSampleRow(name: "Success", color: .Semantic.success)
                    ColorSampleRow(name: "Warning", color: .Semantic.warning)
                    ColorSampleRow(name: "Error", color: .Semantic.error)
                }
                
                Section("Typography") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Display Large").displayLarge()
                        Text("Headline Medium").headlineMedium()
                        Text("Title Small").titleSmall()
                        Text("Body Medium").bodyMedium()
                        Text("Caption Small").captionSmall()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                Section("Components") {
                    VStack(spacing: Spacing.md) {
                        DSButton("Primary Button", style: .primary) {}
                        DSButton("Secondary Button", style: .secondary) {}
                        DSButton("Destructive Button", style: .destructive) {}
                        
                        DSCard {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text.cardTitle("Card Title")
                                Text.supportingContent("This is a card with some content to demonstrate the design system components.")
                            }
                        }
                    }
                    .paddingVertical()
                }
                
                Section("Spacing") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        SpacingSample(name: "XS", value: Spacing.xs)
                        SpacingSample(name: "SM", value: Spacing.sm)
                        SpacingSample(name: "MD", value: Spacing.md)
                        SpacingSample(name: "LG", value: Spacing.lg)
                        SpacingSample(name: "XL", value: Spacing.xl)
                    }
                }
            }
            .navigationTitle("Design System")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

struct ColorSampleRow: View {
    let name: String
    let color: Color
    
    var body: some View {
        HStack {
            Rectangle()
                .fill(color)
                .frame(width: 40, height: 40)
                .cornerRadiusXS()
            
            Text(name)
                .bodyMedium()
            
            Spacer()
        }
    }
}

struct SpacingSample: View {
    let name: String
    let value: CGFloat
    
    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.Brand.primary)
                .frame(width: value, height: 20)
            
            Text("\(name): \(Int(value))pt")
                .captionMedium()
            
            Spacer()
        }
    }
}

struct DesignSystemPreview_Previews: PreviewProvider {
    static var previews: some View {
        DesignSystemPreview()
    }
}
#endif