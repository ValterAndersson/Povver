import SwiftUI

/// Full-screen view showing linked sign-in providers and options to link/unlink.
/// NavigationLink destination from SecurityView.
struct LinkedAccountsView: View {
    @ObservedObject private var authService = AuthService.shared
    @State private var linkedProviders: [AuthProvider] = []
    @State private var providerToUnlink: AuthProvider?
    @State private var showingUnlinkConfirmation = false
    @State private var showingPasswordSheet = false
    @State private var errorMessage: String?

    private var availableProviders: [AuthProvider] {
        AuthProvider.allCases.filter { !linkedProviders.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Linked providers
                sectionHeader("Linked Sign-In Methods")

                VStack(spacing: 0) {
                    ForEach(Array(linkedProviders.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }

                        HStack(spacing: Space.md) {
                            provider.icon
                                .font(.system(size: 18))
                                .foregroundColor(.textSecondary)
                                .frame(width: 24)

                            Text(provider.displayName)
                                .font(.system(size: 15))
                                .foregroundColor(.textPrimary)

                            Spacer()

                            if linkedProviders.count > 1 {
                                Button {
                                    providerToUnlink = provider
                                    showingUnlinkConfirmation = true
                                } label: {
                                    Text("Unlink")
                                        .font(.system(size: 14))
                                        .foregroundColor(.destructive)
                                }
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.accent)
                            }
                        }
                        .padding(Space.md)
                    }
                }
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .padding(.horizontal, Space.lg)

                if linkedProviders.count <= 1 {
                    Text("You need at least one sign-in method. Link another method before unlinking.")
                        .textStyle(.caption)
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, Space.lg)
                }

                // Available to link
                if !availableProviders.isEmpty {
                    sectionHeader("Available to Link")

                    VStack(spacing: Space.md) {
                        ForEach(availableProviders) { provider in
                            switch provider {
                            case .email:
                                PovverButton("Set Password", style: .secondary, leadingIcon: provider.icon) {
                                    showingPasswordSheet = true
                                }
                            case .google:
                                PovverButton("Link Google", style: .secondary, leadingIcon: provider.icon) {
                                    Task { await linkGoogleProvider() }
                                }
                            case .apple:
                                PovverButton("Link Apple", style: .secondary, leadingIcon: provider.icon) {
                                    Task { await linkAppleProvider() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Space.lg)
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .padding(.horizontal, Space.lg)
                }

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("Linked Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await authService.reloadCurrentUser()
            linkedProviders = authService.linkedProviders
        }
        .onAppear {
            linkedProviders = authService.linkedProviders
        }
        .confirmationDialog(
            "Unlink \(providerToUnlink?.displayName ?? "")?",
            isPresented: $showingUnlinkConfirmation
        ) {
            Button("Unlink", role: .destructive) {
                if let provider = providerToUnlink {
                    Task { await unlinkProvider(provider) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("If you unlink \(providerToUnlink?.displayName ?? ""), you won't be able to sign in with it anymore. Are you sure?")
        }
        .sheet(isPresented: $showingPasswordSheet) {
            PasswordChangeView(hasEmailProvider: false)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }

    // MARK: - Actions

    private func linkAppleProvider() async {
        errorMessage = nil
        do {
            try await authService.linkApple()
            linkedProviders = authService.linkedProviders
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
        }
    }

    private func linkGoogleProvider() async {
        errorMessage = nil
        do {
            try await authService.linkGoogle()
            linkedProviders = authService.linkedProviders
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
        }
    }

    private func unlinkProvider(_ provider: AuthProvider) async {
        errorMessage = nil
        do {
            try await authService.unlinkProvider(provider)
            linkedProviders = authService.linkedProviders
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
        }
    }
}
