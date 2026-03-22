import SwiftUI
import FirebaseAuth

struct RegisterView: View {
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var session = SessionManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var registerFailureCount = 0
    @State private var showingNewAccountConfirmation = false
    @State private var pendingSSOResult: AuthService.SSOSignInResult?
    var onRegister: ((String) -> Void)? = nil
    var onBackToLogin: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Space.xl) {
                        Spacer(minLength: Space.xxxl)

                        // Brand header
                        VStack(spacing: Space.sm) {
                            Text("POVVER")
                                .font(.system(size: 40, weight: .black, design: .default))
                                .tracking(2)
                                .foregroundColor(.textPrimary)

                            Text("Create your account")
                                .textStyle(.secondary)
                                .foregroundColor(.textSecondary)
                        }

                        // Form fields
                        VStack(spacing: Space.md) {
                            PovverTextField("Email", text: $email, placeholder: "you@example.com",
                                            keyboard: .emailAddress, autocapitalization: .never,
                                            textContentType: .emailAddress)
                                .id("email")

                            PovverTextField("Password", text: $password, placeholder: "••••••••",
                                            isSecure: true, textContentType: .newPassword)
                                .id("password")
                        }

                        // Error message
                        if registerFailureCount > 0 {
                            InlineError(
                                failureCount: registerFailureCount,
                                firstMessage: errorMessage ?? "That didn't work — check your details and try again.",
                                secondMessage: errorMessage ?? "Still not working — check your connection or try another method."
                            )
                        }

                        // Register button
                        PovverButton("Create Account") {
                            await performRegistrationAsync()
                        }
                        .disabled(email.isEmpty || password.isEmpty)

                        // Divider
                        HStack(spacing: Space.md) {
                            Rectangle()
                                .fill(Color.separatorLine)
                                .frame(height: StrokeWidthToken.hairline)
                            Text("or")
                                .textStyle(.secondary)
                                .foregroundColor(.textTertiary)
                            Rectangle()
                                .fill(Color.separatorLine)
                                .frame(height: StrokeWidthToken.hairline)
                        }
                        .padding(.vertical, Space.sm)

                        // Social signup buttons
                        VStack(spacing: Space.md) {
                            PovverButton("Sign up with Google", style: .secondary, leadingIcon: Image(systemName: "globe")) {
                                await performGoogleSignInAsync()
                            }

                            PovverButton("Sign up with Apple", style: .secondary, leadingIcon: Image(systemName: "apple.logo")) {
                                await performAppleSignInAsync()
                            }
                        }

                        Spacer(minLength: Space.xxxl)

                        // Login link
                        Button {
                            onBackToLogin?()
                        } label: {
                            Text("Already have an account? ")
                                .foregroundColor(.textSecondary) +
                            Text("Login")
                                .foregroundColor(.accent)
                                .fontWeight(.semibold)
                        }
                        .textStyle(.secondary)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onChange(of: email) { _, _ in registerFailureCount = 0 }
        .onChange(of: password) { _, _ in registerFailureCount = 0 }
        .background(Color.bg.ignoresSafeArea())
        .confirmationDialog(
            "Create Account",
            isPresented: $showingNewAccountConfirmation
        ) {
            Button("Create Account") {
                confirmSSOAccount()
            }
            Button("Cancel", role: .cancel) {
                AnalyticsService.shared.ssoConfirmationCancelled(provider: ssoProvider == .apple ? .apple : .google)
                try? authService.signOut()
            }
        } message: {
            if case .newUser(_, let email, _) = pendingSSOResult {
                Text("Create a new Povver account with \(email)?")
            }
        }
    }

    // MARK: - Actions

    @State private var ssoProvider: AuthProvider?

    private func performRegistrationAsync() async {
        do {
            AnalyticsService.shared.signupStarted(provider: .email)
            try await authService.signUp(email: email, password: password)
            if let user = Auth.auth().currentUser {
                session.startSession(userId: user.uid)
                onRegister?(user.uid)
            }
            errorMessage = nil
            registerFailureCount = 0
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
            registerFailureCount += 1
        }
    }

    private func performGoogleSignInAsync() async {
        ssoProvider = .google
        AnalyticsService.shared.signupStarted(provider: .google)
        await performSSOSignInAsync { try await authService.signInWithGoogle() }
    }

    private func performAppleSignInAsync() async {
        ssoProvider = .apple
        AnalyticsService.shared.signupStarted(provider: .apple)
        await performSSOSignInAsync { try await authService.signInWithApple() }
    }

    private func performSSOSignInAsync(_ signIn: () async throws -> AuthService.SSOSignInResult) async {
        do {
            let result = try await signIn()
            switch result {
            case .existingUser:
                if let user = Auth.auth().currentUser {
                    session.startSession(userId: user.uid)
                    onRegister?(user.uid)
                }
            case .newUser:
                pendingSSOResult = result
                AnalyticsService.shared.ssoConfirmationShown(provider: ssoProvider == .apple ? .apple : .google)
                showingNewAccountConfirmation = true
            }
            errorMessage = nil
            registerFailureCount = 0
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
            registerFailureCount += 1
        }
    }

    private func confirmSSOAccount() {
        guard case .newUser(let userId, let email, let name) = pendingSSOResult else { return }
        isLoading = true
        Task {
            do {
                try await authService.confirmSSOAccountCreation(
                    userId: userId,
                    email: email,
                    name: name,
                    provider: ssoProvider ?? .apple
                )
                session.startSession(userId: userId)
                onRegister?(userId)
            } catch {
                errorMessage = AuthService.friendlyAuthError(error)
            }
            isLoading = false
        }
    }
}

struct RegisterView_Previews: PreviewProvider {
    static var previews: some View {
        RegisterView()
    }
}
