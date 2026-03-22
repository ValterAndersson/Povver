/**
 * FocusModeWorkoutHelpers.swift
 *
 * Supporting types for the workout execution screen.
 * Extracted from FocusModeWorkoutScreen.swift to reduce file size.
 *
 * Contains:
 * - CompletedWorkoutRef: Identifiable wrapper for fullScreenCover navigation
 * - WorkoutCompletionSummary: Post-workout summary view
 * - WorkoutAlertsModifier: Extracted alert/confirmation dialogs
 */

import SwiftUI

// MARK: - Workout Completion Summary

/// Identifiable wrapper for the archived workout ID, used by `.fullScreenCover(item:)`.
struct CompletedWorkoutRef: Identifiable {
    let id: String
}

/// Wrapper that fetches the archived workout from Firestore and presents a sequenced
/// completion summary with coach presence, core metrics, and the full WorkoutSummaryContent.
/// The doc is locally cached (just written by completeActiveWorkout), so fetch is near-instant.
struct WorkoutCompletionSummary: View {
    let workoutId: String
    let onDismiss: () -> Void

    @State private var workout: Workout?
    @State private var isLoading = true
    @State private var revealPhase = 0
    @State private var weeklyWorkoutCounts: [WeekWorkoutCount] = []
    @State private var routineFrequency: Int = 4
    @State private var coachReflection: String? = nil

    private var weightUnit: WeightUnit { UserService.shared.weightUnit }

    private var durationMinutes: Int {
        guard let w = workout else { return 0 }
        return Int(w.endTime.timeIntervalSince(w.startTime) / 60)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: Space.lg) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading summary...")
                            .textStyle(.secondary)
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let workout = workout {
                    ScrollView {
                        VStack(spacing: Space.xl) {
                            // Phase 0: Coach presence indicator
                            CoachPresenceIndicator(size: 48)
                                .opacity(revealPhase >= 0 ? 1 : 0)
                                .offset(y: revealPhase >= 0 ? 0 : 8)
                                .animation(MotionToken.gentle, value: revealPhase)
                                .padding(.top, Space.xl)

                            // Phase 1: Headline + workout name
                            VStack(spacing: Space.xs) {
                                Text("Session Complete")
                                    .textStyle(.screenTitle)
                                    .foregroundColor(Color.textPrimary)
                                Text(workout.displayName)
                                    .textStyle(.secondary)
                                    .foregroundColor(Color.textSecondary)
                            }
                            .opacity(revealPhase >= 1 ? 1 : 0)
                            .offset(y: revealPhase >= 1 ? 0 : 8)
                            .animation(MotionToken.gentle, value: revealPhase)

                            // Phase 2: Core metrics row
                            HStack(spacing: 0) {
                                metricBlock(
                                    value: "\(durationMinutes)",
                                    label: "MIN"
                                )
                                metricBlock(
                                    value: formatVolume(workout.analytics.totalWeight),
                                    label: "VOLUME (\(weightUnit.label))"
                                )
                                metricBlock(
                                    value: "\(workout.analytics.totalSets)",
                                    label: "SETS"
                                )
                            }
                            .padding(.horizontal, Space.lg)
                            .opacity(revealPhase >= 2 ? 1 : 0)
                            .offset(y: revealPhase >= 2 ? 0 : 8)
                            .animation(MotionToken.gentle, value: revealPhase)

                            // Phase 3: Exercise count summary
                            Text("\(workout.exercises.count) exercise\(workout.exercises.count == 1 ? "" : "s") completed")
                                .textStyle(.secondary)
                                .foregroundColor(Color.textSecondary)
                                .opacity(revealPhase >= 3 ? 1 : 0)
                                .offset(y: revealPhase >= 3 ? 0 : 8)
                                .animation(MotionToken.gentle, value: revealPhase)

                            // Phase 4: Consistency Map with animated fill
                            if !weeklyWorkoutCounts.isEmpty {
                                TrainingConsistencyMap(
                                    weeks: weeklyWorkoutCounts,
                                    routineFrequency: routineFrequency
                                )
                                .padding(.horizontal, Space.lg)
                                .opacity(revealPhase >= 4 ? 1 : 0)
                                .offset(y: revealPhase >= 4 ? 0 : 8)
                                .animation(MotionToken.bouncy, value: revealPhase)
                            }

                            // Phase 5: Full workout detail (reuse existing component)
                            WorkoutSummaryContent(workout: workout)
                                .opacity(revealPhase >= 5 ? 1 : 0)
                                .offset(y: revealPhase >= 5 ? 0 : 8)
                                .animation(MotionToken.gentle, value: revealPhase)

                            // Coach reflection (if available)
                            if let reflection = coachReflection, !reflection.isEmpty {
                                VStack(spacing: Space.sm) {
                                    CoachPresenceIndicator(size: 24)
                                    Text(reflection)
                                        .textStyle(.secondary)
                                        .foregroundStyle(Color.textSecondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, Space.lg)
                                }
                                .padding(.top, Space.md)
                                .opacity(revealPhase >= 6 ? 1 : 0)
                                .offset(y: revealPhase >= 6 ? 0 : 8)
                                .animation(MotionToken.gentle, value: revealPhase)
                            }
                        }
                    }
                } else {
                    VStack(spacing: Space.md) {
                        CoachPresenceIndicator(size: 48)
                        Text("Workout Complete")
                            .textStyle(.screenTitle)
                            .foregroundColor(Color.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                    .opacity(revealPhase >= 4 ? 1 : 0)
                    .animation(MotionToken.gentle, value: revealPhase)
                }
            }
        }
        .task {
            await loadWorkout()
        }
    }

    // MARK: - Metric Block

    private func metricBlock(value: String, label: String) -> some View {
        VStack(spacing: Space.xxs) {
            Text(value)
                .textStyle(.metricL)
                .foregroundColor(Color.textPrimary)
            Text(label)
                .textStyle(.micro)
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func formatVolume(_ weight: Double) -> String {
        let displayed = WeightFormatter.display(weight, unit: weightUnit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    // MARK: - Data Loading

    private func loadWorkout() async {
        guard let userId = AuthService.shared.currentUser?.uid else {
            isLoading = false
            return
        }
        do {
            workout = try await WorkoutRepository().getWorkout(id: workoutId, userId: userId)
        } catch {
            print("[WorkoutCompletionSummary] Failed to load workout: \(error)")
        }
        isLoading = false

        guard let w = workout else { return }

        // Haptic feedback for workout completion
        HapticManager.workoutCompleted()

        // Set post-workout flag so Coach tab shows post-workout state
        CoachTabViewModel.setPostWorkoutFlag(
            workoutId: w.id,
            name: w.displayName,
            exerciseCount: w.exercises.count,
            setCount: w.analytics.totalSets,
            totalVolume: w.analytics.totalWeight
        )

        // Load consistency map data
        let trainingService = TrainingDataService.shared
        weeklyWorkoutCounts = (try? await trainingService.fetchWeeklyWorkoutCounts(weeks: 12)) ?? []

        // Load coach reflection from post-workout summary
        if let summary = try? await trainingService.fetchPostWorkoutSummary(workoutId: workoutId) {
            coachReflection = summary.summary
        }

        // Sequenced reveal: stagger each phase for a polished entrance.
        // Runs in a Task tied to the .task modifier, so it cancels automatically on disappear.
        await startRevealSequence()
    }

    /// Sequenced reveal animation using structured concurrency.
    /// Automatically cancelled when the parent .task is torn down (view disappears).
    private func startRevealSequence() async {
        let phaseDelays: [Duration] = [
            .milliseconds(100),  // phase 1
            .milliseconds(200),  // phase 2 (cumulative 0.3s)
            .milliseconds(200),  // phase 3 (cumulative 0.5s)
            .milliseconds(200),  // phase 4 (cumulative 0.7s)
            .milliseconds(300),  // phase 5 (cumulative 1.0s)
            .milliseconds(200),  // phase 6 (cumulative 1.2s)
        ]
        for (index, delay) in phaseDelays.enumerated() {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation { revealPhase = index + 1 }
        }
    }
}

// MARK: - Alerts Modifier (extracted to help Swift type checker)

struct WorkoutAlertsModifier: ViewModifier {
    @Binding var showingCompleteConfirmation: Bool
    @Binding var showingNameEditor: Bool
    @Binding var editingName: String
    @Binding var showingCancelConfirmation: Bool
    @Binding var showingResumeGate: Bool
    var onFinish: () -> Void
    var onUpdateName: (String) -> Void
    var onDiscard: () -> Void
    var onResume: () -> Void
    var onDiscardAndStartNew: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Finish this workout?", isPresented: $showingCompleteConfirmation) {
                Button("Finish") {
                    HapticManager.destructiveAction()
                    onFinish()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your workout will be saved and you'll see a summary.")
            }
            .alert("Workout Name", isPresented: $showingNameEditor) {
                TextField("Name", text: $editingName)
                Button("Save") { onUpdateName(editingName) }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Discard this workout?", isPresented: $showingCancelConfirmation) {
                Button("Discard", role: .destructive) {
                    HapticManager.destructiveAction()
                    onDiscard()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your sets and progress from this session won't be saved.")
            }
            .alert("Active Workout Found", isPresented: $showingResumeGate) {
                Button("Resume Workout") { onResume() }
                Button("Discard and Start New", role: .destructive) {
                    HapticManager.destructiveAction()
                    onDiscardAndStartNew()
                }
            } message: {
                Text("You have an active workout in progress. Would you like to resume or start fresh?")
            }
    }
}
