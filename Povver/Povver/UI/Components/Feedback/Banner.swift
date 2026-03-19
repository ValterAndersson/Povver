import SwiftUI

public enum BannerKind { case info, success, warning, error }

public struct Banner: View {
    private let title: String
    private let message: String?
    private let kind: BannerKind
    public init(title: String, message: String? = nil, kind: BannerKind = .info) {
        self.title = title
        self.message = message
        self.kind = kind
    }
    public var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Icon(iconName, size: .md, color: onColor)
            VStack(alignment: .leading, spacing: Space.xs) {
                PovverText(title, style: .headline, color: onColor)
                if let message { PovverText(message, style: .subheadline, color: onColor) }
            }
            Spacer()
        }
        .padding(InsetsToken.symmetric(vertical: Space.md, horizontal: Space.lg))
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous))
        .shadowStyle(ShadowsToken.level1)
    }

    private var background: Color {
        switch kind {
        case .info: return Color.accent.opacity(0.12)
        case .success: return Color.success.opacity(0.12)
        case .warning: return Color.warning.opacity(0.12)
        case .error: return Color.destructive.opacity(0.12)
        }
    }
    private var onColor: Color {
        switch kind {
        case .info: return Color.accent
        case .success: return Color.success
        case .warning: return Color.warning
        case .error: return Color.destructive
        }
    }
    private var iconName: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}


