import SwiftUI

/// Ranked table for movers/laggards (sorted lists with trend indicators)
public struct RankedTableView: View {
    private let spec: VisualizationSpec
    
    public init(spec: VisualizationSpec) {
        self.spec = spec
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rows = spec.data?.rows, !rows.isEmpty {
                tableContent(rows: rows)
            } else {
                emptyState
            }
        }
    }
    
    @ViewBuilder
    private func tableContent(rows: [ChartTableRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                tableRow(row)
                
                if row.id != rows.last?.id {
                    Divider()
                        .background(Color.separatorLine)
                }
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
    
    @ViewBuilder
    private func tableRow(_ row: ChartTableRow) -> some View {
        HStack(spacing: Space.sm) {
            // Rank badge
            rankBadge(rank: row.rank)
            
            // Label and sublabel
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(TypographyToken.body)
                    .foregroundStyle(Color.textPrimary)
                
                if let sublabel = row.sublabel {
                    Text(sublabel)
                        .font(TypographyToken.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
            
            Spacer()
            
            // Value and delta
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(row.value)
                        .font(TypographyToken.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.textPrimary)
                    
                    if let unit = spec.data?.yAxis?.unit {
                        Text(unit)
                            .font(TypographyToken.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                
                if let delta = row.delta {
                    deltaLabel(delta: delta, trend: row.trend)
                }
            }
            
            // Trend indicator
            if let trend = row.trend {
                trendIndicator(trend: trend)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }
    
    @ViewBuilder
    private func rankBadge(rank: Int) -> some View {
        Text("\(rank)")
            .font(TypographyToken.caption)
            .fontWeight(.bold)
            .foregroundStyle(rank <= 3 ? Color.textInverse : Color.textSecondary)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(rankColor(rank: rank))
            )
    }
    
    private func rankColor(rank: Int) -> Color {
        switch rank {
        case 1: return Color.accent
        case 2: return Color.accent
        case 3: return Color.textTertiary
        default: return Color.separatorLine
        }
    }
    
    @ViewBuilder
    private func deltaLabel(delta: Double, trend: TrendDirection?) -> some View {
        let isPositive = delta >= 0
        let color = trend == .up ? Color.success : 
                   (trend == .down ? Color.destructive : Color.textTertiary)
        
        HStack(spacing: 2) {
            Text(isPositive ? "+" : "")
                .font(TypographyToken.caption)
            Text(String(format: "%.1f", delta))
                .font(TypographyToken.caption)
        }
        .foregroundStyle(color)
    }
    
    @ViewBuilder
    private func trendIndicator(trend: TrendDirection) -> some View {
        let iconAndColor: (icon: String, color: Color) = {
            switch trend {
            case .up:
                return ("arrow.up.right", Color.success)
            case .down:
                return ("arrow.down.right", Color.destructive)
            case .flat:
                return ("arrow.right", Color.textTertiary)
            }
        }()
        
        Image(systemName: iconAndColor.icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(iconAndColor.color)
            .frame(width: 20)
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
        .frame(minHeight: 120)
    }
}

// MARK: - Preview

struct RankedTableView_Previews: PreviewProvider {
    static var previews: some View {
        let spec = VisualizationSpec(
            chartType: .table,
            title: "Top Movers (e1RM)",
            subtitle: "Last 8 weeks",
            data: ChartData(
                yAxis: ChartAxis(unit: "kg"),
                rows: [
                    ChartTableRow(rank: 1, label: "Squat", value: "140", numericValue: 140, delta: 12.5, trend: .up, sublabel: "+9.8%"),
                    ChartTableRow(rank: 2, label: "Bench Press", value: "95", numericValue: 95, delta: 7.0, trend: .up, sublabel: "+7.9%"),
                    ChartTableRow(rank: 3, label: "Deadlift", value: "180", numericValue: 180, delta: 5.0, trend: .up, sublabel: "+2.9%"),
                    ChartTableRow(rank: 4, label: "OHP", value: "55", numericValue: 55, delta: 0.0, trend: .flat, sublabel: "0%"),
                    ChartTableRow(rank: 5, label: "Rows", value: "70", numericValue: 70, delta: -2.5, trend: .down, sublabel: "-3.4%"),
                ]
            )
        )
        
        RankedTableView(spec: spec)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
