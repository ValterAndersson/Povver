import SwiftUI
import FirebaseAuth

struct LoginView: View {
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var session = SessionManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var loginFailureCount = 0
    @State private var showingForgotPassword = false
    @State private var showingNewAccountConfirmation = false
    @State private var pendingSSOResult: AuthService.SSOSignInResult?
    var onLogin: ((String) -> Void)? = nil
    var onRegister: (() -> Void)? = nil

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

                            Text("Welcome back")
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
                                            isSecure: true, textContentType: .password)
                                .id("password")
                        }

                        // Forgot password
                        HStack {
                            Spacer()
                            Button {
                                showingForgotPassword = true
                            } label: {
                                Text("Forgot Password?")
                                    .textStyle(.caption)
                                    .foregroundColor(.accent)
                            }
                        }

                        // Error message
                        if loginFailureCount > 0 {
                            InlineError(
                                failureCount: loginFailureCount,
                                firstMessage: errorMessage ?? "That didn't work — check your details and try again.",
                                secondMessage: errorMessage ?? "Still not working — check your connection or try another method."
                            )
                        }

                        // Login button
                        PovverButton("Login") {
                            await performLoginAsync()
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

                        // Social login buttons
                        VStack(spacing: Space.md) {
                            PovverButton("Sign in with Google", style: .secondary, leadingIcon: Image(systemName: "globe")) {
                                await performGoogleSignInAsync()
                            }

                            PovverButton("Sign in with Apple", style: .secondary, leadingIcon: Image(systemName: "apple.logo")) {
                                await performAppleSignInAsync()
                            }
                        }

                        Spacer(minLength: Space.xxxl)

                        // Register link
                        Button {
                            onRegister?()
                        } label: {
                            Text("Don't have an account? ")
                                .foregroundColor(.textSecondary) +
                            Text("Register")
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
        .onChange(of: email) { _, _ in loginFailureCount = 0 }
        .onChange(of: password) { _, _ in loginFailureCount = 0 }
        .background(Color.bg.ignoresSafeArea())
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView(prefillEmail: email)
        }
        .confirmationDialog(
            "Create Account",
            isPresented: $showingNewAccountConfirmation
        ) {
            Button("Create Account") {
                confirmSSOAccount()
            }
            Button("Cancel", role: .cancel) {
                // User declined — sign out the Firebase auth session that was created
                AnalyticsService.shared.ssoConfirmationCancelled(provider: ssoProvider == .apple ? .apple : .google)
                try? authService.signOut()
            }
        } message: {
            if case .newUser(_, let email, _) = pendingSSOResult {
                Text("No account found for \(email). Would you like to create one?")
            }
        }
    }

    // MARK: - Actions

    @State private var ssoProvider: AuthProvider?

    private func performLoginAsync() async {
        do {
            try await authService.signIn(email: email, password: password)
            if let user = Auth.auth().currentUser {
                session.startSession(userId: user.uid)
                AnalyticsService.shared.loginCompleted(provider: .email)
                onLogin?(user.uid)
            }
            errorMessage = nil
            loginFailureCount = 0
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
            loginFailureCount += 1
        }
    }

    private func performGoogleSignInAsync() async {
        ssoProvider = .google
        await performSSOSignInAsync { try await authService.signInWithGoogle() }
    }

    private func performAppleSignInAsync() async {
        ssoProvider = .apple
        await performSSOSignInAsync { try await authService.signInWithApple() }
    }

    private func performSSOSignInAsync(_ signIn: () async throws -> AuthService.SSOSignInResult) async {
        do {
            let result = try await signIn()
            switch result {
            case .existingUser:
                if let user = Auth.auth().currentUser {
                    session.startSession(userId: user.uid)
                    AnalyticsService.shared.loginCompleted(provider: ssoProvider == .apple ? .apple : .google)
                    onLogin?(user.uid)
                }
            case .newUser:
                pendingSSOResult = result
                AnalyticsService.shared.ssoConfirmationShown(provider: ssoProvider == .apple ? .apple : .google)
                showingNewAccountConfirmation = true
            }
            errorMessage = nil
            loginFailureCount = 0
        } catch {
            errorMessage = AuthService.friendlyAuthError(error)
            loginFailureCount += 1
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
                    provider: ssoProvider ?? .google
                )
                session.startSession(userId: userId)
                onLogin?(userId)
            } catch {
                errorMessage = AuthService.friendlyAuthError(error)
            }
            isLoading = false
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
    }
}
