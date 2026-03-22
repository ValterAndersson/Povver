import SwiftUI

/// Canvas card for visualizations (line/bar charts, ranked tables)
public struct VisualizationCard: View {
    private let spec: VisualizationSpec
    private let cardId: String
    private let actions: [CardAction]
    
    public init(spec: VisualizationSpec, cardId: String = "", actions: [CardAction] = []) {
        self.spec = spec
        self.cardId = cardId
        self.actions = actions
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Header
            headerView
            
            // Chart content based on type
            chartContent
            
            // Actions
            if !actions.isEmpty {
                actionsRow
            }
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
    
    @ViewBuilder
    private var headerView: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(spec.title)
                    .font(TypographyToken.sectionHeader)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                // Chart type badge
                chartTypeBadge
            }

            if let subtitle = spec.subtitle {
                Text(subtitle)
                    .font(TypographyToken.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }
    
    @ViewBuilder
    private var chartTypeBadge: some View {
        let (icon, label) = chartTypeInfo
        
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(TypographyToken.caption)
        }
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .background(Color.surfaceElevated)
        .clipShape(Capsule())
    }
    
    private var chartTypeInfo: (String, String) {
        switch spec.chartType {
        case .line: return ("chart.line.uptrend.xyaxis", "Trend")
        case .bar: return ("chart.bar.fill", "Comparison")
        case .table: return ("list.number", "Ranking")
        }
    }
    
    @ViewBuilder
    private var chartContent: some View {
        if spec.isEmpty {
            emptyState
        } else {
            switch spec.chartType {
            case .line:
                if #available(iOS 16.0, *) {
                    LineChartView(spec: spec)
                } else {
                    fallbackView
                }
            case .bar:
                if #available(iOS 16.0, *) {
                    BarChartView(spec: spec)
                } else {
                    fallbackView
                }
            case .table:
                RankedTableView(spec: spec)
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(Color.textTertiary)

            Text(spec.emptyState ?? "No data available")
                .font(TypographyToken.secondary)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120)
        .padding(Space.md)
    }
    
    private var fallbackView: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(Color.warning)

            Text("Charts require iOS 16+")
                .font(TypographyToken.secondary)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 100)
    }
    
    @ViewBuilder
    private var actionsRow: some View {
        HStack(spacing: Space.sm) {
            ForEach(actions) { action in
                actionButton(action)
            }
        }
        .padding(.top, Space.xs)
    }
    
    @ViewBuilder
    private func actionButton(_ action: CardAction) -> some View {
        Button {
            // Action handling would be done via environment or callback
        } label: {
            HStack(spacing: Space.xs) {
                if let iconName = action.iconSystemName {
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(action.label)
                    .font(TypographyToken.caption)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(actionBackground(style: action.style))
            .foregroundStyle(actionForeground(style: action.style))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
        }
    }
    
    private func actionBackground(style: CardActionStyle?) -> Color {
        switch style {
        case .primary: return Color.accent
        case .destructive: return Color.destructive
        case .ghost, .none: return Color.surfaceElevated
        default: return Color.separatorLine
        }
    }
    
    private func actionForeground(style: CardActionStyle?) -> Color {
        switch style {
        case .primary, .destructive: return Color.textInverse
        default: return Color.textPrimary
        }
    }
}

// MARK: - Preview

struct VisualizationCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.md) {
            // Line chart preview
            VisualizationCard(
                spec: VisualizationSpec(
                    chartType: .line,
                    title: "Squat e1RM Trend",
                    subtitle: "Last 8 weeks",
                    data: ChartData(
                        xAxis: ChartAxis(key: "week", label: "Week"),
                        yAxis: ChartAxis(key: "e1rm", label: "e1RM", unit: "kg"),
                        series: [
                            ChartSeries(
                                name: "Squat",
                                color: .primary,
                                points: [
                                    ChartDataPoint(x: 1, y: 120),
                                    ChartDataPoint(x: 2, y: 125),
                                    ChartDataPoint(x: 3, y: 123),
                                    ChartDataPoint(x: 4, y: 128),
                                ]
                            )
                        ]
                    )
                ),
                actions: [
                    CardAction(kind: "expand", label: "View Details", style: .ghost, iconSystemName: "arrow.up.left.and.arrow.down.right")
                ]
            )
            
            // Table preview
            VisualizationCard(
                spec: VisualizationSpec(
                    chartType: .table,
                    title: "Top Movers",
                    subtitle: "By e1RM improvement",
                    data: ChartData(
                        rows: [
                            ChartTableRow(rank: 1, label: "Squat", value: "140", delta: 12.5, trend: .up),
                            ChartTableRow(rank: 2, label: "Bench", value: "95", delta: 5.0, trend: .up),
                            ChartTableRow(rank: 3, label: "Deadlift", value: "180", delta: 0, trend: .flat),
                        ]
                    )
                )
            )
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
