import SwiftUI

/// Persistent radial emerald glow layer for onboarding screens.
/// Provides atmospheric depth with emerald (#22C59A) radial gradient and optional breathing animation.
/// Applied as `.background(OnboardingGlowLayer(...))` behind content.
public struct OnboardingGlowLayer: View {
    /// Opacity of the glow (0.12 default, 0.18 for trial screen, 0.25 for generation completion)
    private let intensity: Double
    /// Y offset to shift glow position per screen
    private let verticalOffset: CGFloat
    /// Whether to animate a slow scale pulse (1.0 → 1.05, 8s loop)
    private let breathing: Bool

    @State private var breathingScale: CGFloat = 1.0

    public init(
        intensity: Double = 0.12,
        verticalOffset: CGFloat = 0,
        breathing: Bool = true
    ) {
        self.intensity = intensity
        self.verticalOffset = verticalOffset
        self.breathing = breathing
    }

    public var body: some View {
        GeometryReader { geometry in
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(hex: "22C59A").opacity(intensity),
                    Color.clear
                ]),
                center: .center,
                startRadius: 0,
                endRadius: geometry.size.width * 0.7
            )
            .blur(radius: 60)
            .scaleEffect(breathingScale)
            .offset(y: verticalOffset)
            .onAppear {
                guard breathing else { return }
                withAnimation(
                    .easeInOut(duration: 8)
                    .repeatForever(autoreverses: true)
                ) {
                    breathingScale = 1.05
                }
            }
        }
        .allowsHitTesting(false) // Do not intercept touches
    }
}

#if DEBUG
struct OnboardingGlowLayer_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.xxl) {
            // Default intensity preview
            ZStack {
                Color(hex: "0A0E14") // Deep dark onboarding background

                OnboardingGlowLayer()

                VStack {
                    Text("Default Glow")
                        .textStyle(.screenTitle)
                        .foregroundColor(.white)
                    Text("intensity: 0.12, breathing: true")
                        .textStyle(.secondary)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 300)

            // Trial screen intensity preview
            ZStack {
                Color(hex: "0A0E14")

                OnboardingGlowLayer(intensity: 0.18, verticalOffset: -50)

                VStack {
                    Text("Trial Screen Glow")
                        .textStyle(.screenTitle)
                        .foregroundColor(.white)
                    Text("intensity: 0.18, offset: -50")
                        .textStyle(.secondary)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 300)

            // Generation completion intensity preview
            ZStack {
                Color(hex: "0A0E14")

                OnboardingGlowLayer(intensity: 0.25, breathing: false)

                VStack {
                    Text("Completion Glow")
                        .textStyle(.screenTitle)
                        .foregroundColor(.white)
                    Text("intensity: 0.25, breathing: false")
                        .textStyle(.secondary)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 300)
        }
        .background(Color(hex: "0A0E14"))
        .ignoresSafeArea()
    }
}
#endif
