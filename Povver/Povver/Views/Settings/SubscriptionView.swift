import SwiftUI

/// Subscription management view for active and inactive users
/// Shows current plan status, benefits, and upgrade/manage options
struct SubscriptionView: View {
    @ObservedObject private var subscriptionService = SubscriptionService.shared
    @ObservedObject private var authService = AuthService.shared

    @State private var user: User?
    @State private var isLoading = true
    @State private var showingPaywall = false

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                // Status card
                statusCard

                // Benefits section
                if !subscriptionService.isPremium {
                    benefitsSection
                }

                // Manage section (for active subscribers)
                if subscriptionService.isPremium {
                    manageSection
                }

                // Restore purchases (for non-premium users)
                if !subscriptionService.isPremium {
                    restorePurchasesSection
                }

                Spacer(minLength: Space.xxl)
            }
            .padding(Space.lg)
        }
        .background(Color.bg)
        .navigationTitle("Subscription")
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: Space.md) {
            // Icon
            Image(systemName: subscriptionService.isPremium ? "star.fill" : "star")
                .font(.system(size: 48))
                .foregroundColor(subscriptionService.isPremium ? Color.accent : Color.textTertiary)

            // Title
            Text(subscriptionService.isPremium ? "Premium" : "Free Plan")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color.textPrimary)

            // Status description
            statusDescription

            // Upgrade button (for free users)
            if !subscriptionService.isPremium {
                upgradeButton
            }

            // Expiry info (for premium users)
            if subscriptionService.isPremium {
                expiryInfo
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
    }

    private var statusDescription: some View {
        Group {
            if let override = user?.subscriptionOverride, override == "premium" {
                Text("Admin override active")
                    .font(.system(size: 15))
                    .foregroundColor(Color.textSecondary)
            } else if subscriptionService.isPremium {
                if subscriptionService.subscriptionState.autoRenewEnabled {
                    Text("Active subscription")
                        .font(.system(size: 15))
                        .foregroundColor(Color.success)
                } else {
                    Text("Subscription expires soon")
                        .font(.system(size: 15))
                        .foregroundColor(Color.warning)
                }
            } else {
                Text("Upgrade to unlock unlimited AI coaching")
                    .font(.system(size: 15))
                    .foregroundColor(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var upgradeButton: some View {
        Button {
            showingPaywall = true
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                Text("Upgrade to Premium")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
            .background(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
        .padding(.top, Space.sm)
    }

    private var expiryInfo: some View {
        Group {
            if let expiresAt = subscriptionService.subscriptionState.expiresAt {
                VStack(spacing: 4) {
                    Text(subscriptionService.subscriptionState.autoRenewEnabled ? "Renews" : "Expires")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textTertiary)

                    Text(formatExpiryDate(expiresAt))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.textSecondary)
                }
                .padding(.top, Space.sm)
            }
        }
    }

    // MARK: - Benefits Section

    private var benefitsSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Premium Benefits")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color.textPrimary)

            VStack(alignment: .leading, spacing: Space.md) {
                benefitRow(icon: "message", title: "Unlimited AI Conversations")
                benefitRow(icon: "chart.xyaxis.line", title: "Advanced Analytics")
                benefitRow(icon: "bolt.fill", title: "Priority Processing")
                benefitRow(icon: "sparkles", title: "Early Access to Features")
            }
            .padding(Space.lg)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
    }

    private func benefitRow(icon: String, title: String) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color.accent)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Color.textPrimary)

            Spacer()

            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.success)
        }
    }

    // MARK: - Restore Purchases Section (for non-premium users)

    private var restorePurchasesSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Already Subscribed?")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color.textPrimary)

            Button {
                Task {
                    await subscriptionService.restorePurchases()
                }
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                        .foregroundColor(Color.textSecondary)
                        .frame(width: 24)

                    Text("Restore Purchases")
                        .font(.system(size: 15))
                        .foregroundColor(Color.textPrimary)

                    Spacer()

                    if subscriptionService.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding(Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
    }

    // MARK: - Manage Section

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Manage Subscription")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color.textPrimary)

            VStack(spacing: 0) {
                manageButton

                Divider().padding(.leading, 56)

                restoreButton
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
    }

    private var manageButton: some View {
        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
            HStack(spacing: Space.md) {
                Image(systemName: "gear")
                    .font(.system(size: 18))
                    .foregroundColor(Color.textSecondary)
                    .frame(width: 24)

                Text("Manage in App Store")
                    .font(.system(size: 15))
                    .foregroundColor(Color.textPrimary)

                Spacer()

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.textTertiary)
            }
            .padding(Space.md)
            .contentShape(Rectangle())
        }
    }

    private var restoreButton: some View {
        Button {
            Task {
                await subscriptionService.restorePurchases()
            }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18))
                    .foregroundColor(Color.textSecondary)
                    .frame(width: 24)

                Text("Restore Purchases")
                    .font(.system(size: 15))
                    .foregroundColor(Color.textPrimary)

                Spacer()

                if subscriptionService.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Helpers

    private func formatExpiryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func loadData() async {
        isLoading = true

        // Load user to check for admin override
        if let userId = authService.currentUser?.uid {
            do {
                user = try await UserRepository.shared.getUser(userId: userId)
            } catch {
                AppLogger.shared.error(.app, "Failed to load user", error)
            }
        }

        // Check subscription status
        await subscriptionService.checkEntitlements()

        isLoading = false
    }
}

#if DEBUG
struct SubscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SubscriptionView()
        }
    }
}
#endif
