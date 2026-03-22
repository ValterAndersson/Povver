import SwiftUI
import Charts

/// Bar chart showing workouts per week over a rolling window.
/// Used in History tab; designed for reuse in dashboards.
struct WeeklyFrequencyChart: View {
    let workouts: [Workout]
    var weekCount: Int = 8

    var body: some View {
        let data = Self.buildWeeklyData(from: workouts, weekCount: weekCount)
        let total = data.map(\.count).reduce(0, +)
        let average = Double(total) / Double(data.count)
        let maxCount = data.map(\.count).max() ?? 1

        ChartCard(title: "Weekly frequency", metric: "avg \(String(format: "%.1f", average))/wk") {
            Chart(data) { bucket in
                BarMark(
                    x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                    y: .value("Workouts", bucket.count)
                )
                .foregroundStyle(bucket.isCurrent ? Color.accent : Color.chartInactive)
                .cornerRadius(CornerRadiusToken.radiusIcon / 2)
                .annotation(position: .top, spacing: Space.xs) {
                    if bucket.count > 0 {
                        Text("\(bucket.count)")
                            .font(TypographyToken.micro)
                            .fontWeight(.semibold)
                            .foregroundStyle(bucket.isCurrent ? Color.textPrimary : Color.textTertiary)
                    }
                }
            }
            .chartYScale(domain: 0 ... max(maxCount + 1, 2))
            .chartStandardYAxis()
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let day = Calendar.current.component(.day, from: date)
                            // Show month name when day is <= 7 (first week of a new month)
                            if day <= 7 {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                                    .font(TypographyToken.micro)
                                    .foregroundStyle(Color.textSecondary)
                            } else {
                                Text("\(day)")
                                    .font(TypographyToken.micro)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Data

    private static func buildWeeklyData(from workouts: [Workout], weekCount: Int) -> [WeekBucket] {
        let calendar = Calendar.current
        let today = Date()

        // Monday of current week (ISO: Mon=start)
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (currentWeekday + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: calendar.startOfDay(for: today))!

        var buckets: [WeekBucket] = []
        for i in (0..<weekCount).reversed() {
            let monday = calendar.date(byAdding: .day, value: -7 * i, to: currentMonday)!
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: monday)!
            let count = workouts.filter { $0.endTime >= monday && $0.endTime < weekEnd }.count
            buckets.append(WeekBucket(weekStart: monday, count: count, isCurrent: i == 0))
        }
        return buckets
    }
}

/// A single week bucket for frequency charts.
private struct WeekBucket: Identifiable {
    let weekStart: Date
    let count: Int
    let isCurrent: Bool
    var id: Date { weekStart }
}
