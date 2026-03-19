import SwiftUI

public struct InlineError: View {
    private let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(Color.destructive)
                .frame(width: IconSizeToken.md, height: IconSizeToken.md)
            Text(message).textStyle(.caption).foregroundStyle(Color.destructive)
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
    }
}


