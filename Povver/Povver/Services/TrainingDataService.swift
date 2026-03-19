import Foundation
import FirebaseFirestore
import FirebaseAuth

/// Reads pre-computed training intelligence from Firestore.
/// All analytical data (ACWR, PRs, insights) is computed by the Training Analyst backend.
/// This service is a read/cache layer, not a computation layer.
class TrainingDataService: ObservableObject {
    static let shared = TrainingDataService()

    private let db = Firestore.firestore()
    private var cachedSnapshot: TrainingSnapshot?
    private var snapshotTimestamp: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    private init() {}

    // MARK: - Training Snapshot (for Coach tab)

    func fetchTrainingSnapshot() async throws -> TrainingSnapshot {
        if let cached = cachedSnapshot,
           let ts = snapshotTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "TrainingDataService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let userRef = db.collection("users").document(userId)

        // Fetch all three sources concurrently
        async let rollupTask = fetchCurrentWeekRollup(userRef: userRef)
        async let reviewTask = fetchLatestWeeklyReview(userRef: userRef)
        async let insightTask = fetchLatestInsight(userRef: userRef)

        let currentWeekRollup = try await rollupTask
        let latestReview = try await reviewTask
        let latestInsight = try await insightTask

        let snapshot = TrainingSnapshot(
            weeklyReview: latestReview,
            latestInsight: latestInsight,
            currentWeekRollup: currentWeekRollup
        )

        cachedSnapshot = snapshot
        snapshotTimestamp = Date()
        return snapshot
    }

    // MARK: - Weekly Workout Counts (for Consistency Map)

    func fetchWeeklyWorkoutCounts(weeks: Int = 12) async throws -> [WeekWorkoutCount] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }

        let userRef = db.collection("users").document(userId)
        let rollups = try await fetchRollups(userRef: userRef, weeks: weeks)

        return rollups.map { rollup in
            WeekWorkoutCount(
                weekId: rollup.id ?? "unknown",
                scheduledCount: 0, // Filled by CoachTabViewModel from routine schedule
                completedCount: rollup.workouts ?? 0
            )
        }
    }

    // MARK: - Post-Workout Summary

    func fetchPostWorkoutSummary(workoutId: String) async throws -> PostWorkoutSummary? {
        guard let userId = Auth.auth().currentUser?.uid else { return nil }

        let userRef = db.collection("users").document(userId)
        let snapshot = try await userRef.collection("analysis_insights")
            .whereField("workout_id", isEqualTo: workoutId)
            .limit(to: 1)
            .getDocuments()

        guard let doc = snapshot.documents.first,
              let insight = try? doc.data(as: PostWorkoutInsight.self) else {
            return nil
        }

        return PostWorkoutSummary(insight: insight)
    }

    // MARK: - Milestones

    func checkMilestones(workoutCount: Int) -> [Milestone] {
        let thresholds = [10, 25, 50, 100, 250, 500, 1000]
        let acknowledged = UserDefaults.standard.array(forKey: "acknowledgedMilestones") as? [String] ?? []

        return thresholds.compactMap { threshold in
            guard workoutCount >= threshold else { return nil }
            let id = "workout_count_\(threshold)"
            guard !acknowledged.contains(id) else { return nil }
            return Milestone(
                id: id,
                type: "consistency",
                message: "\(threshold) workouts completed. Consistency is the hardest exercise — you're doing it.",
                date: Date()
            )
        }
    }

    func acknowledgeMilestone(_ milestone: Milestone) {
        var acknowledged = UserDefaults.standard.array(forKey: "acknowledgedMilestones") as? [String] ?? []
        acknowledged.append(milestone.id)
        UserDefaults.standard.set(acknowledged, forKey: "acknowledgedMilestones")
    }

    /// Invalidate cache (call after workout completion)
    func invalidateCache() {
        cachedSnapshot = nil
        snapshotTimestamp = nil
    }

    // MARK: - Private Helpers

    private func fetchCurrentWeekRollup(userRef: DocumentReference) async throws -> AnalyticsRollup? {
        let calendar = Calendar.current
        let now = Date()
        let weekOfYear = calendar.component(.weekOfYear, from: now)
        let year = calendar.component(.yearForWeekOfYear, from: now)
        let weekId = String(format: "%04d-w%02d", year, weekOfYear)

        let doc = try await userRef.collection("analytics_rollups").document(weekId).getDocument()
        guard doc.exists else { return nil }
        return try? doc.data(as: AnalyticsRollup.self)
    }

    private func fetchRollups(userRef: DocumentReference, weeks: Int) async throws -> [AnalyticsRollup] {
        let snapshot = try await userRef.collection("analytics_rollups")
            .order(by: FieldPath.documentID(), descending: true)
            .limit(to: weeks)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            try? doc.data(as: AnalyticsRollup.self)
        }.reversed() // Chronological order (oldest first)
    }

    private func fetchLatestWeeklyReview(userRef: DocumentReference) async throws -> WeeklyReview? {
        let snapshot = try await userRef.collection("weekly_reviews")
            .order(by: FieldPath.documentID(), descending: true)
            .limit(to: 1)
            .getDocuments()

        return snapshot.documents.first.flatMap { try? $0.data(as: WeeklyReview.self) }
    }

    private func fetchLatestInsight(userRef: DocumentReference) async throws -> PostWorkoutInsight? {
        let snapshot = try await userRef.collection("analysis_insights")
            .order(by: "created_at", descending: true)
            .limit(to: 1)
            .getDocuments()

        return snapshot.documents.first.flatMap { try? $0.data(as: PostWorkoutInsight.self) }
    }
}
