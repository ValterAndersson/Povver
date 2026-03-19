import SwiftUI

public struct UndoToast: View {
    private let text: String
    private let onUndo: () -> Void
    public init(_ text: String, onUndo: @escaping () -> Void) {
        self.text = text
        self.onUndo = onUndo
    }
    public var body: some View {
        HStack(spacing: Space.md) {
            Text(text).textStyle(.body).foregroundStyle(Color.textInverse)
            PovverButton("Undo", style: .secondary) { onUndo() }
                .tint(.textInverse)
        }
        .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
        .background(Color.accent)
        .clipShape(Capsule())
        .shadowStyle(ShadowsToken.level2)
    }
}

/// Lightweight transient toast for status/error messages — auto-dismisses after a delay.
public struct TransientToast: View {
    private let text: String
    private let icon: String?
    private let isError: Bool

    public init(_ text: String, icon: String? = nil, isError: Bool = false) {
        self.text = text
        self.icon = icon
        self.isError = isError
    }

    public var body: some View {
        HStack(spacing: Space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isError ? .white : Color.textInverse)
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isError ? .white : Color.textInverse)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(isError ? Color.red.opacity(0.9) : Color.accent)
        .clipShape(Capsule())
        .shadowStyle(ShadowsToken.level2)
    }
}
