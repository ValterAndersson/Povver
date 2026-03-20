import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - Coach State

enum CoachState: Equatable {
    case loading
    case newUser
    case workoutDay(WorkoutDayContext)
    case restDay(RestDayContext)
    case postWorkout(PostWorkoutContext)
    case returningAfterInactivity(InactivityContext)

    static func == (lhs: CoachState, rhs: CoachState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.newUser, .newUser): return true
        case (.workoutDay(let l), .workoutDay(let r)): return l.id == r.id
        case (.restDay(let l), .restDay(let r)): return l.id == r.id
        case (.postWorkout(let l), .postWorkout(let r)): return l.id == r.id
        case (.returningAfterInactivity(let l), .returningAfterInactivity(let r)): return l.id == r.id
        default: return false
        }
    }
}

// MARK: - Context Types

struct WorkoutDayContext {
    let id = UUID()
    let scheduledWorkoutName: String
    let dayLabel: String // "Day 3 of 4"
    let trainingLoadStatus: String? // "Optimal", "Building", etc.
    let snapshot: TrainingSnapshot
    let greeting: String
}

struct RestDayContext {
    let id = UUID()
    let insight: String?
    let snapshot: TrainingSnapshot
    let greeting: String
}

struct PostWorkoutContext {
    let id = UUID()
    let workoutName: String
    let exerciseCount: Int
    let setCount: Int
    let totalVolume: Double
    let summary: PostWorkoutSummary?
    let snapshot: TrainingSnapshot
}

struct InactivityContext {
    let id = UUID()
    let lastWorkoutDate: Date
    let daysSinceLastWorkout: Int
    let nextWorkoutName: String?
    let snapshot: TrainingSnapshot
}

// MARK: - Post-Workout Flag

/// Stored in UserDefaults after workout completion to trigger the post-workout state.
/// Expires after 4 hours so the Coach tab reverts to normal state.
struct PostWorkoutFlag: Codable {
    let workoutId: String
    let name: String
    let exerciseCount: Int
    let setCount: Int
    let totalVolume: Double
    let timestamp: Date
}

// MARK: - ViewModel

@MainActor
class CoachTabViewModel: ObservableObject {
    @Published var state: CoachState = .loading
    @Published var pendingMilestones: [Milestone] = []
    @Published var weeklyWorkoutCounts: [WeekWorkoutCount] = []
    @Published var routineFrequency: Int = 4
    @Published var recentConversations: [RecentConversation] = []
    @Published var hasLoadedConversations = false

    private let trainingService = TrainingDataService.shared
    private let workoutService = FocusModeWorkoutService.shared
    private var loadTask: Task<Void, Never>?

    private static let postWorkoutFlagKey = "postWorkoutFlag"
    /// 4 hours in seconds
    private static let postWorkoutTTL: TimeInterval = 14400

    deinit {
        loadTask?.cancel()
    }

    func load() async {
        loadTask?.cancel()
        let task = Task { @MainActor [trainingService, workoutService] in
            // 1. Post-workout takes priority — if the user just finished, show that state
            if let flag = self.loadPostWorkoutFlag() {
                let snapshot = (try? await trainingService.fetchTrainingSnapshot()) ?? self.emptySnapshot
                let summary = try? await trainingService.fetchPostWorkoutSummary(workoutId: flag.workoutId)
                self.state = .postWorkout(PostWorkoutContext(
                    workoutName: flag.name,
                    exerciseCount: flag.exerciseCount,
                    setCount: flag.setCount,
                    totalVolume: flag.totalVolume,
                    summary: summary,
                    snapshot: snapshot
                ))
                return
            }

            // 2. Must be authenticated to proceed
            guard let userId = Auth.auth().currentUser?.uid else {
                self.state = .newUser
                return
            }

            // 3. Gather data — workout count and next workout in parallel
            async let workoutCountTask = WorkoutRepository().getWorkoutCount(userId: userId)
            async let nextWorkoutTask = workoutService.getNextWorkout()

            let workoutCount = (try? await workoutCountTask) ?? 0
            let nextWorkout = try? await nextWorkoutTask

            let hasActiveRoutine = nextWorkout?.hasNextWorkout == true

            // 4. Brand-new user: no routine, no workout history
            if !hasActiveRoutine && workoutCount == 0 {
                self.state = .newUser
                return
            }

            // 5. Load training snapshot and weekly workout counts
            async let snapshotTask = trainingService.fetchTrainingSnapshot()
            async let weeklyCountsTask = trainingService.fetchWeeklyWorkoutCounts(weeks: 12)

            let snapshot = (try? await snapshotTask) ?? self.emptySnapshot
            self.weeklyWorkoutCounts = (try? await weeklyCountsTask) ?? []

            // Derive routine frequency from template count (sessions per week)
            if let next = nextWorkout, next.templateCount > 0 {
                self.routineFrequency = next.templateCount
            }

            // 6. Check milestones (consistency thresholds)
            self.pendingMilestones = trainingService.checkMilestones(workoutCount: workoutCount)

            // 7. Inactivity check — 7+ days since last workout
            // Note: Uses weeklyReview.createdAt (the analyst run date) as a proxy for last workout date.
            // The WeeklyReview has weekEnding (a String like "YYYY-WNN") but no parseable last-workout Date.
            // This is a best-available approximation; the analyst typically runs shortly after the last workout of the week.
            if let lastCompletedAt = snapshot.weeklyReview?.createdAt,
               let daysSince = Calendar.current.dateComponents([.day], from: lastCompletedAt, to: Date()).day,
               daysSince >= 7 {
                self.state = .returningAfterInactivity(InactivityContext(
                    lastWorkoutDate: lastCompletedAt,
                    daysSinceLastWorkout: daysSince,
                    nextWorkoutName: nextWorkout?.template?.name,
                    snapshot: snapshot
                ))
                return
            }

            // 8. Determine workout day vs rest day
            let greeting = self.timeAwareGreeting()

            if let next = nextWorkout, next.hasNextWorkout {
                let dayLabel: String
                if next.templateCount > 0 {
                    dayLabel = "Day \(next.templateIndex + 1) of \(next.templateCount)"
                } else {
                    dayLabel = ""
                }
                self.state = .workoutDay(WorkoutDayContext(
                    scheduledWorkoutName: next.template?.name ?? "Next Session",
                    dayLabel: dayLabel,
                    trainingLoadStatus: snapshot.fatigueInterpretation?.capitalized,
                    snapshot: snapshot,
                    greeting: greeting
                ))
            } else {
                self.state = .restDay(RestDayContext(
                    insight: snapshot.weeklyReview?.summary ?? snapshot.latestInsight?.summary,
                    snapshot: snapshot,
                    greeting: greeting
                ))
            }
        }
        loadTask = task
        await task.value
    }

    // MARK: - Post-Workout Flag Management

    static func setPostWorkoutFlag(
        workoutId: String,
        name: String,
        exerciseCount: Int,
        setCount: Int,
        totalVolume: Double
    ) {
        let flag = PostWorkoutFlag(
            workoutId: workoutId,
            name: name,
            exerciseCount: exerciseCount,
            setCount: setCount,
            totalVolume: totalVolume,
            timestamp: Date()
        )
        if let data = try? JSONEncoder().encode(flag) {
            UserDefaults.standard.set(data, forKey: postWorkoutFlagKey)
        }
    }

    static func clearPostWorkoutFlag() {
        UserDefaults.standard.removeObject(forKey: postWorkoutFlagKey)
    }

    func dismissPostWorkout() {
        Self.clearPostWorkoutFlag()
        Task { [weak self] in await self?.load() }
    }

    func acknowledgeMilestone(_ milestone: Milestone) {
        trainingService.acknowledgeMilestone(milestone)
        pendingMilestones.removeAll { $0.id == milestone.id }
    }

    // MARK: - Private Helpers

    private func timeAwareGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Afternoon session? Let's go"
        case 17..<22: return "Evening session — let's finish strong"
        default: return "Late session tonight"
        }
    }

    private var emptySnapshot: TrainingSnapshot {
        TrainingSnapshot(weeklyReview: nil, latestInsight: nil, currentWeekRollup: nil)
    }

    private func loadPostWorkoutFlag() -> PostWorkoutFlag? {
        guard let data = UserDefaults.standard.data(forKey: Self.postWorkoutFlagKey),
              let flag = try? JSONDecoder().decode(PostWorkoutFlag.self, from: data),
              Date().timeIntervalSince(flag.timestamp) < Self.postWorkoutTTL
        else {
            return nil
        }
        return flag
    }

    // MARK: - Recent Conversations

    func loadRecentConversations() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        db.collection("users").document(uid).collection("conversations")
            .whereField("status", isEqualTo: "active")
            .order(by: "updatedAt", descending: true)
            .limit(to: 5)
            .getDocuments { [weak self] snapshot, error in
                if let error = error {
                    AppLogger.shared.error(.store, "loadRecentConversations failed", error)
                }
                guard let docs = snapshot?.documents, error == nil else {
                    DispatchQueue.main.async { self?.hasLoadedConversations = true }
                    return
                }
                let conversations: [RecentConversation] = docs.compactMap { doc in
                    let data = doc.data()
                    let title = data["title"] as? String
                    let lastMessage = data["lastMessage"] as? String
                    let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
                    // Skip conversations that have never been messaged
                    guard lastMessage != nil || updatedAt != nil else { return nil }
                    return RecentConversation(
                        id: doc.documentID,
                        title: title,
                        lastMessage: lastMessage,
                        updatedAt: updatedAt,
                        createdAt: createdAt
                    )
                }
                DispatchQueue.main.async {
                    self?.recentConversations = conversations
                    self?.hasLoadedConversations = true
                }
            }
    }
}

// MARK: - Recent Conversation Model

struct RecentConversation: Identifiable {
    let id: String
    let title: String?
    let lastMessage: String?
    let updatedAt: Date?
    let createdAt: Date?
}
