import SwiftUI

/// Compact horizontal week schedule indicator showing routine progress.
/// Filled cells = completed this week, outlined = upcoming, accent outline = today's session.
struct MiniWeekStrip: View {
    let totalDays: Int
    let completedThisWeek: Int
    let currentDayIndex: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<totalDays, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index < completedThisWeek ? Color.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(strokeColor(for: index), lineWidth: index == currentDayIndex && index >= completedThisWeek ? 1.5 : StrokeWidthToken.hairline)
                    )
                    .frame(height: 6)
            }
        }
    }

    private func strokeColor(for index: Int) -> Color {
        if index < completedThisWeek { return Color.clear }
        if index == currentDayIndex { return Color.accent }
        return Color.separatorLine
    }
}
