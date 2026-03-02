import SwiftUI

struct WelcomeScreen: View {
    let onGetStarted: () -> Void
    let onSignIn: () -> Void

    @State private var showWordmark = false
    @State private var showSubtitle = false
    @State private var showCTA = false

    var body: some View {
        VStack(spacing: Space.zero) {
            Spacer()

            // Content group (centered)
            VStack(spacing: Space.md) {
                // "POVVER" wordmark
                Text("POVVER")
                    .font(.system(size: 16, weight: .bold))
                    .tracking(2.24)
                    .foregroundColor(.textPrimary)
                    .opacity(showWordmark ? 1 : 0)
                    .offset(y: showWordmark ? 0 : 20)

                // "AI STRENGTH COACH" subtitle
                Text("AI STRENGTH COACH")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.32)
                    .foregroundColor(.accent)
                    .opacity(showSubtitle ? 1 : 0)
            }

            Spacer()

            // CTA group (bottom, padded)
            VStack(spacing: Space.lg) {
                PovverButton("Get Started", style: .primary) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onGetStarted()
                }

                Button {
                    onSignIn()
                } label: {
                    (Text("Already have an account? ")
                        .foregroundColor(.textTertiary) +
                     Text("Sign in")
                        .fontWeight(.semibold)
                        .foregroundColor(.accent))
                        .textStyle(.secondary)
                }
            }
            .opacity(showCTA ? 1 : 0)
            .offset(y: showCTA ? 0 : 20)
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xl)
        }
        .onAppear {
            // Staggered entrance animation
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(0.3)) {
                showWordmark = true
            }
            withAnimation(.easeOut(duration: 0.3).delay(0.6)) {
                showSubtitle = true
            }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(0.8)) {
                showCTA = true
            }
        }
    }
}

#if DEBUG
struct WelcomeScreen_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeScreen(onGetStarted: {}, onSignIn: {})
            .background(Color.bg)
    }
}
#endif
