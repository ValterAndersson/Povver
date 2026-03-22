import UIKit

/// Centralized haptic feedback — avoids scattered UIImpactFeedbackGenerator calls.
enum HapticManager {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

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

    // MARK: - Rapid Succession Guard

    /// Tracks last fire time per category to suppress rapid identical haptics.
    /// @MainActor ensures thread safety — all haptic calls originate from main thread.
    @MainActor private static var lastFireTime: [String: Date] = [:]
    private static let suppressionWindow: TimeInterval = 0.2 // 200ms

    /// Fire a haptic only if the same category hasn't fired within the suppression window.
    @MainActor static func guardedFire(category: String, action: () -> Void) {
        let now = Date()
        if let last = lastFireTime[category], now.timeIntervalSince(last) < suppressionWindow {
            return // Suppress
        }
        lastFireTime[category] = now
        action()
    }

    /// Reset suppression state (e.g., when scroll ends or context changes)
    @MainActor static func resetSuppression() {
        lastFireTime.removeAll()
    }

    // MARK: - Scroll Suppression

    /// Set to true while user is actively scrolling at high velocity.
    @MainActor static var isScrollingSuppressed = false

    /// Check if haptics should be suppressed due to active scrolling.
    @MainActor static var shouldSuppressForScroll: Bool { isScrollingSuppressed }

    // MARK: - Button Haptics

    /// Haptic for button taps. Uses guarded fire to prevent rapid succession.
    @MainActor static func buttonTap(style: ButtonHapticStyle) {
        guard !shouldSuppressForScroll else { return }
        switch style {
        case .light:
            guardedFire(category: "button") {
                lightImpact.prepare()
                lightImpact.impactOccurred()
            }
        case .medium:
            guardedFire(category: "button") {
                mediumImpact.prepare()
                mediumImpact.impactOccurred()
            }
        case .none:
            break
        }
    }

    /// Selection haptic for toggles, segments, chips. Uses guarded fire.
    @MainActor static func selectionChanged() {
        guard !shouldSuppressForScroll else { return }
        guardedFire(category: "selection") {
            selection.prepare()
            selection.selectionChanged()
        }
    }
}
