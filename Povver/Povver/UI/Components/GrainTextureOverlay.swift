import SwiftUI

/// A 2% opacity noise texture overlay matching the landing page's grain effect.
/// Applied as `.overlay(GrainTextureOverlay())` on onboarding screens.
/// Rasterized with `.drawingGroup()` for performance. Does not intercept touches.
public struct GrainTextureOverlay: View {
    /// Opacity of the grain effect (0.02 = 2%)
    private let opacity: Double
    /// Density of noise dots per 100x100 point area
    private let density: Int

    public init(opacity: Double = 0.02, density: Int = 80) {
        self.opacity = opacity
        self.density = density
    }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Generate random noise dots across the canvas
                let dotCount = Int((size.width / 100) * (size.height / 100) * CGFloat(density))

                for _ in 0..<dotCount {
                    let x = CGFloat.random(in: 0...size.width)
                    let y = CGFloat.random(in: 0...size.height)
                    let dotSize = CGFloat.random(in: 0.3...0.8)

                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                        with: .color(.white)
                    )
                }
            }
            .opacity(opacity)
        }
        .drawingGroup() // Rasterize for performance
        .allowsHitTesting(false) // Do not intercept touches
    }
}

#if DEBUG
struct GrainTextureOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: "0A0E14") // Deep dark onboarding background

            Text("Onboarding Screen")
                .textStyle(.screenTitle)
                .foregroundColor(.white)
        }
        .overlay(GrainTextureOverlay())
        .ignoresSafeArea()
    }
}
#endif
