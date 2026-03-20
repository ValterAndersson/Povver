/**
 * FloatingWorkoutBanner.swift
 *
 * Compact floating banner shown on non-Train tabs when a workout is active.
 * Tapping returns the user to the Train tab. Pure presentation component —
 * timer state is managed by the parent.
 */

import SwiftUI

struct FloatingWorkoutBanner: View {
    let workoutName: String
    let currentExerciseName: String?
    let elapsedTime: TimeInterval
    let onTap: () -> Void

    @State private var breatheScale: CGFloat = 1.0

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.sm) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 14, weight: .medium))

                Text(currentExerciseName ?? workoutName)
                    .textStyle(.secondary)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer()

                Text(formatDuration(elapsedTime))
                    .textStyle(.secondary)
                    .fontWeight(.medium)
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.textInverse)
            .padding(.horizontal, Space.md)
            .padding(.vertical, 12)
            .background(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .shadowStyle(ShadowsToken.level2)
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(breatheScale)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                breatheScale = 1.02
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
