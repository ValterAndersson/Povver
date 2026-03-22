import SwiftUI

public enum StatusKind { case info, success, warning, error }

public struct StatusTag: View {
    private let text: String
    private let kind: StatusKind
    public init(_ text: String, kind: StatusKind = .info) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        SwiftUI.Text(text)
            .font(TypographyToken.caption)
            .foregroundColor(foreground())
            .padding(.vertical, Space.xs)
            .padding(.horizontal, Space.sm)
            .background(background())
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
            )
    }

    private func background() -> Color {
        switch kind {
        case .info: return Color.accentMuted
        case .success: return Color.success.opacity(0.12)
        case .warning: return Color.warning.opacity(0.12)
        case .error: return Color.destructive.opacity(0.12)
        }
    }

    private func foreground() -> Color {
        switch kind {
        case .info: return Color.accent
        case .success: return Color.success
        case .warning: return Color.warning
        case .error: return Color.destructive
        }
    }
}

#if DEBUG
struct StatusTag_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: Space.sm) {
            StatusTag("Info")
            StatusTag("Success", kind: .success)
            StatusTag("Warn", kind: .warning)
            StatusTag("Error", kind: .error)
        }
        .padding(InsetsToken.screen)
    }
}
#endif


