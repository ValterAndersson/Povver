import SwiftUI

public struct Toast: View {
    private let text: String
    private let icon: String
    public init(_ text: String, icon: String = "checkmark.circle.fill") {
        self.text = text
        self.icon = icon
    }
    public var body: some View {
        HStack(spacing: Space.sm) {
            Icon(icon, size: .md, color: Color.textInverse)
            Text(text).textStyle(.body).foregroundStyle(Color.textInverse)
        }
        .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
        .background(Color.accent)
        .clipShape(Capsule())
        .shadowStyle(ShadowsToken.level2)
    }
}


