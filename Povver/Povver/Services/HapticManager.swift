import UIKit

/// Centralized haptic feedback — avoids scattered UIImpactFeedbackGenerator calls.
enum HapticManager {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        notification.prepare()
    }

    static func setCompleted() {
        lightImpact.prepare()
        lightImpact.impactOccurred()
    }

    /// Light tap for value adjustments (stepper +/-, RIR pill selection)
    static func selectionTick() {
        lightImpact.prepare()
        lightImpact.impactOccurred()
    }

    /// Medium tap for toggling modes or bulk actions (toggle all done, reorder)
    static func modeToggle() {
        mediumImpact.prepare()
        mediumImpact.impactOccurred()
    }

    /// Success notification for confirming a swipe-to-delete or similar action
    static func confirmAction() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func prDetected() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func workoutCompleted() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func milestoneUnlocked() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func destructiveAction() {
        notification.prepare()
        notification.notificationOccurred(.warning)
    }

    static func primaryAction() {
        lightImpact.prepare()
        lightImpact.impactOccurred()
    }
}
