import SwiftUI

/// Content-area error state for failed data loads.
/// Replaces the content area itself (not a toast over empty space).
/// Callers should use `.transition(.opacity)` when switching between loading/error/content states.
struct DataLoadingErrorView: View {
    let failureCount: Int
    let onRetry: () -> Void
    var onCoachTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 32))
                .foregroundStyle(Color.textTertiary)

            Text(failureCount >= 2
                ? "Something's not right. Let us know and we'll sort it out."
                : "Couldn't load right now.")
                .textStyle(.secondary)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Space.sm) {
                PovverButton("Retry", style: .secondary) { onRetry() }

                if failureCount >= 2, let onCoachTap {
                    Button("Message coach") { onCoachTap() }
                        .textStyle(.caption)
                        .foregroundStyle(Color.accent)
                }
            }
        }
        .padding(Space.xl)
    }
}
