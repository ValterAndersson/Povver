import SwiftUI
import FirebaseAuth

/// Full-screen view for account deletion with reauthentication and confirmation.
/// NavigationLink destination from SecurityView.
struct DeleteAccountView: View {
    @ObservedObject private var authService = AuthService.shared
    @State private var showingReauth = false
    @State private var showingFinalConfirmation = false
    @State private var errorMessage: String?
    @State private var isDeleting = false

    private let deletedItems = [
        "Workout history and templates",
        "Progress and analytics",
        "AI coach memories",
        "Profile and account data"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                Spacer(minLength: Space.xl)

                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.destructive)

                Text("Delete Account")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.destructive)

                Text("This action cannot be undone. All your data will be permanently deleted:")
                    .textStyle(.secondary)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.lg)

                // Items list
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(deletedItems, id: \.self) { item in
                        HStack(spacing: Space.sm) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.destructive.opacity(0.7))
                            Text(item)
                                .textStyle(.secondary)
                                .foregroundColor(.textPrimary)
                        }
                    }
                }
                .padding(.horizontal, Space.xl)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Space.lg)
                }

                PovverButton("Delete My Account", style: .destructive) {
                    showingReauth = true
                }
                .disabled(isDeleting)
                .padding(.horizontal, Space.lg)

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReauth) {
            ReauthenticationView(
                providers: authService.linkedProviders,
                onSuccess: { showingFinalConfirmation = true }
            )
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingFinalConfirmation
        ) {
            Button("Delete Account", role: .destructive) {
                HapticManager.destructiveAction()
                Task { await performDeletion() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All your data will be permanently removed. This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func performDeletion() async {
        isDeleting = true
        errorMessage = nil
        do {
            AnalyticsService.shared.accountDeleted()
            try await authService.deleteAccount()
            // RootView reactively navigates to .login when isAuthenticated becomes false
        } catch {
            let nsError = error as NSError
            if AuthErrorCode(rawValue: nsError.code) == .requiresRecentLogin {
                // Race condition: session expired between reauth and delete
                showingReauth = true
            } else {
                errorMessage = AuthService.friendlyAuthError(error)
            }
        }
        isDeleting = false
    }
}
