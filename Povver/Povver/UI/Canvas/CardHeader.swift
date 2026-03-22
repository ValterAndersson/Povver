import SwiftUI

public struct CardHeader: View {
    private let title: String?
    private let subtitle: String?
    private let lane: CardLane?
    private let status: CardStatus?
    private let timestamp: Date?
    private let menuActions: [CardAction]
    private let onAction: (CardAction) -> Void

    public init(title: String?, subtitle: String? = nil, lane: CardLane? = nil, status: CardStatus? = nil, timestamp: Date? = nil, menuActions: [CardAction] = [], onAction: @escaping (CardAction) -> Void = { _ in }) {
        self.title = title
        self.subtitle = subtitle
        self.lane = lane
        self.status = status
        self.timestamp = timestamp
        self.menuActions = menuActions
        self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                if let lane {
                    StatusTag(lane.rawValue.capitalized, kind: .info)
                }
                if let status {
                    let kind: StatusKind = (status == .rejected || status == .expired) ? .warning : (status == .accepted || status == .completed ? .success : .info)
                    StatusTag(status.rawValue.capitalized, kind: kind)
                }
                Spacer(minLength: 0)
                if !menuActions.isEmpty {
                    CardOverflowMenu(actions: menuActions, onAction: onAction)
                }
                if let ts = timestamp { Text(Self.format(ts)).textStyle(.caption).foregroundStyle(Color.textSecondary) }
            }
            if let title { Text(title).textStyle(.sectionHeader).lineLimit(2) }
            if let subtitle { Text(subtitle).textStyle(.secondary).foregroundStyle(Color.textSecondary).lineLimit(1) }
        }
    }

    private static func format(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }
}


