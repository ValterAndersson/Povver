import SwiftUI

struct TrialScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onTrialStarted: () -> Void
    let onSkipped: () -> Void

    @State private var showFeatures = false

    private let features = [
        "Program generation",
        "Session analysis",
        "Progressive overload tracking",
        "900+ exercises"
    ]

    var body: some View {
        VStack(spacing: Space.zero) {
            Spacer()

            // Content area (center-bottom)
            VStack(spacing: Space.xl) {
                // Title
                Text("Powered by AI")
                    .textStyle(.appTitle)
                    .foregroundColor(.textPrimary)

                // Body text
                Text("Povver uses AI to build your programs and coach your sessions. A free trial starts today.")
                    .textStyle(.body)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // Feature list with checkmarks
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        HStack(spacing: Space.md) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accent)
                                .font(.system(size: 20))

                            Text(feature)
                                .textStyle(.body)
                                .foregroundColor(.textPrimary)
                        }
                        .opacity(showFeatures ? 1 : 0)
                        .animation(
                            .easeOut(duration: 0.3).delay(Double(index) * 0.1),
                            value: showFeatures
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Fine print
                Text("After your trial, logging stays free.")
                    .textStyle(.secondary)
                    .foregroundColor(.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.xl)

            Spacer()

            // CTA area
            VStack(spacing: Space.md) {
                // Start Free Trial button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    startTrial()
                } label: {
                    HStack(spacing: Space.sm) {
                        if vm.isLoadingTrial {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        } else {
                            Text("Start Free Trial")
                                .font(TypographyToken.button)
                                .foregroundColor(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .disabled(vm.isLoadingTrial)

                // Error message
                if let error = vm.trialError {
                    Text(error)
                        .textStyle(.secondary)
                        .foregroundColor(.destructive)
                        .multilineTextAlignment(.center)
                }

                // Fine print
                Text("Cancel anytime in App Store settings")
                    .textStyle(.micro)
                    .foregroundColor(.textTertiary)
                    .multilineTextAlignment(.center)

                // Skip option
                Button {
                    onSkipped()
                } label: {
                    Text("Continue with basic logging")
                        .textStyle(.secondary)
                        .foregroundColor(.textTertiary)
                }
                .disabled(vm.isLoadingTrial)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xl)
        }
        .onAppear {
            // Pre-load products
            Task {
                await SubscriptionService.shared.loadProducts()
            }

            // Stagger feature list
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showFeatures = true
            }
        }
    }

    private func startTrial() {
        Task {
            let success = await vm.startFreeTrial()
            if success {
                onTrialStarted()
            }
        }
    }
}

#if DEBUG
struct TrialScreen_Previews: PreviewProvider {
    static var previews: some View {
        TrialScreen(
            vm: OnboardingViewModel(),
            onTrialStarted: {},
            onSkipped: {}
        )
        .background(Color.bg)
    }
}
#endif
