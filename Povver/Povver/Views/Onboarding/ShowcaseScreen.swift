import SwiftUI

struct ShowcaseScreen: View {
    @ObservedObject var vm: OnboardingViewModel
    let onTrialStarted: () -> Void

    @State private var showFeatures = false

    private let features: [(icon: String, title: String, description: String)] = [
        ("brain.head.profile", "AI Coach", "Chat, plan, and get personalized advice"),
        ("figure.strengthtraining.traditional", "Smart Programs", "Routines that adapt to your progress"),
        ("chart.bar.fill", "Workout Tracking", "Log sets, track PRs, see trends"),
        ("link", "Open Platform", "Connect with other AI tools via MCP"),
    ]

    var body: some View {
        VStack(spacing: Space.zero) {
            Spacer()

            VStack(spacing: Space.xl) {
                Text("Everything you need")
                    .textStyle(.appTitle)
                    .foregroundColor(.textPrimary)

                // Feature rows
                VStack(alignment: .leading, spacing: Space.lg) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        HStack(alignment: .top, spacing: Space.md) {
                            Image(systemName: feature.icon)
                                .foregroundColor(.accent)
                                .font(.system(size: 20))
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .textStyle(.bodyStrong)
                                    .foregroundColor(.textPrimary)

                                Text(feature.description)
                                    .textStyle(.secondary)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        .opacity(showFeatures ? 1 : 0)
                        .animation(
                            .easeOut(duration: 0.3).delay(Double(index) * 0.1),
                            value: showFeatures
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Space.xl)

            Spacer()

            // CTA area
            VStack(spacing: Space.md) {
                // Subscription info
                if let product = SubscriptionService.shared.availableProducts.first {
                    let periodLabel: String = {
                        guard let period = product.subscription?.subscriptionPeriod else { return "month" }
                        switch period.unit {
                        case .day: return period.value == 7 ? "week" : "\(period.value) days"
                        case .week: return period.value == 1 ? "week" : "\(period.value) weeks"
                        case .month: return period.value == 1 ? "month" : "\(period.value) months"
                        case .year: return period.value == 1 ? "year" : "\(period.value) years"
                        @unknown default: return "month"
                        }
                    }()
                    Text("\(product.displayPrice) / \(periodLabel) · Cancel anytime")
                        .textStyle(.secondary)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }

                // Start Free Trial
                Button {
                    HapticManager.modeToggle()
                    startTrial()
                } label: {
                    HStack(spacing: Space.sm) {
                        if vm.isLoadingTrial {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        } else {
                            Text("Start Free Trial")
                                .font(TypographyToken.bodyStrong)
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

                // Cancel anytime
                Text("Cancel anytime in App Store settings")
                    .textStyle(.micro)
                    .foregroundColor(.textTertiary)
                    .multilineTextAlignment(.center)

                // Restore purchases
                Button {
                    restorePurchases()
                } label: {
                    Text("Restore purchases")
                        .textStyle(.micro)
                        .foregroundColor(.textTertiary)
                }
                .disabled(vm.isLoadingTrial)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xl)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showFeatures = true
            }
        }
    }

    private func startTrial() {
        Task {
            let success = await vm.startFreeTrial()
            if success {
                // Auto-save the routine after purchase
                let _ = await vm.autoSaveRoutine()
                onTrialStarted()
            }
        }
    }

    private func restorePurchases() {
        Task {
            vm.isLoadingTrial = true
            vm.trialError = nil
            await SubscriptionService.shared.restorePurchases()
            if SubscriptionService.shared.isPremium {
                let _ = await vm.autoSaveRoutine()
                onTrialStarted()
            } else {
                vm.trialError = "No active subscription found"
            }
            vm.isLoadingTrial = false
        }
    }
}

#if DEBUG
struct ShowcaseScreen_Previews: PreviewProvider {
    static var previews: some View {
        ShowcaseScreen(
            vm: OnboardingViewModel(),
            onTrialStarted: {}
        )
        .background(Color.bg)
    }
}
#endif
