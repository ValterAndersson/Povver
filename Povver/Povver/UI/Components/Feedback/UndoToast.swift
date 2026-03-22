import SwiftUI

public struct UndoToast: View {
    private let text: String
    private let onUndo: () -> Void
    private let onDismiss: () -> Void

    /// Auto-dismiss timer handle — cancelled when user taps Undo or view disappears
    @State private var dismissTask: Task<Void, Never>?

    public init(_ text: String, onUndo: @escaping () -> Void, onDismiss: @escaping () -> Void = {}) {
        self.text = text
        self.onUndo = onUndo
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: Space.md) {
            Text(text).textStyle(.body).foregroundStyle(Color.textInverse)
            Button {
                dismissTask?.cancel()
                HapticManager.primaryAction()
                onUndo()
            } label: {
                Text("Undo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.textInverse)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Undo")
        }
        .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
        .background(Color.accent)
        .clipShape(Capsule())
        .shadowStyle(ShadowsToken.level2)
        .onAppear {
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await MainActor.run { onDismiss() }
            }
        }
        .onDisappear {
            dismissTask?.cancel()
        }
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
