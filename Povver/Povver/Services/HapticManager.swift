import UIKit

/// Centralized haptic feedback — avoids scattered UIImpactFeedbackGenerator calls.
enum HapticManager {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()

    static func setCompleted() {
        lightImpact.impactOccurred()
    }

    static func prDetected() {
        notification.notificationOccurred(.success)
    }

    static func workoutCompleted() {
        notification.notificationOccurred(.success)
    }

    static func milestoneUnlocked() {
        notification.notificationOccurred(.success)
    }

    static func destructiveAction() {
        notification.notificationOccurred(.warning)
    }

    static func primaryAction() {
        lightImpact.impactOccurred()
    }
}
