import SwiftUI

/// Povver's signature visual — 12-week training consistency grid.
/// Emerald fills for completed sessions (earned color at scale).
struct TrainingConsistencyMap: View {
    let weeks: [WeekWorkoutCount]
    let routineFrequency: Int // Sessions per week (e.g., 4 for a 4-day program)
    var animateLatest: Bool = false

    @State private var latestFilled = false

    private let cellSize: CGFloat = 8
    private let cellSpacing: CGFloat = 3

    var body: some View {
        HStack(spacing: cellSpacing) {
            ForEach(Array(paddedWeeks.enumerated()), id: \.0) { weekIndex, week in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<max(1, routineFrequency), id: \.self) { dayIndex in
                        let isCompleted = dayIndex < week.completedCount
                        let isLatestCell = animateLatest && weekIndex == paddedWeeks.count - 1 && dayIndex == week.completedCount - 1

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellFill(completed: isCompleted && (!isLatestCell || latestFilled)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(cellStroke(completed: isCompleted), lineWidth: isCompleted ? 0 : 0.5)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .task {
            if animateLatest {
                try? await Task.sleep(for: .seconds(0.5))
                withAnimation(MotionToken.bouncy) {
                    latestFilled = true
                }
                HapticManager.setCompleted()
            }
        }
    }

    private var paddedWeeks: [WeekWorkoutCount] {
        let target = 12
        if weeks.count >= target { return Array(weeks.suffix(target)) }
        let padding = (0..<(target - weeks.count)).map { i in
            WeekWorkoutCount(weekId: "pad_\(i)", scheduledCount: routineFrequency, completedCount: 0)
        }
        return padding + weeks
    }

    private func cellFill(completed: Bool) -> Color {
        completed ? Color.accent : Color.clear
    }

    private func cellStroke(completed: Bool) -> Color {
        completed ? Color.clear : Color.separatorLine
    }
}
