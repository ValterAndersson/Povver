import SwiftUI

// MARK: - Responsive Spacing System

@frozen
struct Spacing {
    
    // MARK: - Base Spacing Values (8-point grid system)
    static var xs: CGFloat { SpacingToken(4, scale: .micro).value }
    static var sm: CGFloat { SpacingToken(8, scale: .small).value }
    static var md: CGFloat { SpacingToken(16, scale: .medium).value }
    static var lg: CGFloat { SpacingToken(24, scale: .large).value }
    static var xl: CGFloat { SpacingToken(32, scale: .huge).value }
    static var xxl: CGFloat { SpacingToken(48, scale: .huge).value }
    static var xxxl: CGFloat { SpacingToken(64, scale: .huge).value }
    
    // MARK: - Semantic Spacing Values
    static let none: CGFloat = 0
    static let hairline: CGFloat = 1
    static let tiny: CGFloat = 2
    static var micro: CGFloat { xs }
    static var small: CGFloat { sm }
    static var medium: CGFloat { md }
    static var large: CGFloat { lg }
    static var huge: CGFloat { xl }
    static var massive: CGFloat { xxl }
    
    // MARK: - Tokens for Theme Support
    static let xsToken = SpacingToken(4, scale: .micro)
    static let smToken = SpacingToken(8, scale: .small)
    static let mdToken = SpacingToken(16, scale: .medium)
    static let lgToken = SpacingToken(24, scale: .large)
    static let xlToken = SpacingToken(32, scale: .huge)
    
    // MARK: - Component-Specific Spacing
    @frozen
    struct Component {
        // Button spacing
        static var buttonPaddingHorizontal: CGFloat { md }
        static var buttonPaddingVertical: CGFloat { sm + xs } // 12pt
        static var buttonSpacing: CGFloat { sm }
        
        // Card spacing
        static var cardPadding: CGFloat { md }
        static var cardSpacing: CGFloat { md }
        static var cardCornerRadius: CGFloat { sm + xs } // 12pt
        
        // Form spacing
        static var formFieldSpacing: CGFloat { md }
        static var formSectionSpacing: CGFloat { lg }
        static var formLabelSpacing: CGFloat { xs }
        
        // List spacing
        static var listItemPadding: CGFloat { md }
        static var listItemSpacing: CGFloat { sm }
        static var listSectionSpacing: CGFloat { lg }
        
        // Navigation spacing
        static var navigationPadding: CGFloat { md }
        static let tabBarHeight: CGFloat = 48
        
        // Modal spacing
        static var modalPadding: CGFloat { lg }
        static var modalCornerRadius: CGFloat { md }
        
        // Icon spacing
        static var iconSpacing: CGFloat { sm }
        static var iconPadding: CGFloat { xs }
    }
    
    // MARK: - Layout Spacing
    @frozen
    struct Layout {
        // Screen margins
        static var screenMargin: CGFloat { md }
        static var screenMarginLarge: CGFloat { lg }
        
        // Section spacing
        static var sectionSpacing: CGFloat { lg }
        static var sectionPadding: CGFloat { md }
        
        // Content spacing
        static var contentSpacing: CGFloat { md }
        static var contentPadding: CGFloat { md }
        
        // Grid spacing
        static var gridSpacing: CGFloat { md }
        static var gridItemSpacing: CGFloat { sm }
    }
}

// MARK: - Padding Extensions

extension View {
    
    // MARK: - Basic Padding
    func paddingXS() -> some View {
        self.padding(Spacing.xs)
    }
    
    func paddingSM() -> some View {
        self.padding(Spacing.sm)
    }
    
    func paddingMD() -> some View {
        self.padding(Spacing.md)
    }
    
    func paddingLG() -> some View {
        self.padding(Spacing.lg)
    }
    
    func paddingXL() -> some View {
        self.padding(Spacing.xl)
    }
    
    func paddingXXL() -> some View {
        self.padding(Spacing.xxl)
    }
    
    // MARK: - Directional Padding
    func paddingHorizontal(_ amount: CGFloat = Spacing.md) -> some View {
        self.padding(.horizontal, amount)
    }
    
    func paddingVertical(_ amount: CGFloat = Spacing.md) -> some View {
        self.padding(.vertical, amount)
    }
    
    func paddingTop(_ amount: CGFloat = Spacing.md) -> some View {
        self.padding(.top, amount)
    }
    
    func paddingBottom(_ amount: CGFloat = Spacing.md) -> some View {
        self.padding(.bottom, amount)
    }
    
    func paddingLeading(_ amount: CGFloat = Spacing.md) -> some View {
        self.padding(.leading, amount)
    }
    
    func paddingTrailing(_ amount: CGFloat = Spacing.md) -> some View {
        self.padding(.trailing, amount)
    }
    
    // MARK: - Semantic Padding
    func screenMargins() -> some View {
        self.paddingHorizontal(Spacing.Layout.screenMargin)
    }
    
    func cardPadding() -> some View {
        self.padding(Spacing.Component.cardPadding)
    }
    
    func buttonPadding() -> some View {
        self.padding(.horizontal, Spacing.Component.buttonPaddingHorizontal)
            .padding(.vertical, Spacing.Component.buttonPaddingVertical)
    }
    
    func formFieldPadding() -> some View {
        self.paddingVertical(Spacing.Component.formFieldSpacing)
    }
    
    func listItemPadding() -> some View {
        self.padding(Spacing.Component.listItemPadding)
    }
    
    func modalPadding() -> some View {
        self.padding(Spacing.Component.modalPadding)
    }
}

// MARK: - Spacing Extensions

extension View {
    
    // MARK: - Spacer Helpers
    static func spacerXS() -> some View {
        Spacer()
            .frame(height: Spacing.xs)
    }
    
    static func spacerSM() -> some View {
        Spacer()
            .frame(height: Spacing.sm)
    }
    
    static func spacerMD() -> some View {
        Spacer()
            .frame(height: Spacing.md)
    }
    
    static func spacerLG() -> some View {
        Spacer()
            .frame(height: Spacing.lg)
    }
    
    static func spacerXL() -> some View {
        Spacer()
            .frame(height: Spacing.xl)
    }
    
    // MARK: - Spacing Between Elements
    func spacingXS() -> some View {
        VStack(spacing: Spacing.xs) {
            self
        }
    }
    
    func spacingSM() -> some View {
        VStack(spacing: Spacing.sm) {
            self
        }
    }
    
    func spacingMD() -> some View {
        VStack(spacing: Spacing.md) {
            self
        }
    }
    
    func spacingLG() -> some View {
        VStack(spacing: Spacing.lg) {
            self
        }
    }
    
    func spacingXL() -> some View {
        VStack(spacing: Spacing.xl) {
            self
        }
    }
}

// MARK: - Corner Radius Extensions

extension View {
    
    func cornerRadiusXS() -> some View {
        self.cornerRadius(Spacing.xs)
    }
    
    func cornerRadiusSM() -> some View {
        self.cornerRadius(Spacing.sm)
    }
    
    func cornerRadiusMD() -> some View {
        self.cornerRadius(Spacing.md)
    }
    
    func cornerRadiusLG() -> some View {
        self.cornerRadius(Spacing.lg)
    }
    
    func cardCornerRadius() -> some View {
        self.cornerRadius(Spacing.Component.cardCornerRadius)
    }
    
    func modalCornerRadius() -> some View {
        self.cornerRadius(Spacing.Component.modalCornerRadius)
    }
}

// MARK: - Layout Helpers

extension View {
    
    // MARK: - Frame Helpers with Spacing
    func frameSquare(_ size: CGFloat) -> some View {
        self.frame(width: size, height: size)
    }
    
    func frameIcon() -> some View {
        self.frameSquare(Spacing.lg)
    }
    
    func frameIconLarge() -> some View {
        self.frameSquare(Spacing.xl)
    }
    
    func frameButton() -> some View {
        self.frame(minHeight: 44) // iOS minimum touch target
    }
    
    // MARK: - Common Layout Patterns
    func cardContainer() -> some View {
        self
            .cardPadding()
            .background(Color.Surface.primary)
            .cardCornerRadius()
            .shadow(radius: 2)
    }
    
    func sectionContainer() -> some View {
        self
            .padding(Spacing.Layout.sectionPadding)
            .background(Color.Surface.primary)
    }
    
    func screenContainer() -> some View {
        self
            .screenMargins()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Surface.primary)
    }
}