import SwiftUI

/// Brief accent-tint highlight when a view appears for the first time.
public struct NewItemHighlight: ViewModifier {
    @State private var show = false
    public func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                    .fill(Color.accentMuted)
                    .opacity(show ? 0.35 : 0)
            )
            .onAppear {
                guard !show else { return }
                withAnimation(.easeOut(duration: MotionToken.medium)) { show = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeIn(duration: MotionToken.medium)) { show = false }
                }
            }
    }
}

public extension View {
    func newItemHighlight() -> some View { modifier(NewItemHighlight()) }
}


