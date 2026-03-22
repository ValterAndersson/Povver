import SwiftUI

public struct ChatCard: View {
    private let model: CanvasCardModel
    public init(model: CanvasCardModel) { self.model = model }
    public var body: some View {
        CardContainer(status: model.status) {
            VStack(alignment: .leading, spacing: Space.sm) {
                CardHeader(title: model.title, subtitle: model.subtitle, lane: model.lane, status: model.status, timestamp: Date())
                if case .chat(let lines) = model.data {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .textStyle(.body)
                        }
                    }
                }
            }
        }
    }
}


