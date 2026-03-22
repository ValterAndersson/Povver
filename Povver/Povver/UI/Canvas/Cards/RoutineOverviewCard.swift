import SwiftUI

public struct RoutineOverviewCard: View {
    private let model: CanvasCardModel
    public init(model: CanvasCardModel) { self.model = model }
    public var body: some View {
        CardContainer(status: model.status) {
            VStack(alignment: .leading, spacing: Space.md) {
                CardHeader(title: model.title ?? "Your Program", subtitle: model.subtitle, lane: model.lane, status: model.status, timestamp: Date(), menuActions: model.menuItems, onAction: { action in
                    let handler = Environment(\.cardActionHandler).wrappedValue
                    handler(action, model)
                })
                if case .routineOverview(let split, let days, let notes) = model.data {
                    HStack(spacing: Space.lg) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Split").textStyle(.caption).foregroundStyle(Color.textSecondary)
                            Text(split).textStyle(.sectionHeader)
                        }
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Days").textStyle(.caption).foregroundStyle(Color.textSecondary)
                            Text(String(days)).textStyle(.sectionHeader)
                        }
                        Spacer()
                    }
                    if let notes { Text(notes).textStyle(.body).foregroundStyle(Color.textSecondary) }
                }
                if !model.actions.isEmpty { CardActionBar(actions: model.actions, onAction: { action in
                    let handler = Environment(\.cardActionHandler).wrappedValue
                    handler(action, model)
                }) }
            }
        }
    }
}


