import SwiftUI

/// More Tab — settings hub replacing the old ProfileView.
/// Provides navigation to profile editing, activity, preferences, security, and subscription.
/// recommendationsVM received as @ObservedObject — owned by MainTabsView for early listener start.
struct MoreView: View {
    @ObservedObject var recommendationsVM: RecommendationsViewModel
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var subscriptionService = SubscriptionService.shared

    @State private var user: User?
    @State private var showingLogoutConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Profile card
                profileCard

                // Activity (premium only)
                if subscriptionService.isPremium {
                    NavigationLink(destination: ActivityView(viewModel: recommendationsVM)) {
                        ProfileRowLinkContent(
                            icon: "bolt.fill",
                            title: "Activity",
                            subtitle: "Recommendations & auto-pilot",
                            badgeCount: recommendationsVM.pendingCount
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                    .padding(.horizontal, Space.lg)
                }

                // Settings
                sectionHeader("Settings")
                settingsSection

                // More
                moreSection

                // Error banner
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .padding(.horizontal, Space.lg)
                }

                // Sign Out
                logoutButton

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadUser()
        }
        .confirmationDialog("Sign Out", isPresented: $showingLogoutConfirmation) {
            Button("Sign Out", role: .destructive) {
                logout()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        NavigationLink(destination: ProfileEditView()) {
            HStack(spacing: Space.md) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color.accent.opacity(0.15))
                        .frame(width: 56, height: 56)

                    Text(initials)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.textPrimary)

                    if let email = visibleEmail {
                        Text(email)
                            .font(.system(size: 13))
                            .foregroundColor(Color.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.textTertiary)
            }
            .padding(Space.lg)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(spacing: 0) {
            NavigationLink(destination: PreferencesView()) {
                ProfileRowLinkContent(
                    icon: "gearshape",
                    title: "Preferences",
                    subtitle: "Timezone, week start"
                )
            }
            .buttonStyle(PlainButtonStyle())

            Divider().padding(.leading, 56)

            NavigationLink(destination: SecurityView()) {
                ProfileRowLinkContent(
                    icon: "lock.shield",
                    title: "Security",
                    subtitle: "Passwords & linked accounts"
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .padding(.horizontal, Space.lg)
    }

    // MARK: - More Section

    private var moreSection: some View {
        VStack(spacing: 0) {
            NavigationLink(destination: SubscriptionView()) {
                ProfileRowLinkContent(
                    icon: "creditcard",
                    title: "Subscription",
                    subtitle: "Manage your plan"
                )
            }
            .buttonStyle(PlainButtonStyle())

            Divider().padding(.leading, 56)

            NavigationLink(destination: ConnectedAppsView()) {
                ProfileRowLinkContent(
                    icon: "cable.connector",
                    title: "Connected Apps",
                    subtitle: "API keys for AI assistants"
                )
            }
            .buttonStyle(PlainButtonStyle())

            Divider().padding(.leading, 56)

            NavigationLink(destination: DevicesPlaceholderView()) {
                ProfileRowLinkContent(
                    icon: "applewatch",
                    title: "Devices",
                    subtitle: "Connected devices"
                )
            }
            .buttonStyle(PlainButtonStyle())

            Divider().padding(.leading, 56)

            NavigationLink(destination: MemoriesPlaceholderView()) {
                ProfileRowLinkContent(
                    icon: "brain",
                    title: "Memories",
                    subtitle: "What Coach knows about you"
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Logout

    private var logoutButton: some View {
        Button {
            showingLogoutConfirmation = true
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 18))
                    .foregroundColor(Color.destructive)

                Text("Sign Out")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color.destructive)

                Spacer()
            }
            .padding(Space.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color.textSecondary)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }

    private var displayName: String {
        if let name = user?.name, !name.isEmpty {
            return name
        }
        if let email = visibleEmail {
            return email.components(separatedBy: "@").first ?? email
        }
        return "User"
    }

    private var visibleEmail: String? {
        let email = user?.email ?? authService.currentUser?.email
        guard let email = email, !email.hasSuffix("@privaterelay.appleid.com") else { return nil }
        return email
    }

    private var initials: String {
        let name = displayName
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func loadUser() async {
        guard let userId = authService.currentUser?.uid else { return }
        do {
            user = try await UserRepository.shared.getUser(userId: userId)
        } catch {
            print("[MoreView] Failed to load user: \(error)")
        }
    }

    private func logout() {
        do {
            try authService.signOut()
        } catch {
            errorMessage = "Sign out failed. Please try again."
        }
    }
}

// MARK: - Placeholder Views

struct DevicesPlaceholderView: View {
    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "applewatch")
                .font(.system(size: 48))
                .foregroundColor(Color.textTertiary)

            Text("Connected Devices")
                .font(.system(size: 20, weight: .semibold))

            Text("Link your Apple Watch or other devices")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
        .navigationTitle("Devices")
    }
}

struct MemoriesPlaceholderView: View {
    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundColor(Color.textTertiary)

            Text("Memories")
                .font(.system(size: 20, weight: .semibold))

            Text("What Coach has learned about your training")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
        .navigationTitle("Memories")
    }
}
