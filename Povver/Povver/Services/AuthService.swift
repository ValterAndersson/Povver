import AuthenticationServices
import Foundation
import UIKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn

class AuthService: ObservableObject {
    static let shared = AuthService()
    private let db = Firestore.firestore()
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    @Published var isAuthenticated = false
    @Published var currentUser: FirebaseAuth.User?

    private init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.isAuthenticated = user != nil
            self?.currentUser = user

            if let user = user {
                FirebaseConfig.shared.setUserForCrashlytics(user.uid)
                AnalyticsService.shared.setUserId(user.uid)
                FirebaseConfig.shared.setUserForAnalytics(user.uid)
                Task {
                    try? await TimezoneManager.shared.initializeTimezoneIfNeeded(userId: user.uid)
                }
            }
        }
    }

    // MARK: - Email Sign-Up / Sign-In

    func signUp(email: String, password: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        try await createUserDocument(
            userId: result.user.uid,
            email: email,
            provider: AuthProvider.email.firestoreValue
        )
        AnalyticsService.shared.signupCompleted(provider: "email")
        AnalyticsService.shared.recordSignupDate()
        try await TimezoneManager.shared.initializeTimezoneIfNeeded(userId: result.user.uid)
        try await DeviceManager.shared.registerCurrentDevice(for: result.user.uid)
    }

    func signIn(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        try await TimezoneManager.shared.initializeTimezoneIfNeeded(userId: result.user.uid)
        try await DeviceManager.shared.registerCurrentDevice(for: result.user.uid)
    }

    // MARK: - Google Sign-In

    /// SSO sign-in returns `.newUser` if no Firestore user doc exists.
    /// Caller MUST show confirmation UI before calling confirmSSOAccountCreation().
    /// This prevents auto-creating accounts without explicit user consent.
    /// Pattern shared by Google and Apple sign-in flows.
    enum SSOSignInResult {
        case existingUser
        case newUser(userId: String, email: String, name: String?)
    }

    /// Performs Google Sign-In and authenticates with Firebase.
    /// Returns `.newUser` if no Firestore user document exists (caller should confirm account creation).
    @MainActor
    func signInWithGoogle() async throws -> SSOSignInResult {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthServiceError.missingClientID
        }
        guard let rootVC = UIApplication.shared.rootViewController else {
            throw AuthServiceError.noRootViewController
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingIDToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )

        let authResult = try await Auth.auth().signIn(with: credential)
        let userId = authResult.user.uid

        // Refresh provider data after sign-in (Firebase may have auto-linked providers)
        try await authResult.user.reload()
        self.currentUser = Auth.auth().currentUser

        // Check if Firestore user document already exists
        let userDoc = try? await UserRepository.shared.getUser(userId: userId)
        if userDoc != nil {
            // Existing user — complete sign-in
            try await TimezoneManager.shared.initializeTimezoneIfNeeded(userId: userId)
            try await DeviceManager.shared.registerCurrentDevice(for: userId)
            return .existingUser
        } else {
            // New user — return details for confirmation
            return .newUser(
                userId: userId,
                email: authResult.user.email ?? "",
                name: authResult.user.displayName
            )
        }
    }

    /// Called after user confirms new account creation via SSO.
    func confirmSSOAccountCreation(
        userId: String,
        email: String,
        name: String?,
        provider: AuthProvider,
        appleAuthCode: String? = nil
    ) async throws {
        try await createUserDocument(
            userId: userId,
            email: email,
            provider: provider.firestoreValue,
            name: name,
            appleAuthCode: appleAuthCode
        )
        AnalyticsService.shared.signupCompleted(provider: provider.firestoreValue)
        AnalyticsService.shared.recordSignupDate()
        try await TimezoneManager.shared.initializeTimezoneIfNeeded(userId: userId)
        try await DeviceManager.shared.registerCurrentDevice(for: userId)
    }

    /// Reauthenticates the current user with Google (for sensitive operations).
    @MainActor
    func reauthenticateWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthServiceError.missingClientID
        }
        guard let rootVC = UIApplication.shared.rootViewController else {
            throw AuthServiceError.noRootViewController
        }
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingIDToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await user.reauthenticate(with: credential)
    }

    /// Links Google as a provider to the current account.
    @MainActor
    func linkGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthServiceError.missingClientID
        }
        guard let rootVC = UIApplication.shared.rootViewController else {
            throw AuthServiceError.noRootViewController
        }
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingIDToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await user.link(with: credential)

        // Refresh so linkedProviders reflects the change immediately
        try await user.reload()
        self.currentUser = Auth.auth().currentUser
    }

    /// Refreshes the cached currentUser so providerData is up to date.
    func reloadCurrentUser() async {
        try? await currentUser?.reload()
        await MainActor.run {
            self.currentUser = Auth.auth().currentUser
        }
    }

    // MARK: - Apple Sign-In

    @MainActor private let appleCoordinator = AppleSignInCoordinator()

    /// Performs Apple Sign-In and authenticates with Firebase.
    /// Returns `.newUser` if no Firestore user document exists.
    @MainActor
    func signInWithApple() async throws -> SSOSignInResult {
        let appleResult = try await appleCoordinator.signIn()

        let credential = OAuthProvider.appleCredential(
            withIDToken: appleResult.idToken,
            rawNonce: appleResult.rawNonce,
            fullName: appleResult.fullName
        )

        let authResult = try await Auth.auth().signIn(with: credential)
        let userId = authResult.user.uid

        // Refresh provider data
        try await authResult.user.reload()
        self.currentUser = Auth.auth().currentUser

        // Check if Firestore user document already exists
        let userDoc = try? await UserRepository.shared.getUser(userId: userId)
        if userDoc != nil {
            // Existing user — store updated auth code if available (needed for future token revocation)
            if let authCode = appleResult.authorizationCode {
                try? await db.collection("users").document(userId).updateData([
                    "apple_authorization_code": authCode
                ])
            }
            try await TimezoneManager.shared.initializeTimezoneIfNeeded(userId: userId)
            try await DeviceManager.shared.registerCurrentDevice(for: userId)
            return .existingUser
        } else {
            // New user — build display name from Apple's name components
            var displayName: String?
            if let fullName = appleResult.fullName {
                let parts = [fullName.givenName, fullName.familyName].compactMap { $0 }
                if !parts.isEmpty {
                    displayName = parts.joined(separator: " ")
                }
            }
            return .newUser(
                userId: userId,
                email: authResult.user.email ?? appleResult.email ?? "",
                name: displayName
            )
        }
    }

    /// Called by confirmSSOAccountCreation for Apple — stores the auth code for token revocation.
    private var pendingAppleAuthCode: String?

    /// Reauthenticates the current user with Apple (for sensitive operations).
    @MainActor
    func reauthenticateWithApple() async throws {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }

        let appleResult = try await appleCoordinator.signIn()
        let credential = OAuthProvider.appleCredential(
            withIDToken: appleResult.idToken,
            rawNonce: appleResult.rawNonce,
            fullName: appleResult.fullName
        )
        try await user.reauthenticate(with: credential)
    }

    /// Links Apple as a provider to the current account.
    @MainActor
    func linkApple() async throws {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }

        let appleResult = try await appleCoordinator.signIn()
        let credential = OAuthProvider.appleCredential(
            withIDToken: appleResult.idToken,
            rawNonce: appleResult.rawNonce,
            fullName: appleResult.fullName
        )
        try await user.link(with: credential)

        // Store the auth code for future token revocation
        if let authCode = appleResult.authorizationCode {
            try? await db.collection("users").document(user.uid).updateData([
                "apple_authorization_code": authCode
            ])
        }

        try await user.reload()
        self.currentUser = Auth.auth().currentUser
    }

    // MARK: - User Document Creation (shared by email + SSO sign-up)

    /// Creates the Firestore user document after a new account is created.
    /// Called by `signUp()` for email and by SSO confirmation flows for Google/Apple.
    func createUserDocument(
        userId: String,
        email: String,
        provider: String,
        name: String? = nil,
        appleAuthCode: String? = nil
    ) async throws {
        let userRef = db.collection("users").document(userId)

        var userData: [String: Any] = [
            "email": email,
            "uid": userId,
            "created_at": Timestamp(),
            "provider": provider,
            "week_starts_on_monday": true
        ]
        if let name = name {
            userData["name"] = name
        }
        if let code = appleAuthCode {
            userData["apple_authorization_code"] = code
        }

        try await userRef.setData(userData)
    }

    // MARK: - Linked Providers

    /// Returns the list of auth providers currently linked to the signed-in user.
    var linkedProviders: [AuthProvider] {
        guard let providerData = currentUser?.providerData else { return [] }
        return providerData.compactMap { AuthProvider.from($0.providerID) }
    }

    // MARK: - Email Change

    /// Sends a verification email to the new address. The actual email change
    /// happens when the user clicks the link. Requires recent authentication.
    func changeEmail(to newEmail: String) async throws {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }
        try await user.sendEmailVerification(beforeUpdatingEmail: newEmail)
    }

    // MARK: - Password Management

    /// Changes password for an email/password user. Reauthenticates first.
    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard let user = currentUser, let email = user.email else {
            throw AuthServiceError.notSignedIn
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: currentPassword)
        try await user.reauthenticate(with: credential)
        try await user.updatePassword(to: newPassword)
    }

    /// Adds email/password as a provider to an SSO-only account.
    func setPassword(_ password: String) async throws {
        guard let user = currentUser, let email = user.email else {
            throw AuthServiceError.notSignedIn
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await user.link(with: credential)
    }

    // MARK: - Password Reset

    /// Sends a password reset email. Works for email/password accounts only.
    func sendPasswordReset(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    // MARK: - Reauthentication

    func reauthenticateWithEmail(password: String) async throws {
        guard let user = currentUser, let email = user.email else {
            throw AuthServiceError.notSignedIn
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await user.reauthenticate(with: credential)
    }

    // MARK: - Provider Linking / Unlinking

    func linkProvider(_ credential: AuthCredential) async throws {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }
        try await user.link(with: credential)
    }

    func unlinkProvider(_ provider: AuthProvider) async throws {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }
        guard user.providerData.count > 1 else {
            throw AuthServiceError.cannotUnlinkLastProvider
        }
        _ = try await user.unlink(fromProvider: provider.rawValue)
    }

    // MARK: - Account Deletion

    /// Full deletion sequence: revoke Apple token → server-side data purge → end session.
    /// Server-side deleteAccount Cloud Function handles all Firestore data deletion
    /// (including admin-only collections) and Firebase Auth account deletion.
    func deleteAccount() async throws {
        guard let user = currentUser else { throw AuthServiceError.notSignedIn }
        let userId = user.uid

        // If Apple is a linked provider, revoke the token before deletion (App Store requirement 5.1.1(v))
        if linkedProviders.contains(.apple) {
            if let userDoc = try? await UserRepository.shared.getUser(userId: userId),
               let authCode = userDoc.appleAuthorizationCode {
                do {
                    try await Auth.auth().revokeToken(withAuthorizationCode: authCode)
                } catch {
                    // Token revocation failed — auth code may have been consumed already
                    // (Apple auth codes are single-use). Log but proceed with deletion.
                    AppLogger.shared.error(.app, "Apple token revocation failed", error)
                }
            }
        }

        // Server-side deletion — purges all Firestore data + deletes Firebase Auth account
        struct DeleteResponse: Decodable {
            let success: Bool
            let data: DeleteData?
            struct DeleteData: Decodable {
                let deleted: Bool
                let totalDeleted: Int
            }
        }

        let _: DeleteResponse = try await ApiClient.shared.postJSON("deleteAccount", body: EmptyBody())

        // End the local session
        SessionManager.shared.endSession()
    }

    /// Empty request body for endpoints that don't need parameters
    private struct EmptyBody: Encodable {}

    // MARK: - Sign Out

    func signOut() throws {
        try Auth.auth().signOut()
        SessionManager.shared.endSession()
    }

    // MARK: - Friendly Error Messages

    /// Maps Firebase Auth errors to user-friendly messages.
    static func friendlyAuthError(_ error: Error) -> String {
        let nsError = error as NSError
        guard let code = AuthErrorCode(rawValue: nsError.code) else {
            return "Something went wrong. Please try again."
        }

        switch code {
        case .wrongPassword:
            return "Incorrect password. Please try again."
        case .requiresRecentLogin:
            return "For your security, please sign in again to continue."
        case .emailAlreadyInUse:
            return "This email is already in use by another account."
        case .weakPassword:
            return "Password must be at least 6 characters."
        case .accountExistsWithDifferentCredential:
            return "An account with this email already exists. Please sign in with your original method, then link this provider in Settings."
        case .invalidCredential:
            return "The sign-in credentials are invalid. Please try again."
        case .networkError:
            return "Network error. Please check your connection and try again."
        case .credentialAlreadyInUse:
            return "This account is already linked to a different Povver account."
        case .userNotFound:
            return "No account found with this email. Please register first."
        default:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Error Types

enum AuthServiceError: LocalizedError {
    case notSignedIn
    case cannotUnlinkLastProvider
    case missingClientID
    case noRootViewController
    case missingIDToken

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to perform this action."
        case .cannotUnlinkLastProvider:
            return "You need at least one sign-in method. Link another method before unlinking."
        case .missingClientID:
            return "Google Sign-In configuration error. Please try again."
        case .noRootViewController:
            return "Unable to present sign-in. Please try again."
        case .missingIDToken:
            return "Google Sign-In failed. Please try again."
        }
    }
}
