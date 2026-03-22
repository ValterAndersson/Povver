import SwiftUI
import Charts

/// Reusable card container for native charts (dashboards, history, etc.).
/// Provides a consistent header (title + trailing metric) and card chrome
/// that matches the design system. Agent-produced charts use VisualizationCard;
/// this is the native counterpart for charts built in Swift.
struct ChartCard<Content: View>: View {
    let title: String
    var metric: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .textStyle(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                if let metric {
                    Text(metric)
                        .textStyle(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            content()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Color.surface)
        // radiusControl (12pt) — compact chart cards, vs radiusCard (16pt) for full content cards
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
}

// MARK: - Shared Chart Axis Styling

extension View {
    /// Standard Y-axis for native charts: gridlines + integer labels using design tokens.
    func chartStandardYAxis(desiredCount: Int = 3) -> some View {
        self.chartYAxis {
            AxisMarks(values: .automatic(desiredCount: desiredCount)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: StrokeWidthToken.hairline))
                    .foregroundStyle(Color.separatorLine)
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text("\(intVal)")
                            .font(TypographyToken.micro)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }
        }
    }
}
