import Foundation
import FirebaseFirestore

// MARK: - Weekly Review (users/{uid}/weekly_reviews/{weekId})
// Document ID is YYYY-WNN format. TTL: 30 days.
// Written by Training Analyst after weekly progression analysis.

struct WeeklyReview: Codable, Identifiable {
    @DocumentID var id: String?
    let weekEnding: String?
    let summary: String?
    let trainingLoad: TrainingLoad?
    let muscleBalance: [MuscleBalanceEntry]?
    let exerciseTrends: [ExerciseTrend]?
    let progressionCandidates: [ProgressionCandidate]?
    let stalledExercises: [StalledExercise]?
    let periodization: Periodization?
    let routineRecommendations: [RoutineRecommendation]?
    let fatigueStatus: FatigueStatus?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case weekEnding = "week_ending"
        case summary
        case trainingLoad = "training_load"
        case muscleBalance = "muscle_balance"
        case exerciseTrends = "exercise_trends"
        case progressionCandidates = "progression_candidates"
        case stalledExercises = "stalled_exercises"
        case periodization
        case routineRecommendations = "routine_recommendations"
        case fatigueStatus = "fatigue_status"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(DocumentID<String>.self, forKey: .id)
        weekEnding = try container.decodeIfPresent(String.self, forKey: .weekEnding)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        trainingLoad = try container.decodeIfPresent(TrainingLoad.self, forKey: .trainingLoad)
        muscleBalance = try container.decodeIfPresent([MuscleBalanceEntry].self, forKey: .muscleBalance)
        exerciseTrends = try container.decodeIfPresent([ExerciseTrend].self, forKey: .exerciseTrends)
        progressionCandidates = try container.decodeIfPresent([ProgressionCandidate].self, forKey: .progressionCandidates)
        stalledExercises = try container.decodeIfPresent([StalledExercise].self, forKey: .stalledExercises)
        periodization = try container.decodeIfPresent(Periodization.self, forKey: .periodization)
        routineRecommendations = try container.decodeIfPresent([RoutineRecommendation].self, forKey: .routineRecommendations)
        fatigueStatus = try container.decodeIfPresent(FatigueStatus.self, forKey: .fatigueStatus)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    struct TrainingLoad: Codable {
        let sessions: Int?
        let totalSets: Int?
        let totalVolume: Double?
        let acwr: Double?
        let vsLastWeek: WeekComparison?

        enum CodingKeys: String, CodingKey {
            case sessions
            case totalSets = "total_sets"
            case totalVolume = "total_volume"
            case acwr
            case vsLastWeek = "vs_last_week"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decodeIfPresent(Int.self, forKey: .sessions)
            totalSets = try container.decodeIfPresent(Int.self, forKey: .totalSets)
            totalVolume = try container.decodeIfPresent(Double.self, forKey: .totalVolume)
            acwr = try container.decodeIfPresent(Double.self, forKey: .acwr)
            vsLastWeek = try container.decodeIfPresent(WeekComparison.self, forKey: .vsLastWeek)
        }
    }

    struct WeekComparison: Codable {
        let setsDelta: Int?
        let volumeDelta: Double?

        enum CodingKeys: String, CodingKey {
            case setsDelta = "sets_delta"
            case volumeDelta = "volume_delta"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            setsDelta = try container.decodeIfPresent(Int.self, forKey: .setsDelta)
            volumeDelta = try container.decodeIfPresent(Double.self, forKey: .volumeDelta)
        }
    }

    struct MuscleBalanceEntry: Codable {
        let muscleGroup: String?
        let weeklySets: Int?
        let trend: String?
        let status: String?

        enum CodingKeys: String, CodingKey {
            case muscleGroup = "muscle_group"
            case weeklySets = "weekly_sets"
            case trend
            case status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            muscleGroup = try container.decodeIfPresent(String.self, forKey: .muscleGroup)
            weeklySets = try container.decodeIfPresent(Int.self, forKey: .weeklySets)
            trend = try container.decodeIfPresent(String.self, forKey: .trend)
            status = try container.decodeIfPresent(String.self, forKey: .status)
        }
    }

    struct ExerciseTrend: Codable {
        let exerciseName: String?
        let trend: String?
        let e1rmSlope: Double?
        let note: String?

        enum CodingKeys: String, CodingKey {
            case exerciseName = "exercise_name"
            case trend
            case e1rmSlope = "e1rm_slope"
            case note
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exerciseName = try container.decodeIfPresent(String.self, forKey: .exerciseName)
            trend = try container.decodeIfPresent(String.self, forKey: .trend)
            e1rmSlope = try container.decodeIfPresent(Double.self, forKey: .e1rmSlope)
            note = try container.decodeIfPresent(String.self, forKey: .note)
        }
    }

    struct ProgressionCandidate: Codable {
        let exerciseName: String?
        let currentWeight: Double?
        let suggestedWeight: Double?
        let rationale: String?
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case exerciseName = "exercise_name"
            case currentWeight = "current_weight"
            case suggestedWeight = "suggested_weight"
            case rationale
            case confidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exerciseName = try container.decodeIfPresent(String.self, forKey: .exerciseName)
            currentWeight = try container.decodeIfPresent(Double.self, forKey: .currentWeight)
            suggestedWeight = try container.decodeIfPresent(Double.self, forKey: .suggestedWeight)
            rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        }
    }

    struct StalledExercise: Codable {
        let exerciseName: String?
        let weeksStalled: Int?
        let suggestedAction: String?
        let rationale: String?

        enum CodingKeys: String, CodingKey {
            case exerciseName = "exercise_name"
            case weeksStalled = "weeks_stalled"
            case suggestedAction = "suggested_action"
            case rationale
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exerciseName = try container.decodeIfPresent(String.self, forKey: .exerciseName)
            weeksStalled = try container.decodeIfPresent(Int.self, forKey: .weeksStalled)
            suggestedAction = try container.decodeIfPresent(String.self, forKey: .suggestedAction)
            rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        }
    }

    struct Periodization: Codable {
        let currentPhase: String?
        let weeksInPhase: Int?
        let suggestion: String?
        let reasoning: String?

        enum CodingKeys: String, CodingKey {
            case currentPhase = "current_phase"
            case weeksInPhase = "weeks_in_phase"
            case suggestion
            case reasoning
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentPhase = try container.decodeIfPresent(String.self, forKey: .currentPhase)
            weeksInPhase = try container.decodeIfPresent(Int.self, forKey: .weeksInPhase)
            suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion)
            reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        }
    }

    struct RoutineRecommendation: Codable {
        let type: String?
        let target: String?
        let suggestion: String?
        let reasoning: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            target = try container.decodeIfPresent(String.self, forKey: .target)
            suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion)
            reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        }
    }

    struct FatigueStatus: Codable {
        let overallAcwr: Double?
        let interpretation: String?
        let flags: [String]?
        let recommendation: String?

        enum CodingKeys: String, CodingKey {
            case overallAcwr = "overall_acwr"
            case interpretation
            case flags
            case recommendation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            overallAcwr = try container.decodeIfPresent(Double.self, forKey: .overallAcwr)
            interpretation = try container.decodeIfPresent(String.self, forKey: .interpretation)
            flags = try container.decodeIfPresent([String].self, forKey: .flags)
            recommendation = try container.decodeIfPresent(String.self, forKey: .recommendation)
        }
    }
}

// MARK: - Post-Workout Insight (users/{uid}/analysis_insights/{id})
// Named PostWorkoutInsight to avoid collision with the canvas AnalysisInsight in Models.swift.
// Maps to the Firestore analysis_insights collection. TTL: 7 days.
// Written by Training Analyst after each workout completion.

struct PostWorkoutInsight: Codable, Identifiable {
    @DocumentID var id: String?
    let type: String?
    let workoutId: String?
    let workoutDate: String?
    let summary: String?
    let highlights: [Highlight]?
    let flags: [Flag]?
    let recommendations: [InsightRecommendation]?
    let templateDiffSummary: String?
    let createdAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case workoutId = "workout_id"
        case workoutDate = "workout_date"
        case summary
        case highlights
        case flags
        case recommendations
        case templateDiffSummary = "template_diff_summary"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(DocumentID<String>.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        workoutId = try container.decodeIfPresent(String.self, forKey: .workoutId)
        workoutDate = try container.decodeIfPresent(String.self, forKey: .workoutDate)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        highlights = try container.decodeIfPresent([Highlight].self, forKey: .highlights)
        flags = try container.decodeIfPresent([Flag].self, forKey: .flags)
        recommendations = try container.decodeIfPresent([InsightRecommendation].self, forKey: .recommendations)
        templateDiffSummary = try container.decodeIfPresent(String.self, forKey: .templateDiffSummary)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    struct Highlight: Codable {
        let type: String?
        let message: String?
        let exerciseId: String?

        enum CodingKeys: String, CodingKey {
            case type
            case message
            case exerciseId = "exercise_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            exerciseId = try container.decodeIfPresent(String.self, forKey: .exerciseId)
        }
    }

    struct Flag: Codable {
        let type: String?
        let severity: String?
        let message: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            severity = try container.decodeIfPresent(String.self, forKey: .severity)
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }
    }

    struct InsightRecommendation: Codable {
        let type: String?
        let target: String?
        let action: String?
        let confidence: Double?
        let suggestedWeight: Double?
        let targetReps: Int?
        let setsDelta: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case target
            case action
            case confidence
            case suggestedWeight = "suggested_weight"
            case targetReps = "target_reps"
            case setsDelta = "sets_delta"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            target = try container.decodeIfPresent(String.self, forKey: .target)
            action = try container.decodeIfPresent(String.self, forKey: .action)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            suggestedWeight = try container.decodeIfPresent(Double.self, forKey: .suggestedWeight)
            targetReps = try container.decodeIfPresent(Int.self, forKey: .targetReps)
            setsDelta = try container.decodeIfPresent(Int.self, forKey: .setsDelta)
        }
    }
}

// MARK: - Analytics Rollup (users/{uid}/analytics_rollups/{periodId})
// Weekly/monthly compact rollups keyed by yyyy-ww or yyyy-mm.

struct AnalyticsRollup: Codable, Identifiable {
    @DocumentID var id: String?
    let workouts: Int?
    let totalSets: Int?
    let totalReps: Int?
    let totalWeight: Double?
    let weightPerMuscleGroup: [String: Double]?
    let hardSetsTotal: Int?
    let lowRirSetsTotal: Int?
    let hardSetsPerMuscle: [String: Double]?
    let lowRirSetsPerMuscle: [String: Double]?
    let loadPerMuscle: [String: Double]?
    let hardSetsPerMuscleGroup: [String: Double]?
    let lowRirSetsPerMuscleGroup: [String: Double]?
    let loadPerMuscleGroup: [String: Double]?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workouts
        case totalSets = "total_sets"
        case totalReps = "total_reps"
        case totalWeight = "total_weight"
        case weightPerMuscleGroup = "weight_per_muscle_group"
        case hardSetsTotal = "hard_sets_total"
        case lowRirSetsTotal = "low_rir_sets_total"
        case hardSetsPerMuscle = "hard_sets_per_muscle"
        case lowRirSetsPerMuscle = "low_rir_sets_per_muscle"
        case loadPerMuscle = "load_per_muscle"
        case hardSetsPerMuscleGroup = "hard_sets_per_muscle_group"
        case lowRirSetsPerMuscleGroup = "low_rir_sets_per_muscle_group"
        case loadPerMuscleGroup = "load_per_muscle_group"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(DocumentID<String>.self, forKey: .id)
        workouts = try container.decodeIfPresent(Int.self, forKey: .workouts)
        totalSets = try container.decodeIfPresent(Int.self, forKey: .totalSets)
        totalReps = try container.decodeIfPresent(Int.self, forKey: .totalReps)
        totalWeight = try container.decodeIfPresent(Double.self, forKey: .totalWeight)
        weightPerMuscleGroup = try container.decodeIfPresent([String: Double].self, forKey: .weightPerMuscleGroup)
        hardSetsTotal = try container.decodeIfPresent(Int.self, forKey: .hardSetsTotal)
        lowRirSetsTotal = try container.decodeIfPresent(Int.self, forKey: .lowRirSetsTotal)
        hardSetsPerMuscle = try container.decodeIfPresent([String: Double].self, forKey: .hardSetsPerMuscle)
        lowRirSetsPerMuscle = try container.decodeIfPresent([String: Double].self, forKey: .lowRirSetsPerMuscle)
        loadPerMuscle = try container.decodeIfPresent([String: Double].self, forKey: .loadPerMuscle)
        hardSetsPerMuscleGroup = try container.decodeIfPresent([String: Double].self, forKey: .hardSetsPerMuscleGroup)
        lowRirSetsPerMuscleGroup = try container.decodeIfPresent([String: Double].self, forKey: .lowRirSetsPerMuscleGroup)
        loadPerMuscleGroup = try container.decodeIfPresent([String: Double].self, forKey: .loadPerMuscleGroup)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Composed Types for View Consumption

/// Snapshot of training state for dashboard display.
/// Composed from the latest WeeklyReview, AnalyticsRollup, and PostWorkoutInsight.
struct TrainingSnapshot {
    let weeklyReview: WeeklyReview?
    let latestInsight: PostWorkoutInsight?
    let currentWeekRollup: AnalyticsRollup?

    var workoutsThisWeek: Int {
        currentWeekRollup?.workouts ?? weeklyReview?.trainingLoad?.sessions ?? 0
    }

    var totalVolumeThisWeek: Double {
        currentWeekRollup?.totalWeight ?? weeklyReview?.trainingLoad?.totalVolume ?? 0
    }

    var fatigueInterpretation: String? {
        weeklyReview?.fatigueStatus?.interpretation
    }

    var acwr: Double? {
        weeklyReview?.fatigueStatus?.overallAcwr ?? weeklyReview?.trainingLoad?.acwr
    }
}

/// Weekly workout count for trend chart and consistency map display.
/// Shape matches TrainingConsistencyMap expectations.
struct WeekWorkoutCount: Identifiable {
    let id: String
    let weekId: String
    let scheduledCount: Int
    let completedCount: Int

    init(weekId: String, scheduledCount: Int, completedCount: Int) {
        self.id = weekId
        self.weekId = weekId
        self.scheduledCount = scheduledCount
        self.completedCount = completedCount
    }
}

/// Post-workout summary for display after completing a workout.
struct PostWorkoutSummary {
    let insight: PostWorkoutInsight

    var summary: String {
        insight.summary ?? ""
    }

    var highlightMessages: [String] {
        insight.highlights?.compactMap(\.message) ?? []
    }

    var flagMessages: [String] {
        insight.flags?.compactMap(\.message) ?? []
    }

    var hasProgressionRecommendations: Bool {
        insight.recommendations?.contains(where: { $0.type == "progression" }) ?? false
    }
}

/// A notable training milestone derived from insights or weekly reviews.
struct Milestone: Identifiable {
    let id: String
    let type: String // "pr", "volume_up", "consistency", "intensity"
    let message: String
    let date: Date?
}
