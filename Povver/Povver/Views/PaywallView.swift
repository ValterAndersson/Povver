import SwiftUI
import StoreKit

/// Full-screen paywall sheet for presenting subscription options
/// Shown when user attempts premium-only actions without an active subscription
struct PaywallView: View {
    @ObservedObject private var subscriptionService = SubscriptionService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var paywallShownAt: Date?

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header

                ScrollView {
                    VStack(spacing: Space.xl) {
                        // Hero section
                        heroSection

                        // Features
                        featuresSection

                        // Products
                        productsSection

                        // Restore
                        restoreButton

                        // Subscription disclosure (App Store Guideline 3.1.2)
                        subscriptionDisclosure
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.xxl)
                }

                // Close button overlay
                VStack {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    Spacer()
                }
            }
        }
        .task {
            paywallShownAt = Date()
            await subscriptionService.loadProducts()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(Color.accent)
                .padding(.top, Space.xl)

            Text("Upgrade to Premium")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, Space.lg)
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        Text("Unlock unlimited AI coaching and advanced analytics")
            .font(.system(size: 17))
            .foregroundColor(Color.textSecondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            featureRow(icon: "message", title: "Unlimited AI Conversations", description: "Get personalized coaching anytime")
            featureRow(icon: "chart.xyaxis.line", title: "Advanced Analytics", description: "Deep insights into your progress")
            featureRow(icon: "bolt.fill", title: "Priority Processing", description: "Faster responses and planning")
            featureRow(icon: "sparkles", title: "Premium Features", description: "Early access to new capabilities")
        }
        .padding(Space.lg)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Color.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.textPrimary)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(Color.textSecondary)
            }

            Spacer()
        }
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(spacing: Space.md) {
            if subscriptionService.isLoading {
                ProgressView()
                    .padding(Space.xl)
            } else if let error = subscriptionService.error {
                errorView(error: error)
            } else if subscriptionService.availableProducts.isEmpty {
                Text("No subscription options available")
                    .font(.system(size: 15))
                    .foregroundColor(Color.textSecondary)
                    .padding(Space.xl)
            } else {
                ForEach(subscriptionService.availableProducts, id: \.id) { product in
                    productRow(product: product)
                }
            }
        }
    }

    private func productRow(product: Product) -> some View {
        Button {
            Task {
                await subscriptionService.purchase(product)
                if subscriptionService.isPremium {
                    dismiss()
                }
            }
        } label: {
            VStack(spacing: Space.md) {
                // Dynamic CTA: "Start Free Trial" if eligible, else product name
                if subscriptionService.isTrialEligible {
                    Text("Start 7-Day Free Trial")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.md)
                        .background(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))

                    Text("Then \(product.displayPrice)/month")
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                } else {
                    Text("Subscribe")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.md)
                        .background(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))

                    Text("\(product.displayPrice)/month")
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                }
            }
            .padding(Space.lg)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                    .strokeBorder(Color.accentStroke, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func errorView(error: SubscriptionError) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(Color.warning)

            Text(error.localizedDescription)
                .font(.system(size: 15))
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
    }

    // MARK: - Restore Button

    private var restoreButton: some View {
        Button {
            Task {
                await subscriptionService.restorePurchases()
                if subscriptionService.isPremium {
                    dismiss()
                }
            }
        } label: {
            Text("Restore Purchases")
                .font(.system(size: 15))
                .foregroundColor(Color.textSecondary)
        }
        .padding(.top, Space.lg)
    }

    // MARK: - Subscription Disclosure

    private var subscriptionDisclosure: some View {
        VStack(spacing: Space.sm) {
            Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. You can manage or cancel your subscription in your device's Settings > Subscriptions.")
                .font(.system(size: 11))
                .foregroundColor(Color.textTertiary)
                .multilineTextAlignment(.center)

            Button {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Manage Subscriptions")
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary)
                    .underline()
            }
        }
        .padding(.top, Space.sm)
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button {
            let timeOnScreen = Int(Date().timeIntervalSince(paywallShownAt ?? Date()))
            AnalyticsService.shared.paywallDismissed(trigger: "unknown", timeOnScreenSec: timeOnScreen)
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(Color.textTertiary)
                .padding(Space.lg)
        }
    }
}

#if DEBUG
struct PaywallView_Previews: PreviewProvider {
    static var previews: some View {
        PaywallView()
    }
}
#endif
