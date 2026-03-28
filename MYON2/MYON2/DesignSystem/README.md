# MYON2 Design System

A comprehensive, scalable design system for the MYON2 iOS application built with SwiftUI.

## 📁 Structure

```
DesignSystem/
├── Colors/
│   └── ColorPalette.swift          # Color tokens and extensions
├── Typography/
│   └── Typography.swift            # Font tokens and text modifiers
├── Spacing/
│   └── Spacing.swift              # Spacing tokens and layout helpers
├── Components/
│   └── DesignSystemComponents.swift # Enhanced UI components
├── DesignSystem.swift              # Main design system interface
└── README.md                       # This file
```

## 🎨 Design Tokens

### Colors
- **Brand Colors**: Primary, secondary, tertiary brand colors
- **Semantic Colors**: Success, warning, error, info states
- **Surface Colors**: Background and surface variations
- **Text Colors**: Text hierarchy and states
- **Component Colors**: Pre-defined component color mappings

### Typography
- **Display**: Large, attention-grabbing text (57pt, 45pt, 36pt)
- **Headline**: Page and section headers (32pt, 28pt, 24pt)
- **Title**: Content hierarchy (22pt, 20pt, 18pt)
- **Body**: Main content text (17pt, 16pt, 15pt)
- **Label**: UI elements and buttons (17pt, 16pt, 15pt - semibold)
- **Caption**: Supporting text and metadata (14pt, 13pt, 12pt)

### Spacing
- **8-point grid system**: xs(4), sm(8), md(16), lg(24), xl(32), xxl(48), xxxl(64)
- **Component spacing**: Button, card, form, list, modal spacing
- **Layout spacing**: Screen margins, sections, content areas

## 🚀 Quick Start

### 1. Basic Usage

```swift
import SwiftUI

struct MyView: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            Text("Welcome to MYON2")
                .headlineLarge()
                .brandText()
            
            DSButton("Get Started", style: .primary) {
                // action
            }
        }
        .screenMargins()
    }
}
```

### 2. Colors

```swift
// Brand colors
.foregroundColor(.Brand.primary)
.background(.Brand.secondary)

// Semantic colors
.foregroundColor(.Semantic.success)
.background(.Semantic.error)

// Quick access
.foregroundColor(.brandPrimary)
.foregroundColor(.success)
```

### 3. Typography

```swift
Text("Page Title")
    .headlineLarge()
    .primaryText()

Text("Supporting text")
    .bodyMedium()
    .secondaryText()

// Pre-built text styles
Text.pageTitle("Dashboard")
Text.supportingContent("Last updated 2 hours ago")
```

### 4. Spacing & Layout

```swift
VStack {
    // content
}
.paddingMD()
.screenMargins()
.cardContainer()

// Spacing helpers
View.spacerMD()
.cornerRadiusSM()
```

### 5. Components

```swift
// Buttons
DSButton("Primary Action", style: .primary) { }
DSButton("Secondary", style: .secondary, size: .small) { }

// Cards
DSCard(isSelected: true) {
    VStack {
        Text.cardTitle("Card Title")
        Text.supportingContent("Description")
    }
}

// Input fields
DSTextField("Email", text: $email, placeholder: "Enter email")

// Search
DSSearchBar(text: $searchText, placeholder: "Search workouts")
```

## 📱 Components

### DSButton
- **Styles**: primary, secondary, destructive, ghost, link
- **Sizes**: small, medium, large
- **States**: disabled, loading
- **Accessibility**: Full VoiceOver support

### DSCard
- **Features**: Selection state, tap handling, consistent styling
- **Accessibility**: Proper focus management

### DSTextField
- **Features**: Label, placeholder, validation, secure entry
- **States**: Error, disabled
- **Accessibility**: Associated labels and error announcements

### DSSearchBar
- **Features**: Clear button, search action, customizable placeholder
- **Responsive**: Adapts to content

## 🔄 Migration Strategy

### Phase 1: Non-intrusive Introduction (Current)
- ✅ Design system files created
- ✅ Color assets added to Assets.xcassets
- ✅ Existing components remain unchanged
- ✅ New components available alongside existing ones

### Phase 2: Gradual Adoption (Next Steps)
1. **Update new views** to use design system components
2. **Replace hardcoded colors** with design system colors
3. **Standardize typography** in high-impact areas
4. **Adopt spacing system** in new layouts

### Phase 3: Systematic Migration
1. **Audit existing components** for design system opportunities
2. **Update SharedComponents.swift** to use design system
3. **Migrate high-traffic views** to design system
4. **Remove deprecated hardcoded values**

## 🛠 Best Practices

### Colors
```swift
// ✅ DO: Use semantic color names
.foregroundColor(.Brand.primary)
.background(.Surface.secondary)

// ❌ DON'T: Use hardcoded colors
.foregroundColor(.blue)
.background(.gray)
```

### Typography
```swift
// ✅ DO: Use semantic text styles
Text("Title").titleMedium().primaryText()
Text.pageTitle("Dashboard")

// ❌ DON'T: Use arbitrary font sizes
Text("Title").font(.system(size: 20))
```

### Spacing
```swift
// ✅ DO: Use design system spacing
.padding(Spacing.md)
.paddingMD()

// ❌ DON'T: Use arbitrary values
.padding(15)
```

### Components
```swift
// ✅ DO: Use design system components for consistency
DSButton("Action", style: .primary) { }

// ✅ ACCEPTABLE: Extend existing components gradually
Button("Action") { }
    .buttonStyle(PrimaryActionButtonStyle())
```

## 🎯 Benefits

### Consistency
- **Visual coherence** across the entire app
- **Predictable spacing** and layout patterns
- **Unified color palette** with dark mode support

### Developer Experience
- **Faster development** with pre-built components
- **Type-safe design tokens** prevent errors
- **Comprehensive documentation** and examples

### Maintainability
- **Centralized theming** for easy updates
- **Scalable architecture** for future design changes
- **Clear migration path** from existing code

### Accessibility
- **Built-in accessibility** features
- **Consistent focus management**
- **Proper semantic markup**

## 🔧 Customization

### Adding New Colors
1. Add color asset to `Assets.xcassets`
2. Add reference in `ColorPalette.swift`
3. Update documentation

### Adding New Components
1. Create component in `DesignSystemComponents.swift`
2. Follow existing patterns and naming conventions
3. Add to preview in `DesignSystem.swift`

### Extending Typography
1. Add new font tokens to `Typography.swift`
2. Create text modifiers for common use cases
3. Document usage patterns

## 📋 Checklist for New Views

- [ ] Use design system colors instead of hardcoded values
- [ ] Apply semantic typography styles
- [ ] Use spacing system for consistent layouts
- [ ] Leverage design system components where applicable
- [ ] Test in both light and dark modes
- [ ] Verify accessibility with VoiceOver

## 🤝 Contributing

When adding new design patterns:

1. **Check existing components** first
2. **Follow naming conventions**
3. **Add comprehensive documentation**
4. **Include preview examples**
5. **Test accessibility**
6. **Update migration guide**

## 📚 Resources

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [SwiftUI Design System Best Practices](https://developer.apple.com/documentation/swiftui)
- [iOS Accessibility Guidelines](https://developer.apple.com/accessibility/)

---

**Version**: 1.0.0  
**Last Updated**: December 2024  
**Maintained by**: MYON2 Development Team