import SwiftUI

// MARK: - v1.1 Premium Visual System Chip
/// A selectable chip/tag component for filters and multi-select
/// Default: neutral appearance, Selected: accentMuted background with accent text

public struct Chip: View {
    private let text: String
    private let isSelected: Bool
    private let icon: Image?
    private let action: () -> Void
    
    /// Creates a Chip with v1.1 styling
    /// - Parameters:
    ///   - text: Chip label text
    ///   - isSelected: Whether the chip is currently selected
    ///   - icon: Optional leading icon
    ///   - action: Tap action
    public init(
        _ text: String,
        isSelected: Bool = false,
        icon: Image? = nil,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.isSelected = isSelected
        self.icon = icon
        self.action = action
    }
    
    public var body: some View {
        Button {
            HapticManager.selectionChanged()
            action()
        } label: {
            HStack(spacing: Space.xs) {
                if let icon {
                    icon
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .textPrimary : .textSecondary)
                }

                Text(text)
                    .textStyle(.secondary)
                    .foregroundColor(isSelected ? .textPrimary : .textSecondary)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(isSelected ? Color.surfaceElevated : Color.surface)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.textTertiary.opacity(0.3) : Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
            )
        }
        .buttonStyle(ChipButtonStyle())
    }
}

// MARK: - Chip Button Style
private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: MotionToken.fast), value: configuration.isPressed)
    }
}

// MARK: - Chip Group (Horizontal scrollable chip collection)
public struct ChipGroup<T: Hashable & Identifiable>: View {
    private let items: [T]
    private let labelKeyPath: KeyPath<T, String>
    @Binding private var selection: Set<T>
    private let allowsMultiple: Bool
    
    public init(
        items: [T],
        labelKeyPath: KeyPath<T, String>,
        selection: Binding<Set<T>>,
        allowsMultiple: Bool = true
    ) {
        self.items = items
        self.labelKeyPath = labelKeyPath
        self._selection = selection
        self.allowsMultiple = allowsMultiple
    }
    
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(items) { item in
                    Chip(
                        item[keyPath: labelKeyPath],
                        isSelected: selection.contains(item)
                    ) {
                        HapticManager.guardedFire(category: "chip") {
                            HapticManager.selectionChanged()
                        }
                        if allowsMultiple {
                            if selection.contains(item) {
                                selection.remove(item)
                            } else {
                                selection.insert(item)
                            }
                        } else {
                            selection = [item]
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
        }
    }
}

#if DEBUG
struct Chip_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.xl) {
            HStack(spacing: Space.sm) {
                Chip("Chest", isSelected: true) {}
                Chip("Back", isSelected: false) {}
                Chip("Legs", isSelected: false) {}
            }
            
            HStack(spacing: Space.sm) {
                Chip("Compound", isSelected: true, icon: Image(systemName: "arrow.up.arrow.down")) {}
                Chip("Isolation", isSelected: false, icon: Image(systemName: "arrow.right")) {}
            }
        }
        .padding()
        .background(Color.bg)
        .previewLayout(.sizeThatFits)
    }
}
#endif
