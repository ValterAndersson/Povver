import SwiftUI
import Charts

/// Bar chart for comparisons (e.g., muscle group volume distribution, current vs baseline)
@available(iOS 16.0, *)
public struct BarChartView: View {
    private let spec: VisualizationSpec
    
    public init(spec: VisualizationSpec) {
        self.spec = spec
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // Chart
            if let series = spec.data?.series, !series.isEmpty {
                chartContent(series: series)
            } else {
                emptyState
            }
            
            // Legend (if multiple series)
            if let series = spec.data?.series, series.count > 1 {
                legendView(series: series)
            }
        }
    }
    
    @ViewBuilder
    private func chartContent(series: [ChartSeries]) -> some View {
        let xLabel = spec.data?.xAxis?.label ?? "Category"
        let yLabel = spec.data?.yAxis?.label ?? "Value"
        
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { point in
                    BarMark(
                        x: .value(xLabel, point.label ?? String(Int(point.x))),
                        y: .value(yLabel, point.y)
                    )
                    .foregroundStyle(s.color.color.gradient)
                    .cornerRadius(CornerRadiusToken.radiusIcon)
                }
            }
        }
        .chartXAxisLabel(spec.data?.xAxis?.label ?? "")
        .chartYAxisLabel(spec.data?.yAxis?.label ?? "")
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisValueLabel()
                    .font(TypographyToken.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.separatorLine)
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.separatorLine)
                AxisValueLabel()
                    .font(TypographyToken.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .chartLegend(.hidden)
        .frame(minHeight: 180)
        .padding(.horizontal, Space.xs)
    }
    
    @ViewBuilder
    private func legendView(series: [ChartSeries]) -> some View {
        HStack(spacing: Space.md) {
            ForEach(series) { s in
                HStack(spacing: Space.xs) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(s.color.color)
                        .frame(width: 12, height: 8)
                    Text(s.name)
                        .font(TypographyToken.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .padding(.horizontal, Space.sm)
    }
    
    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                .fill(Color.surface)
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
            Text(spec.emptyState ?? "No data available")
                .font(TypographyToken.callout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 160)
    }
}

// MARK: - Preview

@available(iOS 16.0, *)
struct BarChartView_Previews: PreviewProvider {
    static var previews: some View {
        let spec = VisualizationSpec(
            chartType: .bar,
            title: "Weekly Volume by Muscle",
            subtitle: "Last 4 weeks average",
            data: ChartData(
                xAxis: ChartAxis(key: "muscle", label: "Muscle Group", type: "category"),
                yAxis: ChartAxis(key: "sets", label: "Weekly Sets", unit: "sets"),
                series: [
                    ChartSeries(
                        name: "Volume",
                        color: .primary,
                        points: [
                            ChartDataPoint(x: 0, y: 18, label: "Chest"),
                            ChartDataPoint(x: 1, y: 15, label: "Back"),
                            ChartDataPoint(x: 2, y: 20, label: "Quads"),
                            ChartDataPoint(x: 3, y: 12, label: "Hams"),
                            ChartDataPoint(x: 4, y: 10, label: "Shoulders"),
                            ChartDataPoint(x: 5, y: 8, label: "Arms"),
                        ]
                    )
                ]
            )
        )
        
        BarChartView(spec: spec)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
