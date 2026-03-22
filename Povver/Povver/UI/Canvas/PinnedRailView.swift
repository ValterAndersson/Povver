import SwiftUI

public struct PinnedRailView: View {
    private let cards: [CanvasCardModel]
    private let onTap: (String) -> Void
    public init(cards: [CanvasCardModel], onTap: @escaping (String) -> Void) {
        self.cards = cards
        self.onTap = onTap
    }
    public var body: some View {
        if cards.isEmpty { EmptyView() } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(cards) { card in
                        Button(action: { onTap(card.id) }) {
                            HStack(spacing: Space.xs) {
                                Icon("pin", size: .sm, color: Color.textSecondary)
                                if let t = card.title { Text(t).textStyle(.caption) }
                            }
                            .padding(.vertical, Space.xs)
                            .padding(.horizontal, Space.sm)
                            .background(Color.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline))
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
            }
            .frame(height: 36)
        }
    }
}


