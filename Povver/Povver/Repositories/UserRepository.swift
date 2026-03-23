import Foundation
import FirebaseFirestore

class UserRepository {
    static let shared = UserRepository()
    private let db = Firestore.firestore()
    private let collection = "users"
    
    func getUser(userId: String) async throws -> User? {
        do {
            let doc = try await db.collection(collection).document(userId).getDocument()
            if doc.exists {
                let user = try doc.data(as: User.self)
                return user
            } else {
                return nil
            }
        } catch {
            AppLogger.shared.error(.store, "Error fetching user", error)
            throw error
        }
    }
    
    func updateUser(userId: String, user: User) async throws {
        do {
            try db.collection(collection).document(userId).setData(from: user, merge: true)
        } catch {
            AppLogger.shared.error(.store, "Error updating user", error)
            throw error
        }
    }
    
    // MARK: - User Profile
    
    func updateUserProfile(userId: String, name: String, email: String, weekStartsOnMonday: Bool? = nil, timeZone: String? = nil) async throws {
        let userRef = db.collection(collection).document(userId)
        var updates: [String: Any] = [
            "name": name,
            "email": email,
            "updated_at": FieldValue.serverTimestamp()
        ]
        if let weekStartsOnMonday = weekStartsOnMonday {
            updates["week_starts_on_monday"] = weekStartsOnMonday
        }
        if let timeZone = timeZone {
            updates["timezone"] = timeZone
        }
        try await userRef.updateData(updates)
    }
    
    // MARK: - Timezone Management
    
    /// Update user's timezone preference
    func updateUserTimezone(userId: String, timezone: String) async throws {
        guard TimeZone(identifier: timezone) != nil else {
            throw UserRepositoryError.invalidTimezone(timezone)
        }
        
        let userRef = db.collection(collection).document(userId)
        let updates: [String: Any] = [
            "timezone": timezone,
            "updated_at": FieldValue.serverTimestamp()
        ]
        
        do {
            try await userRef.updateData(updates)
            AppLogger.shared.info(.store, "Updated timezone to \(timezone)")
        } catch {
            AppLogger.shared.error(.store, "Failed to update timezone", error)
            throw UserRepositoryError.updateFailed(error)
        }
    }
    
    /// Get user's stored timezone, with fallback to device timezone
    func getUserTimezone(userId: String) async throws -> String {
        do {
            let user = try await getUser(userId: userId)
            return user?.timeZone ?? TimeZone.current.identifier
        } catch {
            AppLogger.shared.error(.store, "Failed to get timezone, using device timezone", error)
            return TimeZone.current.identifier
        }
    }
    
    func deleteUser(userId: String) async throws {
        let userRef = db.collection(collection).document(userId)
        
        // Delete all subcollections first
        // Matches Firestore security rules — "workout_templates" was wrong (collection is "templates")
        let subcollections = [
            "user_attributes", "linked_devices", "workouts", "templates",
            "routines", "active_workouts", "conversations", "progress_reports",
            "weekly_stats", "analytics_series_exercise", "analytics_series_muscle",
            "analytics_rollups", "analytics_state"
        ]
        for subcollection in subcollections {
            let snapshot = try await userRef.collection(subcollection).getDocuments()
            for document in snapshot.documents {
                try await document.reference.delete()
            }
        }
        
        // Finally delete the user document
        try await userRef.delete()
    }
    
    // MARK: - User Attributes
    
    func saveUserAttributes(_ attributes: UserAttributes) async throws {
        guard let id = attributes.id else {
            throw NSError(domain: "UserRepository", code: 0, userInfo: [NSLocalizedDescriptionKey: "UserAttributes.id is nil"])
        }
        let userRef = db.collection("users").document(id)
        let attributesRef = userRef.collection("user_attributes").document(id)
        try attributesRef.setData(from: attributes)
    }
    
    func getUserAttributes(userId: String) async throws -> UserAttributes? {
        let userRef = db.collection("users").document(userId)
        let attributesRef = userRef.collection("user_attributes").document(userId)
        let document = try await attributesRef.getDocument()
        
        if document.exists {
            return try document.data(as: UserAttributes.self)
        } else {
            return nil
        }
    }
    
    // MARK: - Linked Devices
    
    func addLinkedDevice(_ device: LinkedDevice, userId: String) async throws {
        let userRef = db.collection("users").document(userId)
        let devicesRef = userRef.collection("linked_devices").document(device.id)
        try devicesRef.setData(from: device)
    }
    
    func removeLinkedDevice(deviceId: String, userId: String) async throws {
        let userRef = db.collection("users").document(userId)
        let deviceRef = userRef.collection("linked_devices").document(deviceId)
        try await deviceRef.delete()
    }
    
    func getLinkedDevices(userId: String) async throws -> [LinkedDevice] {
        let userRef = db.collection("users").document(userId)
        let devicesRef = userRef.collection("linked_devices")
        let snapshot = try await devicesRef.getDocuments()
        return try snapshot.documents.compactMap { try $0.data(as: LinkedDevice.self) }
    }
    
    func updateDeviceSync(deviceId: String, userId: String) async throws {
        let userRef = db.collection("users").document(userId)
        let deviceRef = userRef.collection("linked_devices").document(deviceId)
        try await deviceRef.updateData([
            "last_sync": FieldValue.serverTimestamp(),
            "is_active": true
        ])
    }
    
    // MARK: - User Preferences

    func updateUserPreferences(userId: String, timezone: String? = nil, locale: String? = nil, currency: String? = nil) async throws {
        let userRef = db.collection("users").document(userId)
        let attributesRef = userRef.collection("user_attributes").document(userId)

        var updates: [String: Any] = [:]
        if let timezone = timezone { updates["timezone"] = timezone }
        if let locale = locale { updates["locale"] = locale }
        if let currency = currency { updates["currency"] = currency }
        updates["last_updated"] = FieldValue.serverTimestamp()

        try await attributesRef.updateData(updates)
    }

    func updateAutoPilot(userId: String, enabled: Bool) async throws {
        let userRef = db.collection(collection).document(userId)
        try await userRef.updateData([
            "auto_pilot_enabled": enabled,
            "updated_at": FieldValue.serverTimestamp()
        ])
    }
}

// MARK: - Error Types

enum UserRepositoryError: LocalizedError {
    case invalidTimezone(String)
    case updateFailed(Error)
    case userNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidTimezone(let tz):
            return "Invalid timezone identifier: \(tz)"
        case .updateFailed(let error):
            return "Failed to update user data: \(error.localizedDescription)"
        case .userNotFound:
            return "User not found"
        }
    }
}
