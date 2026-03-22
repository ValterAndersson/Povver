import SwiftUI
import FirebaseAuth

struct OnboardingAuthScreen: View {
    let onAuthenticated: () -> Void
    let onSignIn: () -> Void

    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var session = SessionManager.shared

    @State private var isCreateMode = true
    @State private var showEmailForm = false
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    // SSO confirmation flow
    @State private var showingNewAccountConfirmation = false
    @State private var pendingSSOResult: AuthService.SSOSignInResult?
    @State private var ssoProvider: AuthProvider?

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            // Heading
            Text(isCreateMode ? "Create account" : "Sign in")
                .textStyle(.screenTitle)
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Auth buttons
            VStack(spacing: Space.md) {
                // Apple Sign-In
                Button {
                    performAppleSignIn()
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 20, weight: .semibold))
                        Text(isCreateMode ? "Continue with Apple" : "Sign in with Apple")
                            .font(TypographyToken.bodyStrong)
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .disabled(isLoading)

                // Google Sign-In
                Button {
                    performGoogleSignIn()
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "globe")
                            .font(.system(size: 20, weight: .semibold))
                        Text(isCreateMode ? "Continue with Google" : "Sign in with Google")
                            .font(TypographyToken.bodyStrong)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .background(Color(hex: "111820"))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
                )
                .disabled(isLoading)

                // Email Sign-Up/Sign-In
                Button {
                    showEmailForm = true
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "envelope")
                            .font(.system(size: 20, weight: .semibold))
                        Text(isCreateMode ? "Sign up with email" : "Sign in with email")
                            .font(TypographyToken.bodyStrong)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .background(Color(hex: "111820"))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: StrokeWidthToken.hairline)
                )
                .disabled(isLoading)
            }

            // Error message
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .textStyle(.caption)
                    .foregroundColor(.destructive)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.lg)
            }

            Spacer()

            // Mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCreateMode.toggle()
                    errorMessage = nil
                }
            } label: {
                if isCreateMode {
                    (Text("Already have an account? ")
                        .foregroundColor(.textSecondary) +
                     Text("Sign in")
                        .fontWeight(.semibold)
                        .foregroundColor(.accent))
                        .textStyle(.secondary)
                } else {
                    (Text("Don't have an account? ")
                        .foregroundColor(.textSecondary) +
                     Text("Create account")
                        .fontWeight(.semibold)
                        .foregroundColor(.accent))
                        .textStyle(.secondary)
                }
            }

            // Legal text (only in create mode)
            if isCreateMode {
                Text("By continuing you agree to our Terms & Privacy")
                    .textStyle(.micro)
                    .foregroundColor(.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xl)
        .sheet(isPresented: $showEmailForm) {
            emailFormSheet
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

    // MARK: - Email Form Sheet

    @ViewBuilder
    private var emailFormSheet: some View {
        NavigationView {
            VStack(spacing: Space.xl) {
                // Form fields
                VStack(spacing: Space.md) {
                    authTextField(
                        placeholder: "Email",
                        text: $email,
                        keyboardType: .emailAddress,
                        isSecure: false
                    )

                    authTextField(
                        placeholder: "Password",
                        text: $password,
                        keyboardType: .default,
                        isSecure: true
                    )
                }

                // Error message
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .multilineTextAlignment(.center)
                }

                // Submit button
                PovverButton(
                    isCreateMode ? "Create Account" : "Sign In",
                    style: .primary
                ) {
                    performEmailAuth()
                }
                .disabled(isLoading || email.isEmpty || password.isEmpty)

                Spacer()
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.xl)
            .navigationTitle(isCreateMode ? "Create Account" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showEmailForm = false
                        errorMessage = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func authTextField(
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        isSecure: Bool
    ) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .textStyle(.body)
        .foregroundColor(.textPrimary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .strokeBorder(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }

    // MARK: - Auth Actions

    private func performGoogleSignIn() {
        ssoProvider = .google
        performSSOSignIn { try await authService.signInWithGoogle() }
    }

    private func performAppleSignIn() {
        ssoProvider = .apple
        performSSOSignIn { try await authService.signInWithApple() }
    }

    private func performSSOSignIn(_ signIn: @escaping () async throws -> AuthService.SSOSignInResult) {
        isLoading = true
        Task {
            do {
                let result = try await signIn()
                switch result {
                case .existingUser:
                    if let user = Auth.auth().currentUser {
                        session.startSession(userId: user.uid)
                        AnalyticsService.shared.loginCompleted(provider: ssoProvider == .apple ? .apple : .google)
                        onSignIn()
                    }
                case .newUser:
                    pendingSSOResult = result
                    AnalyticsService.shared.ssoConfirmationShown(provider: ssoProvider == .apple ? .apple : .google)
                    showingNewAccountConfirmation = true
                }
                errorMessage = nil
            } catch {
                errorMessage = AuthService.friendlyAuthError(error)
            }
            isLoading = false
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
                onAuthenticated()
            } catch {
                errorMessage = AuthService.friendlyAuthError(error)
            }
            isLoading = false
        }
    }

    private func performEmailAuth() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                if isCreateMode {
                    try await authService.signUp(email: email, password: password)
                    if let user = Auth.auth().currentUser {
                        session.startSession(userId: user.uid)
                        AnalyticsService.shared.loginCompleted(provider: .email)
                        showEmailForm = false
                        onAuthenticated()
                    }
                } else {
                    try await authService.signIn(email: email, password: password)
                    if let user = Auth.auth().currentUser {
                        session.startSession(userId: user.uid)
                        AnalyticsService.shared.loginCompleted(provider: .email)
                        showEmailForm = false
                        onSignIn()
                    }
                }
            } catch {
                errorMessage = AuthService.friendlyAuthError(error)
            }
            isLoading = false
        }
    }
}

#if DEBUG
struct OnboardingAuthScreen_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingAuthScreen(onAuthenticated: {}, onSignIn: {})
            .background(Color.bg)
    }
}
#endif
