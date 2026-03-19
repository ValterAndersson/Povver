import SwiftUI

// MARK: - Dropdown Menu Item

public struct DropdownMenuItem: Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let isDestructive: Bool
    public let action: () -> Void
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.action = action
    }
}

// MARK: - Dropdown Menu View

public struct DropdownMenu: View {
    let items: [DropdownMenuItem]
    let onDismiss: () -> Void
    
    public init(items: [DropdownMenuItem], onDismiss: @escaping () -> Void) {
        self.items = items
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button(action: {
                    onDismiss()
                    item.action()
                }) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(item.isDestructive ? Color.destructive : Color.textSecondary)
                            .frame(width: 20)
                        
                        Text(item.title)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(item.isDestructive ? Color.destructive : Color.textPrimary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DropdownButtonStyle())
                
                if item.id != items.last?.id {
                    Divider()
                        .background(Color.separatorLine.opacity(0.5))
                }
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .stroke(Color.separatorLine.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Button Style

private struct DropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.surfaceElevated : Color.clear)
    }
}

// MARK: - Dropdown Trigger Modifier

public struct DropdownMenuModifier: ViewModifier {
    @Binding var isPresented: Bool
    let items: [DropdownMenuItem]
    let alignment: Alignment
    
    public func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isPresented {
                    DropdownMenu(items: items) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isPresented = false
                        }
                    }
                    .frame(minWidth: 180)
                    .offset(y: alignment == .topTrailing || alignment == .topLeading ? 8 : -8)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: alignment == .topTrailing ? .topTrailing : .bottomTrailing)))
                    .zIndex(100)
                }
            }
            .overlay {
                if isPresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                isPresented = false
                            }
                        }
                }
            }
    }
}

public extension View {
    func dropdownMenu(
        isPresented: Binding<Bool>,
        alignment: Alignment = .topTrailing,
        items: [DropdownMenuItem]
    ) -> some View {
        modifier(DropdownMenuModifier(isPresented: isPresented, items: items, alignment: alignment))
    }
}

// MARK: - Positioned Dropdown Overlay

public struct PositionedDropdown<Content: View>: View {
    @Binding var isPresented: Bool
    let items: [DropdownMenuItem]
    let anchor: UnitPoint
    let content: () -> Content
    
    public init(
        isPresented: Binding<Bool>,
        items: [DropdownMenuItem],
        anchor: UnitPoint = .topTrailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isPresented = isPresented
        self.items = items
        self.anchor = anchor
        self.content = content
    }
    
    public var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
            
            if isPresented {
                // Backdrop
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isPresented = false
                        }
                    }
                
                // Menu
                DropdownMenu(items: items) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isPresented = false
                    }
                }
                .frame(minWidth: 200)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: anchor)))
            }
        }
    }
}
