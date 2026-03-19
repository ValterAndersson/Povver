import SwiftUI

public struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0
    public func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.5), Color.white.opacity(0)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .rotationEffect(.degrees(20))
                    .offset(x: phase)
                    .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 240
                }
            }
    }
}

public extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

public struct SkeletonBlock: View {
    private let height: CGFloat
    private let corner: CGFloat
    public init(height: CGFloat = 16, corner: CGFloat = CornerRadiusToken.radiusIcon) {
        self.height = height
        self.corner = corner
    }
    public var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.surfaceElevated)
            .frame(height: height)
            .shimmer()
    }
}

public struct Spinner: View {
    private let size: CGFloat
    private let color: Color
    public init(size: CGFloat = 24, color: Color = Color.accent) {
        self.size = size
        self.color = color
    }
    public var body: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: color))
            .frame(width: size, height: size)
    }
}

#if DEBUG
struct Spinner_Previews: PreviewProvider {
    static var previews: some View {
        Spinner()
            .padding(InsetsToken.screen)
    }
}
#endif


