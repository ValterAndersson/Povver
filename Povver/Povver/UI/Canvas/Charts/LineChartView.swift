import SwiftUI
import Charts

/// Line chart for time series data (e.g., e1RM trends, weekly volume)
@available(iOS 16.0, *)
public struct LineChartView: View {
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
        let xLabel = spec.data?.xAxis?.label ?? "X"
        let yLabel = spec.data?.yAxis?.label ?? "Y"
        
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { point in
                    LineMark(
                        x: .value(xLabel, point.x),
                        y: .value(yLabel, point.y)
                    )
                    .foregroundStyle(s.color.color)
                    .interpolationMethod(.catmullRom)
                    
                    PointMark(
                        x: .value(xLabel, point.x),
                        y: .value(yLabel, point.y)
                    )
                    .foregroundStyle(s.color.color)
                    .symbolSize(30)
                }
            }
        }
        .chartXAxisLabel(spec.data?.xAxis?.label ?? "")
        .chartYAxisLabel(spec.data?.yAxis?.label ?? "")
        .chartYScale(domain: yDomain)
        .chartXAxis {
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
    
    /// Compute Y domain with some padding
    private var yDomain: ClosedRange<Double> {
        guard let series = spec.data?.series else { return 0...100 }
        
        let allY = series.flatMap { $0.points.map { $0.y } }
        guard !allY.isEmpty else { return 0...100 }
        
        let minY = spec.data?.yAxis?.min ?? allY.min()!
        let maxY = spec.data?.yAxis?.max ?? allY.max()!
        
        // Add 10% padding
        let padding = (maxY - minY) * 0.1
        return (minY - padding)...(maxY + padding)
    }
    
    @ViewBuilder
    private func legendView(series: [ChartSeries]) -> some View {
        HStack(spacing: Space.md) {
            ForEach(series) { s in
                HStack(spacing: Space.xs) {
                    Circle()
                        .fill(s.color.color)
                        .frame(width: 8, height: 8)
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
struct LineChartView_Previews: PreviewProvider {
    static var previews: some View {
        let spec = VisualizationSpec(
            chartType: .line,
            title: "Squat e1RM Trend",
            subtitle: "Last 8 weeks",
            data: ChartData(
                xAxis: ChartAxis(key: "week", label: "Week", type: "number"),
                yAxis: ChartAxis(key: "e1rm", label: "e1RM (kg)", unit: "kg"),
                series: [
                    ChartSeries(
                        name: "Squat",
                        color: .primary,
                        points: [
                            ChartDataPoint(x: 1, y: 120),
                            ChartDataPoint(x: 2, y: 122),
                            ChartDataPoint(x: 3, y: 125),
                            ChartDataPoint(x: 4, y: 123),
                            ChartDataPoint(x: 5, y: 127),
                            ChartDataPoint(x: 6, y: 130),
                            ChartDataPoint(x: 7, y: 132),
                            ChartDataPoint(x: 8, y: 135),
                        ]
                    )
                ]
            )
        )
        
        LineChartView(spec: spec)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
