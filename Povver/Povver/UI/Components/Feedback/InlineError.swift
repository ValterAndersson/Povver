import SwiftUI

/// Inline error for form submissions with progressive copy and coach escalation.
/// First failure shows `firstMessage`; second+ shows `secondMessage` with optional coach link.
///
/// Simple usage (backward-compatible): `InlineError("Something went wrong")`
/// Progressive usage: `InlineError(failureCount: n, firstMessage: "...", secondMessage: "...")`
struct InlineError: View {
    let failureCount: Int
    let firstMessage: String
    let secondMessage: String
    var onCoachTap: (() -> Void)? = nil
    @State private var isVisible = false

    /// Convenience init for a single static error message (backward-compatible).
    init(_ message: String) {
        self.failureCount = 1
        self.firstMessage = message
        self.secondMessage = message
    }

    init(failureCount: Int, firstMessage: String, secondMessage: String, onCoachTap: (() -> Void)? = nil) {
        self.failureCount = failureCount
        self.firstMessage = firstMessage
        self.secondMessage = secondMessage
        self.onCoachTap = onCoachTap
    }

    var body: some View {
        if failureCount > 0 {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.destructive)
                        .frame(width: IconSizeToken.md, height: IconSizeToken.md)
                    Text(failureCount >= 2 ? secondMessage : firstMessage)
                        .textStyle(.caption)
                        .foregroundStyle(Color.destructive)
                        .lineLimit(2)
                }
                .padding(.vertical, Space.xs)
                .padding(.horizontal, Space.sm)
                .background(Color.destructive.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon, style: .continuous)
                        .stroke(Color.destructive.opacity(0.25), lineWidth: StrokeWidthToken.hairline)
                )
                if failureCount >= 2, let onCoachTap {
                    Button("Message coach") { onCoachTap() }
                        .textStyle(.caption)
                        .foregroundStyle(Color.accent)
                }
            }
            .id(failureCount)
            .revealEffect(isVisible: isVisible)
            .onAppear { isVisible = true }
        }
    }
}

/// Transient sync indicator for workout rows.
/// Shows nothing when synced, a rotating arrow when syncing, and a warning icon on failure.
struct SyncIndicator: View {
    let syncState: EntitySyncState

    var body: some View {
        switch syncState {
        case .synced:
            EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(Color.textTertiary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(Color.warning)
        }
    }
}
