import SwiftUI

/// Staggered fade + slide entrance animation.
/// Usage: `.staggeredEntrance(index: 0, active: hasAppeared)`
struct StaggeredEntrance: ViewModifier {
    let index: Int
    let active: Bool
    let offset: CGFloat
    let delay: Double

    init(index: Int, active: Bool, offset: CGFloat = 8, delay: Double = 0.08) {
        self.index = index
        self.active = active
        self.offset = offset
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active ? 0 : offset)
            .animation(
                MotionToken.gentle.delay(min(Double(index) * delay, 0.8)),
                value: active
            )
    }
}

extension View {
    /// Apply staggered entrance animation. Set `active` to true on appear.
    func staggeredEntrance(index: Int, active: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, active: active))
    }
}
