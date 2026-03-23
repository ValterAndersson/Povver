import Foundation
import StoreKit
import CryptoKit
import FirebaseFirestore

// MARK: - SubscriptionService
// Singleton service for managing App Store subscriptions with StoreKit 2.
// Handles product fetching, purchasing, transaction validation, and sync to Firestore.
// Uses UUID v5 deterministic generation for appAccountToken (derived from Firebase UID).
//
// Firestore fields are flat on users/{uid} to match the server-side schema
// (subscription_status, subscription_tier, subscription_app_account_token, etc.).
// The server-side gate in subscription-gate.js reads these same flat fields.
//
// IMPORTANT: Only syncs to Firestore when StoreKit reports a POSITIVE entitlement.
// For the free/expired case, the webhook is the authoritative source — the client
// must not overwrite server-set subscription_tier with "free" based on stale
// StoreKit cache (e.g., new device, delayed entitlement sync).

@MainActor
class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    // MARK: - Published Properties

    @Published var subscriptionState: UserSubscriptionState = .free
    @Published var availableProducts: [Product] = []
    @Published var isLoading = false
    @Published var isTrialEligible = false
    @Published var error: SubscriptionError?

    /// Convenience: true when user has premium access (via override or subscription)
    var isPremium: Bool { subscriptionState.isPremium }

    // MARK: - Private Properties

    private var transactionListener: Task<Void, Never>?

    // Product IDs configured in App Store Connect
    private let productIds = ["com.povver.premium.monthly"]

    // Fixed namespace UUID for deterministic UUID v5 generation.
    // DNS namespace (RFC 4122) — same constant used in Firebase Functions webhook
    // to derive the same UUID from the same Firebase UID.
    private static let uuidNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!

    // MARK: - Initialization

    private init() {
        startTransactionListener()
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Public Methods

    /// Load available subscription products from App Store
    func loadProducts() async {
        isLoading = true
        error = nil

        do {
            let products = try await Product.products(for: productIds)
            self.availableProducts = products.sorted { $0.price < $1.price }

            // Check trial eligibility for the first product
            if let product = products.first {
                self.isTrialEligible = await isEligibleForTrial(product)
            }

            self.isLoading = false
        } catch {
            self.error = .productLoadFailed(error)
            self.isLoading = false
        }
    }

    /// Check current subscription status from StoreKit entitlements.
    /// Works offline — Transaction.currentEntitlements uses cached data.
    ///
    /// Only syncs to Firestore when a positive entitlement is found.
    /// If no entitlement exists, updates local state only — the webhook
    /// is the authoritative source for expiration/cancellation.
    func checkEntitlements() async {
        // Also load the user's Firestore override so isPremium reflects admin grants
        await loadOverrideFromFirestore()

        var latestTransaction: StoreKit.Transaction?

        for await result in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result),
                  productIds.contains(transaction.productID) else { continue }

            if latestTransaction == nil || transaction.purchaseDate > (latestTransaction?.purchaseDate ?? .distantPast) {
                latestTransaction = transaction
            }
        }

        if let transaction = latestTransaction {
            updateState(from: transaction)
            // Only sync positive entitlements to Firestore
            await syncToFirestore()
        } else {
            // No StoreKit entitlement — set local state to free but do NOT
            // write to Firestore. The webhook may have set tier=premium that
            // we don't want to overwrite with stale client state.
            self.subscriptionState = UserSubscriptionState(
                tier: .free,
                status: .free,
                override: subscriptionState.override, // preserve Firestore override
                expiresAt: nil,
                autoRenewEnabled: false,
                inGracePeriod: false,
                productId: nil,
                originalTransactionId: nil,
                appAccountToken: nil
            )
        }
    }

    /// Purchase a subscription product
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard let userId = AuthService.shared.currentUser?.uid else {
            self.error = .notAuthenticated
            return false
        }

        isLoading = true
        error = nil

        do {
            let appAccountToken = Self.generateAppAccountToken(from: userId)

            let result = try await product.purchase(options: [
                .appAccountToken(appAccountToken)
            ])

            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                updateState(from: transaction)
                await transaction.finish()
                await syncToFirestore()

                // Track purchase analytics
                let priceValue = NSDecimalNumber(decimal: product.price).doubleValue
                let currency = Locale.current.currency?.identifier ?? "USD"

                if self.subscriptionState.status == .trial {
                    AnalyticsService.shared.trialStarted(productId: product.id)
                } else {
                    AnalyticsService.shared.subscriptionPurchased(
                        productId: product.id,
                        isFromTrial: false,
                        value: priceValue,
                        currency: currency
                    )
                }
                isLoading = false
                return true

            case .userCancelled:
                error = .purchaseCancelled
                isLoading = false
                return false

            case .pending:
                error = .purchasePending
                isLoading = false
                return false

            @unknown default:
                error = .unknownPurchaseResult
                isLoading = false
                return false
            }

        } catch {
            self.error = .purchaseFailed(error)
            isLoading = false
            return false
        }
    }

    /// Restore purchases — forces sync with App Store then re-checks entitlements
    func restorePurchases() async {
        isLoading = true
        error = nil

        do {
            try await AppStore.sync()
            await checkEntitlements()
            AnalyticsService.shared.subscriptionRestored()
            isLoading = false
        } catch {
            self.error = .restoreFailed(error)
            isLoading = false
        }
    }

    /// Check if the user is eligible for the introductory offer (free trial)
    func isEligibleForTrial(_ product: Product) async -> Bool {
        guard let subscription = product.subscription else { return false }
        return await subscription.isEligibleForIntroOffer
    }

    // MARK: - UUID v5 Generation

    /// Generate deterministic UUID v5 from Firebase UID.
    /// Both iOS and Firebase Functions use the same namespace + algorithm,
    /// so the same UID always produces the same UUID.
    /// This is passed as appAccountToken during purchase and stored in Firestore
    /// so the webhook can look up the user by this token.
    static func generateAppAccountToken(from userId: String) -> UUID {
        let namespaceBytes = withUnsafeBytes(of: uuidNamespace.uuid) { Data($0) }
        let nameBytes = Data(userId.utf8)

        var hasher = Insecure.SHA1()
        hasher.update(data: namespaceBytes)
        hasher.update(data: nameBytes)
        let hash = hasher.finalize()

        var uuidBytes = Array(hash.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50  // Version 5
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80  // Variant RFC 4122

        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }

    // MARK: - Private Methods

    /// Verify a StoreKit transaction result.
    /// Nonisolated — pure validation with no state access, safe to call from any context.
    private nonisolated static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw SubscriptionError.failedVerification
        }
    }

    /// Read subscription_override from Firestore so isPremium reflects admin grants.
    /// Called during checkEntitlements() to hydrate the override before gate checks.
    private func loadOverrideFromFirestore() async {
        guard let userId = AuthService.shared.currentUser?.uid else { return }

        do {
            let doc = try await Firestore.firestore()
                .collection("users").document(userId).getDocument()
            let override = doc.data()?["subscription_override"] as? String
            subscriptionState = UserSubscriptionState(
                tier: subscriptionState.tier,
                status: subscriptionState.status,
                override: override,
                expiresAt: subscriptionState.expiresAt,
                autoRenewEnabled: subscriptionState.autoRenewEnabled,
                inGracePeriod: subscriptionState.inGracePeriod,
                productId: subscriptionState.productId,
                originalTransactionId: subscriptionState.originalTransactionId,
                appAccountToken: subscriptionState.appAccountToken
            )
        } catch {
            AppLogger.shared.error(.store, "Failed to load override from Firestore", error)
        }
    }

    /// Derive subscription state from a verified transaction
    private func updateState(from transaction: StoreKit.Transaction) {
        // Determine status: introductoryOffer → trial, else active.
        // We only configure a free trial in App Store Connect, so .introductoryOffer = trial.
        let status: SubscriptionStatusValue
        if transaction.offer?.type == .introductory {
            status = .trial
        } else {
            status = .active
        }

        // Auto-renew: if the transaction has not been revoked and has a future expiration,
        // assume auto-renew is enabled. The webhook provides the authoritative value;
        // this is a reasonable client-side default.
        let autoRenew = transaction.revocationDate == nil
            && (transaction.expirationDate ?? .distantFuture) > Date()

        self.subscriptionState = UserSubscriptionState(
            tier: .premium,
            status: status,
            override: subscriptionState.override, // preserve existing override
            expiresAt: transaction.expirationDate,
            autoRenewEnabled: autoRenew,
            inGracePeriod: false,
            productId: transaction.productID,
            originalTransactionId: String(transaction.originalID),
            appAccountToken: transaction.appAccountToken?.uuidString.lowercased()
        )
    }

    /// Sync subscription state to Firestore via Cloud Function.
    /// Only called when we have a positive StoreKit entitlement — never for free state.
    /// Uses syncSubscriptionStatus Cloud Function (Firestore rules block direct client writes).
    /// Sends the Apple-signed JWS transaction for server-side verification.
    private func syncToFirestore() async {
        guard AuthService.shared.currentUser?.uid != nil else { return }

        let state = subscriptionState

        // Only sync positive entitlements (same guard as before)
        guard state.tier == .premium else { return }

        // Get the latest verified transaction's JWS for server-side verification
        var signedTransactionJWS: String?
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               productIds.contains(transaction.productID) {
                signedTransactionJWS = result.jwsRepresentation
                break
            }
        }

        guard let jwsString = signedTransactionJWS else {
            AppLogger.shared.error(.store, "No signed transaction available for sync")
            return
        }

        struct SyncRequest: Encodable {
            let status: String
            let tier: String
            let autoRenewEnabled: Bool
            let inGracePeriod: Bool
            let productId: String?
            let signedTransactionInfo: String
        }

        struct SyncResponse: Decodable {
            let success: Bool
        }

        let request = SyncRequest(
            status: state.status.rawValue,
            tier: state.tier.rawValue,
            autoRenewEnabled: state.autoRenewEnabled,
            inGracePeriod: state.inGracePeriod,
            productId: state.productId,
            signedTransactionInfo: jwsString
        )

        do {
            let _: SyncResponse = try await ApiClient.shared.postJSON("syncSubscriptionStatus", body: request)
            AppLogger.shared.info(.store, "Synced subscription: tier=\(state.tier.rawValue) status=\(state.status.rawValue)")
        } catch {
            // Non-critical — webhook is authoritative
            AppLogger.shared.error(.store, "Subscription sync failed", error)
        }
    }

    /// Listen for transaction updates (renewals, expirations, refunds) while app is running
    private func startTransactionListener() {
        transactionListener = Task.detached { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self = self else { break }
                do {
                    let transaction = try Self.checkVerified(result)
                    await MainActor.run {
                        self.updateState(from: transaction)
                    }
                    await transaction.finish()
                    await self.syncToFirestore()
                } catch {
                    AppLogger.shared.error(.store, "Transaction update verification failed", error)
                }
            }
        }
    }
}

// MARK: - Subscription Errors

enum SubscriptionError: LocalizedError {
    case notAuthenticated
    case productLoadFailed(Error)
    case purchaseFailed(Error)
    case purchaseCancelled
    case purchasePending
    case unknownPurchaseResult
    case restoreFailed(Error)
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in to manage subscriptions"
        case .productLoadFailed(let error):
            return "Failed to load subscription options: \(error.localizedDescription)"
        case .purchaseFailed(let error):
            return "Purchase failed: \(error.localizedDescription)"
        case .purchaseCancelled:
            return "Purchase was cancelled"
        case .purchasePending:
            return "Purchase is pending approval"
        case .unknownPurchaseResult:
            return "Unknown purchase result"
        case .restoreFailed(let error):
            return "Failed to restore purchases: \(error.localizedDescription)"
        case .failedVerification:
            return "Transaction verification failed"
        }
    }
}
