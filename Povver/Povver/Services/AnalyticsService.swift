import Foundation
import FirebaseAnalytics

// MARK: - Analytics Enums

/// Constrained parameter types to prevent typos and ensure consistency across call sites.

enum AnalyticsAuthProvider: String {
    case email, google, apple
}

enum AnalyticsWorkoutSource: String {
    case nextScheduled = "next_scheduled"
    case template
    case empty
}

enum AnalyticsSetLoggedVia: String {
    case manual, autofill, doneTap = "done_tap", coach
}

enum AnalyticsArtifactAction: String {
    case accept, dismiss
    case startWorkout = "start_workout"
    case saveAsTemplate = "save_as_template"
    case saveRoutine = "save_routine"
    case adjustPlan = "adjust_plan"
    case swapExercise = "swap_exercise"
    case learnMore = "learn_more"
}

enum AnalyticsLibrarySection: String {
    case routines, templates, exercises
}

enum AnalyticsTab: String {
    case coach, train, library, history, profile
}

enum AnalyticsQuickAction: String {
    case planProgram = "plan_program"
    case analyzeProgress = "analyze_progress"
    case createRoutine = "create_routine"
    case reviewPlan = "review_plan"
}

enum AnalyticsConversationEntryPoint: String {
    case quickAction = "quick_action"
    case freeform
    case recentChat = "recent_chat"
    case artifactStartWorkout = "artifact_start_workout"
    case existingCanvas = "existing_canvas"
}

enum AnalyticsRecommendationType: String {
    case progression, deload
    case muscleBalance = "muscle_balance"
    case repProgression = "rep_progression"
    case intensityAdjust = "intensity_adjust"
}

enum AnalyticsRecommendationScope: String {
    case template, exercise, routine
}

enum AnalyticsPaywallTrigger: String {
    case aiGate = "ai_gate"
    case recommendationGate = "recommendation_gate"
    case profileUpgrade = "profile_upgrade"
    case streamingPremiumGate = "streaming_premium_gate"
    case serverPremiumGate = "server_premium_gate"
}

enum AnalyticsPremiumGateType: String {
    case client, server
}

enum AnalyticsExerciseModSource: String {
    case search, coach, menu
}

enum AnalyticsStreamingErrorContext: String {
    case coach, workoutCoach = "workout_coach"
}

// MARK: - Parameter Structs

/// Used for workout_completed to keep call sites clean.
struct WorkoutCompletedParams {
    let workoutId: String
    let durationMin: Int
    let exerciseCount: Int
    let totalSets: Int
    let setsCompleted: Int
    let source: AnalyticsWorkoutSource
    let templateId: String?
    let routineId: String?
}

/// Used for conversation_ended.
struct ConversationEndedParams {
    let conversationDepth: Int
    let artifactsReceived: Int
    let artifactsAccepted: Int
    let durationSec: Int
}

// MARK: - AnalyticsService

/// Thin wrapper around Firebase Analytics providing typed event methods.
/// Organized by domain. Milestone events fire once per install via UserDefaults guard.
/// User properties are persisted in UserDefaults and synced to GA4.
final class AnalyticsService {
    static let shared = AnalyticsService()
    private init() {}

    // MARK: - User Identity

    func setUserId(_ userId: String) {
        Analytics.setUserID(userId)
    }

    // =========================================================================
    // MARK: - Domain 1: Authentication
    // =========================================================================

    func signupStarted(provider: AnalyticsAuthProvider) {
        log("signup_started", params: ["provider": provider.rawValue])
    }

    func signupCompleted(provider: String) {
        log("signup_completed", params: ["provider": provider])
        setUserProperty("signup_provider", value: provider)
    }

    func loginCompleted(provider: AnalyticsAuthProvider) {
        log("login_completed", params: ["provider": provider.rawValue])
    }

    func ssoConfirmationShown(provider: AnalyticsAuthProvider) {
        log("sso_confirmation_shown", params: ["provider": provider.rawValue])
    }

    func ssoConfirmationCancelled(provider: AnalyticsAuthProvider) {
        log("sso_confirmation_cancelled", params: ["provider": provider.rawValue])
    }

    // =========================================================================
    // MARK: - Domain: Onboarding
    // =========================================================================

    func onboardingStepViewed(step: String) {
        log("onboarding_step_viewed", params: ["step": step])
    }

    func onboardingProfileCompleted(fitnessLevel: String, frequency: Int, equipment: String) {
        log("onboarding_profile_completed", params: [
            "fitness_level": fitnessLevel,
            "frequency": String(frequency),
            "equipment": equipment,
        ])
    }

    func onboardingTrialStarted() {
        log("onboarding_trial_started")
    }

    func onboardingSkippedToBasic() {
        log("onboarding_skipped_to_basic")
    }

    // Stubs — full implementation in Task 9
    func onboardingGenerationFailed() {
        log("onboarding_generation_failed")
    }

    func onboardingRoutineAutoSaved() {
        log("onboarding_routine_auto_saved")
    }

    func onboardingRoutineAutoSaveFailed() {
        log("onboarding_routine_auto_save_failed")
    }

    func onboardingCompleted(trialStarted: Bool, adjustWithCoach: Bool) {
        log("onboarding_completed", params: [
            "trial_started": String(trialStarted),
            "adjust_with_coach": String(adjustWithCoach),
        ])
    }

    // =========================================================================
    // MARK: - Domain 2: AI Coaching & Conversations
    // =========================================================================

    func quickActionTapped(action: AnalyticsQuickAction) {
        log("quick_action_tapped", params: ["action": action.rawValue])
    }

    func conversationStarted(entryPoint: String) {
        log("conversation_started", params: ["entry_point": entryPoint])
        incrementCounter("total_conversations")
    }

    func messageSent(messageLength: Int, conversationDepth: Int) {
        log("message_sent", params: [
            "message_length": messageLength,
            "conversation_depth": conversationDepth,
        ])
        logOnce("first_message_sent")
    }

    func artifactReceived(artifactType: String, conversationDepth: Int) {
        log("artifact_received", params: [
            "artifact_type": artifactType,
            "conversation_depth": conversationDepth,
        ])
        logOnce("first_artifact_received")
    }

    func artifactAction(action: String, artifactType: String) {
        log("artifact_action", params: [
            "action": action,
            "artifact_type": artifactType,
        ])
    }

    func conversationEnded(_ params: ConversationEndedParams) {
        log("conversation_ended", params: [
            "conversation_depth": params.conversationDepth,
            "artifacts_received": params.artifactsReceived,
            "artifacts_accepted": params.artifactsAccepted,
            "duration_sec": params.durationSec,
        ])
    }

    // =========================================================================
    // MARK: - Domain 3: Workout Execution
    // =========================================================================

    func workoutStartViewed(hasNextScheduled: Bool, templateCount: Int) {
        log("workout_start_viewed", params: [
            "has_next_scheduled": hasNextScheduled,
            "template_count": templateCount,
        ])
    }

    func workoutStarted(source: AnalyticsWorkoutSource, workoutId: String, templateId: String? = nil, routineId: String? = nil, plannedExerciseCount: Int) {
        var params: [String: Any] = [
            "source": source.rawValue,
            "workout_id": workoutId,
            "planned_exercise_count": plannedExerciseCount,
        ]
        if let templateId { params["template_id"] = templateId }
        if let routineId { params["routine_id"] = routineId }
        log("workout_started", params: params)
    }

    func workoutFirstSetLogged(workoutId: String, secondsToFirstSet: Int) {
        // Cap at 600 (10 min) — values above indicate stale/resumed workout
        let capped = min(secondsToFirstSet, 600)
        log("workout_first_set_logged", params: [
            "workout_id": workoutId,
            "seconds_to_first_set": capped,
        ])
    }

    func setLogged(workoutId: String, exercisePosition: Int, setIndex: Int, isWarmup: Bool, loggedVia: AnalyticsSetLoggedVia) {
        log("set_logged", params: [
            "workout_id": workoutId,
            "exercise_position": exercisePosition,
            "set_index": setIndex,
            "is_warmup": isWarmup,
            "logged_via": loggedVia.rawValue,
        ])
    }

    func exerciseAdded(workoutId: String, source: AnalyticsExerciseModSource) {
        log("exercise_added", params: [
            "workout_id": workoutId,
            "source": source.rawValue,
        ])
    }

    func exerciseRemoved(workoutId: String) {
        log("exercise_removed", params: ["workout_id": workoutId])
    }

    func exerciseSwapped(workoutId: String, source: AnalyticsExerciseModSource) {
        log("exercise_swapped", params: [
            "workout_id": workoutId,
            "source": source.rawValue,
        ])
    }

    func exerciseReordered(workoutId: String) {
        log("exercise_reordered", params: ["workout_id": workoutId])
    }

    func workoutCoachOpened(workoutId: String, elapsedMin: Int, setsLogged: Int) {
        log("workout_coach_opened", params: [
            "workout_id": workoutId,
            "elapsed_min": elapsedMin,
            "sets_logged": setsLogged,
        ])
    }

    func workoutCoachMsgSent(workoutId: String, messageLength: Int) {
        log("workout_coach_msg_sent", params: [
            "workout_id": workoutId,
            "message_length": messageLength,
        ])
    }

    func workoutCompleted(_ params: WorkoutCompletedParams) {
        log("workout_completed", params: [
            "workout_id": params.workoutId,
            "duration_min": params.durationMin,
            "exercise_count": params.exerciseCount,
            "total_sets": params.totalSets,
            "sets_completed": params.setsCompleted,
            "source": params.source.rawValue,
            "template_id": params.templateId ?? "",
            "routine_id": params.routineId ?? "",
        ])
        logOnce("first_workout_completed")
        incrementCounter("total_workouts")
    }

    func workoutCancelled(workoutId: String, durationMin: Int, setsCompleted: Int, totalSets: Int) {
        log("workout_cancelled", params: [
            "workout_id": workoutId,
            "duration_min": durationMin,
            "sets_completed": setsCompleted,
            "total_sets": totalSets,
        ])
    }

    // =========================================================================
    // MARK: - Domain 4: Library & Content
    // =========================================================================

    func librarySectionOpened(section: AnalyticsLibrarySection) {
        log("library_section_opened", params: ["section": section.rawValue])
    }

    func routineViewed(routineId: String, templateCount: Int) {
        log("routine_viewed", params: [
            "routine_id": routineId,
            "template_count": templateCount,
        ])
    }

    func routineEdited(routineId: String, editType: String) {
        log("routine_edited", params: [
            "routine_id": routineId,
            "edit_type": editType,
        ])
    }

    func templateViewed(templateId: String, exerciseCount: Int, source: String) {
        log("template_viewed", params: [
            "template_id": templateId,
            "exercise_count": exerciseCount,
            "source": source,
        ])
    }

    func templateEdited(templateId: String, editType: String) {
        log("template_edited", params: [
            "template_id": templateId,
            "edit_type": editType,
        ])
    }

    func exerciseSearched(hasQuery: Bool, filterCount: Int, resultCount: Int) {
        log("exercise_searched", params: [
            "has_query": hasQuery,
            "filter_count": filterCount,
            "result_count": resultCount,
        ])
    }

    func exerciseDetailViewed(exerciseId: String, source: String) {
        log("exercise_detail_viewed", params: [
            "exercise_id": exerciseId,
            "source": source,
        ])
    }

    // =========================================================================
    // MARK: - Domain 5: Recommendations
    // =========================================================================

    func activityViewed(pendingCount: Int) {
        log("activity_viewed", params: ["pending_count": pendingCount])
    }

    func recommendationViewed(type: String, scope: String) {
        log("recommendation_viewed", params: ["type": type, "scope": scope])
    }

    func recommendationAccepted(type: String, scope: String) {
        log("recommendation_accepted", params: ["type": type, "scope": scope])
    }

    func recommendationRejected(type: String, scope: String) {
        log("recommendation_rejected", params: ["type": type, "scope": scope])
    }

    func autoPilotToggled(enabled: Bool) {
        log("auto_pilot_toggled", params: ["enabled": enabled])
        setUserProperty("auto_pilot_enabled", value: enabled ? "true" : "false")
    }

    // =========================================================================
    // MARK: - Domain 6: Monetization
    // =========================================================================

    func premiumGateHit(feature: String, gateType: AnalyticsPremiumGateType) {
        log("premium_gate_hit", params: [
            "feature": feature,
            "gate_type": gateType.rawValue,
        ])
    }

    func paywallShown(trigger: String) {
        log("paywall_shown", params: ["trigger": trigger])
    }

    func paywallDismissed(trigger: String, timeOnScreenSec: Int) {
        log("paywall_dismissed", params: [
            "trigger": trigger,
            "time_on_screen_sec": timeOnScreenSec,
        ])
    }

    func trialStarted(productId: String) {
        log("trial_started", params: ["product_id": productId])
    }

    func subscriptionPurchased(productId: String, isFromTrial: Bool, value: Double, currency: String) {
        log("subscription_purchased", params: [
            "product_id": productId,
            "is_from_trial": isFromTrial,
            "value": value,
            "currency": currency,
        ])
    }

    func subscriptionRestored() {
        log("subscription_restored")
    }

    // =========================================================================
    // MARK: - Domain 7: History & Review
    // =========================================================================

    func workoutHistoryViewed(workoutId: String, daysAgo: Int) {
        log("workout_history_viewed", params: [
            "workout_id": workoutId,
            "days_ago": daysAgo,
        ])
    }

    func workoutHistoryEdited(workoutId: String, editType: String) {
        log("workout_history_edited", params: [
            "workout_id": workoutId,
            "edit_type": editType,
        ])
    }

    func workoutHistoryDeleted(workoutId: String, daysAgo: Int) {
        log("workout_history_deleted", params: [
            "workout_id": workoutId,
            "days_ago": daysAgo,
        ])
    }

    // =========================================================================
    // MARK: - Domain 8: Profile & Settings
    // =========================================================================

    func bodyMetricsUpdated(field: String) {
        log("body_metrics_updated", params: ["field": field])
    }

    func preferenceChanged(preference: String, value: String) {
        log("preference_changed", params: [
            "preference": preference,
            "value": value,
        ])
    }

    func accountDeleted() {
        log("account_deleted")
    }

    // =========================================================================
    // MARK: - Domain 9: App Lifecycle & Navigation
    // =========================================================================

    func appOpened() {
        log("app_opened")
        syncUserPropertiesIfNeeded()
    }

    func tabViewed(_ tab: String) {
        log("tab_viewed", params: ["tab": tab])
    }

    /// Deprecated: kept for 30-day transition period. Use domain-specific events instead.
    func screenViewed(_ screen: String) {
        log("screen_viewed", params: ["screen": screen])
    }

    func streamingError(errorCode: String, context: AnalyticsStreamingErrorContext? = nil) {
        var params: [String: Any] = ["error_code": errorCode]
        if let context { params["context"] = context.rawValue }
        log("streaming_error", params: params)
    }

    // =========================================================================
    // MARK: - User Properties
    // =========================================================================

    /// Set a GA4 user property. All values must be strings per GA4 requirements.
    func setUserProperty(_ name: String, value: String) {
        Analytics.setUserProperty(value, forName: name)
        #if DEBUG
        print("[Analytics] setUserProperty \(name)=\(value)")
        #endif
    }

    /// Update subscription status user property.
    func updateSubscriptionStatus(_ status: String) {
        setUserProperty("subscription_status", value: status)
    }

    /// Update fitness level user property.
    func updateFitnessLevel(_ level: String) {
        setUserProperty("fitness_level", value: level)
    }

    /// Update has_active_routine user property.
    func updateHasActiveRoutine(_ hasActive: Bool) {
        setUserProperty("has_active_routine", value: hasActive ? "true" : "false")
    }

    /// Update install_source user property (called once on first app open).
    func updateInstallSource(_ source: String) {
        let key = "analytics_install_source_set"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setUserProperty("install_source", value: source)
    }

    /// Increment a UserDefaults-persisted counter and sync to GA4.
    func incrementCounter(_ property: String) {
        let key = "analytics_counter_\(property)"
        let current = UserDefaults.standard.integer(forKey: key)
        let next = current + 1
        UserDefaults.standard.set(next, forKey: key)
        setUserProperty(property, value: String(next))
    }

    /// Sync all user properties that need periodic recalculation.
    /// Called on app_opened, debounced to once per calendar day.
    func syncUserPropertiesIfNeeded() {
        let key = "analytics_last_sync_date"
        let todayString = Self.calendarDayString()
        let lastSync = UserDefaults.standard.string(forKey: key) ?? ""
        guard lastSync != todayString else { return }
        UserDefaults.standard.set(todayString, forKey: key)

        // Sync persisted counters
        let counterKeys = ["total_workouts", "total_conversations", "total_templates", "total_routines"]
        for prop in counterKeys {
            let val = UserDefaults.standard.integer(forKey: "analytics_counter_\(prop)")
            if val > 0 {
                setUserProperty(prop, value: String(val))
            }
        }

        // days_since_signup
        if let signupDate = UserDefaults.standard.object(forKey: "analytics_signup_date") as? Date {
            let days = Calendar.current.dateComponents([.day], from: signupDate, to: Date()).day ?? 0
            setUserProperty("days_since_signup", value: String(days))
        }

        // days_since_last_workout
        if let lastWorkoutDate = UserDefaults.standard.object(forKey: "analytics_last_workout_date") as? Date {
            let days = Calendar.current.dateComponents([.day], from: lastWorkoutDate, to: Date()).day ?? 0
            setUserProperty("days_since_last_workout", value: String(days))
        }

        // Calculated properties — only set after threshold data exists

        // workout_completion_rate: after 5+ workouts started
        let started = UserDefaults.standard.integer(forKey: "analytics_workouts_started")
        let completed = UserDefaults.standard.integer(forKey: "analytics_counter_total_workouts")
        if started >= 5 {
            let rate = Int(Double(completed) / Double(started) * 100)
            setUserProperty("workout_completion_rate", value: String(min(rate, 100)))
        }

        // avg_workout_duration_min: after 5+ completed workouts
        let totalDuration = UserDefaults.standard.integer(forKey: "analytics_total_workout_duration_min")
        if completed >= 5 {
            let avg = totalDuration / completed
            setUserProperty("avg_workout_duration_min", value: String(avg))
        }

        // primary_workout_source: mode of last N sources, after 5+ completed
        if completed >= 5 {
            if let sourcesData = UserDefaults.standard.data(forKey: "analytics_workout_sources"),
               let sources = try? JSONDecoder().decode([String].self, from: sourcesData) {
                let mode = Self.computeMode(sources)
                setUserProperty("primary_workout_source", value: mode)
            }
        }

        // coach_engagement_level: after 10+ sessions
        let appSessions = UserDefaults.standard.integer(forKey: "analytics_app_sessions")
        let newSessions = appSessions + 1
        UserDefaults.standard.set(newSessions, forKey: "analytics_app_sessions")
        if newSessions >= 10 {
            let convos = UserDefaults.standard.integer(forKey: "analytics_counter_total_conversations")
            let ratio = Double(convos) / Double(newSessions)
            let level: String
            if ratio == 0 { level = "none" }
            else if ratio < 0.2 { level = "low" }
            else if ratio < 0.5 { level = "medium" }
            else { level = "high" }
            setUserProperty("coach_engagement_level", value: level)
        }
    }

    /// Record signup date for days_since_signup calculation.
    func recordSignupDate() {
        UserDefaults.standard.set(Date(), forKey: "analytics_signup_date")
    }

    /// Record last workout date for days_since_last_workout calculation.
    func recordLastWorkoutDate() {
        UserDefaults.standard.set(Date(), forKey: "analytics_last_workout_date")
    }

    /// Record a workout start for completion rate calculation.
    func recordWorkoutStarted() {
        let key = "analytics_workouts_started"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    /// Record workout duration for avg_workout_duration_min calculation.
    func recordWorkoutDuration(_ durationMin: Int) {
        let key = "analytics_total_workout_duration_min"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + durationMin, forKey: key)
    }

    /// Record workout source for primary_workout_source calculation.
    func recordWorkoutSource(_ source: AnalyticsWorkoutSource) {
        let key = "analytics_workout_sources"
        var sources: [String] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let existing = try? JSONDecoder().decode([String].self, from: data) {
            sources = existing
        }
        sources.append(source.rawValue)
        // Keep last 20
        if sources.count > 20 { sources = Array(sources.suffix(20)) }
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // =========================================================================
    // MARK: - Private
    // =========================================================================

    private func log(_ name: String, params: [String: Any]? = nil) {
        Analytics.logEvent(name, parameters: params)
        #if DEBUG
        if let params = params {
            print("[Analytics] \(name): \(params)")
        } else {
            print("[Analytics] \(name)")
        }
        #endif
    }

    /// Fire a milestone event exactly once per app install.
    private func logOnce(_ name: String) {
        let key = "analytics_milestone_\(name)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        log(name)
    }

    /// Get today's date as a string for daily debounce.
    private static func calendarDayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Compute the mode (most frequent value) of an array of strings.
    private static func computeMode(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key ?? "empty"
    }
}
