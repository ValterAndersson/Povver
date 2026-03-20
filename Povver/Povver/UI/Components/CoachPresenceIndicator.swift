import SwiftUI

/// Breathing emerald glow component representing the AI coach's presence.
/// Used in the Coach tab hero and workout header.
/// Features a sparkles icon with animated breathing glow and ring.
struct CoachPresenceIndicator: View {
    var size: CGFloat = 40
    var isThinking: Bool = false

    @State private var breathePhase: CGFloat = 0

    private var cycleDuration: Double { isThinking ? 2.0 : 8.0 }
    private var glowIntensity: Double { isThinking ? 0.2 : 0.12 }

    var body: some View {
        ZStack {
            // Breathing glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.accent.opacity(glowIntensity), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.8
                    )
                )
                .frame(width: size * 1.6, height: size * 1.6)
                .scaleEffect(1.0 + breathePhase * 0.05)

            // Icon container
            Circle()
                .fill(Color.accent.opacity(0.1))
                .frame(width: size, height: size)

            // Sparkles icon
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundColor(Color.accent)

            // Breathing ring
            Circle()
                .stroke(Color.accent.opacity(0.3 + breathePhase * 0.1), lineWidth: 1.5)
                .frame(width: size + 4, height: size + 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: cycleDuration).repeatForever(autoreverses: true)) {
                breathePhase = 1.0
            }
        }
        .onChange(of: isThinking) { _, newValue in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                breathePhase = 0
            }
            withAnimation(.easeInOut(duration: newValue ? 2.0 : 8.0).repeatForever(autoreverses: true)) {
                breathePhase = 1.0
            }
        }
    }
}

#if DEBUG
struct CoachPresenceIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.xxl) {
            // Default state
            ZStack {
                Color(hex: "0A0E14")

                VStack(spacing: Space.lg) {
                    CoachPresenceIndicator()
                    Text("Default State")
                        .textStyle(.secondary)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 200)

            // Thinking state
            ZStack {
                Color(hex: "0A0E14")

                VStack(spacing: Space.lg) {
                    CoachPresenceIndicator(isThinking: true)
                    Text("Thinking State")
                        .textStyle(.secondary)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 200)

            // Large size
            ZStack {
                Color(hex: "0A0E14")

                VStack(spacing: Space.lg) {
                    CoachPresenceIndicator(size: 60)
                    Text("Large Size (60pt)")
                        .textStyle(.secondary)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 200)
        }
        .background(Color(hex: "0A0E14"))
        .ignoresSafeArea()
    }
}
#endif
