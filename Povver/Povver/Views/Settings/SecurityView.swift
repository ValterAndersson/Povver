import SwiftUI

/// Security screen — linked accounts, password, and account deletion.
/// Accessed via NavigationLink from MoreView.
struct SecurityView: View {
    @ObservedObject private var authService = AuthService.shared

    @State private var linkedProviders: [AuthProvider] = []
    @State private var showingPasswordChange = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                sectionHeader("Account Security")

                VStack(spacing: 0) {
                    NavigationLink(destination: LinkedAccountsView()) {
                        ProfileRowLinkContent(
                            icon: "lock.shield",
                            title: "Linked Accounts",
                            subtitle: "\(linkedProviders.count) sign-in method\(linkedProviders.count == 1 ? "" : "s")"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Divider().padding(.leading, 56)

                    // Password is a sheet, not a push destination
                    Button {
                        showingPasswordChange = true
                    } label: {
                        ProfileRowLinkContent(
                            icon: "key",
                            title: linkedProviders.contains(.email) ? "Change Password" : "Set Password",
                            subtitle: linkedProviders.contains(.email) ? "Update your password" : "Add email sign-in"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Divider().padding(.leading, 56)

                    NavigationLink(destination: DeleteAccountView()) {
                        ProfileRowLinkContent(
                            icon: "trash",
                            title: "Delete Account",
                            subtitle: "Permanently delete your account"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .padding(.horizontal, Space.lg)

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await authService.reloadCurrentUser()
            linkedProviders = authService.linkedProviders
        }
        .sheet(isPresented: $showingPasswordChange) {
            PasswordChangeView(hasEmailProvider: linkedProviders.contains(.email))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color.textSecondary)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }
}
