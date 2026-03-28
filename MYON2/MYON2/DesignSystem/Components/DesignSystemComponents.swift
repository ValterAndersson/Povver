import SwiftUI

// MARK: - Enhanced Design System Components

// MARK: - Buttons
struct DSButton: View {
    enum Style {
        case primary
        case secondary
        case destructive
        case ghost
        case link
    }
    
    enum Size {
        case small
        case medium
        case large
    }
    
    let title: String
    let style: Style
    let size: Size
    let action: () -> Void
    let isDisabled: Bool
    let isLoading: Bool
    
    init(
        _ title: String,
        style: Style = .primary,
        size: Size = .medium,
        isDisabled: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.size = size
        self.isDisabled = isDisabled
        self.isLoading = isLoading
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(textColor)
                }
                
                Text(title)
                    .font(fontSize)
                    .foregroundColor(textColor)
            }
            .buttonPadding()
            .frame(maxWidth: size == .small ? nil : .infinity)
            .frameButton()
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.Component.cardCornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cardCornerRadius()
        }
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
    
    private var backgroundColor: Color {
        switch style {
        case .primary:
            return Color.Component.buttonPrimary
        case .secondary:
            return Color.Component.buttonSecondary
        case .destructive:
            return Color.Component.buttonDestructive
        case .ghost:
            return Color.clear
        case .link:
            return Color.clear
        }
    }
    
    private var textColor: Color {
        switch style {
        case .primary:
            return Color.Text.inverse
        case .secondary:
            return Color.Text.primary
        case .destructive:
            return Color.Text.inverse
        case .ghost:
            return Color.Brand.primary
        case .link:
            return Color.Brand.primary
        }
    }
    
    private var borderColor: Color {
        switch style {
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
    
    private var fontSize: Font {
        switch size {
        case .small:
            return .Label.small
        case .medium:
            return .Label.medium
        case .large:
            return .Label.large
        }
    }
}

// MARK: - Cards
struct DSCard<Content: View>: View {
    let content: Content
    let isSelected: Bool
    let onTap: (() -> Void)?
    
    init(
        isSelected: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.onTap = onTap
        self.content = content()
    }
    
    var body: some View {
        Group {
            if let onTap = onTap {
                Button(action: onTap) {
                    cardContent
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                cardContent
            }
        }
    }
    
    private var cardContent: some View {
        content
            .cardPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Component.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.Component.cardCornerRadius)
                    .stroke(
                        isSelected ? Color.Brand.primary : Color.Component.cardBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .cardCornerRadius()
            .shadow(
                color: Color.black.opacity(0.1),
                radius: isSelected ? 4 : 2,
                x: 0,
                y: isSelected ? 2 : 1
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - Input Fields
struct DSTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let isDisabled: Bool
    let errorMessage: String?
    
    init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        isDisabled: Bool = false,
        errorMessage: String? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.isDisabled = isDisabled
        self.errorMessage = errorMessage
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.Component.formLabelSpacing) {
            Text.formLabel(label)
            
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .padding(Spacing.sm)
            .background(Color.Component.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.sm)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cornerRadiusSM()
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1.0)
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .captionSmall()
                    .errorText()
            }
        }
    }
    
    private var borderColor: Color {
        if let _ = errorMessage {
            return Color.Border.error
        }
        return Color.Component.inputBorder
    }
}

// MARK: - Enhanced Filter Chips
struct DSFilterChips: View {
    let title: String
    let options: [String]
    @Binding var selectedOption: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text.sectionHeader(title)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    DSFilterChip(
                        title: "All",
                        isSelected: selectedOption == nil
                    ) {
                        selectedOption = nil
                    }
                    
                    ForEach(options, id: \.self) { option in
                        DSFilterChip(
                            title: option,
                            isSelected: selectedOption == option
                        ) {
                            selectedOption = option
                        }
                    }
                }
                .paddingHorizontal()
            }
        }
    }
}

struct DSFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .labelSmall()
                .foregroundColor(isSelected ? Color.Text.inverse : Color.Text.primary)
                .paddingHorizontal(Spacing.sm)
                .paddingVertical(Spacing.xs)
                .background(isSelected ? Color.Brand.primary : Color.Surface.secondary)
                .cornerRadiusSM()
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.sm)
                        .stroke(
                            isSelected ? Color.clear : Color.Border.primary,
                            lineWidth: 1
                        )
                )
        }
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - Enhanced Search Bar
struct DSSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSearchTapped: (() -> Void)?
    
    init(
        text: Binding<String>,
        placeholder: String = "Search",
        onSearchTapped: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onSearchTapped = onSearchTapped
    }
    
    var body: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.Text.secondary)
                    .frameIcon()
                
                TextField(placeholder, text: $text)
                    .bodyMedium()
                
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.Text.secondary)
                    }
                }
            }
            .padding(Spacing.sm)
            .background(Color.Component.inputBackground)
            .cornerRadiusSM()
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.sm)
                    .stroke(Color.Component.inputBorder, lineWidth: 1)
            )
            
            if let onSearchTapped = onSearchTapped {
                DSButton("Search", style: .primary, size: .small) {
                    onSearchTapped()
                }
            }
        }
    }
}

// MARK: - Loading and Error States
struct DSLoadingView: View {
    let message: String
    
    init(_ message: String = "Loading...") {
        self.message = message
    }
    
    var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.Brand.primary)
            
            Text(message)
                .bodyMedium()
                .secondaryText()
        }
        .screenContainer()
    }
}

struct DSErrorView: View {
    let title: String
    let message: String
    let retryAction: (() -> Void)?
    
    init(
        title: String = "Something went wrong",
        message: String,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }
    
    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.Semantic.warning)
                
                Text.sectionHeader(title)
                
                Text.supportingContent(message)
                    .multilineTextAlignment(.center)
            }
            
            if let retryAction = retryAction {
                DSButton("Try Again", style: .primary) {
                    retryAction()
                }
            }
        }
        .screenContainer()
    }
}

// MARK: - Enhanced Tag List
struct DSTagList: View {
    let tags: [String]
    let color: Color
    
    init(tags: [String], color: Color = .Brand.primary) {
        self.tags = tags
        self.color = color
    }
    
    var body: some View {
        FlowLayout(spacing: Spacing.xs) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .captionMedium()
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(color.opacity(0.1))
                    .foregroundColor(color)
                    .cornerRadiusXS()
            }
        }
    }
}

// MARK: - Section Headers
struct DSSectionHeader: View {
    let title: String
    let subtitle: String?
    let action: (() -> Void)?
    let actionTitle: String?
    
    init(
        _ title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text.sectionHeader(title)
                    
                    if let subtitle = subtitle {
                        Text.supportingContent(subtitle)
                    }
                }
                
                Spacer()
                
                if let action = action, let actionTitle = actionTitle {
                    DSButton(actionTitle, style: .link, size: .small) {
                        action()
                    }
                }
            }
        }
        .paddingHorizontal()
    }
}