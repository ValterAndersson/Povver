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

/// Wrapper that fetches the archived workout from Firestore and presents WorkoutSummaryContent.
/// The doc is locally cached (just written by completeActiveWorkout), so fetch is near-instant.
struct WorkoutCompletionSummary: View {
    let workoutId: String
    let onDismiss: () -> Void

    @State private var workout: Workout?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: Space.lg) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading summary...")
                            .font(.system(size: 15))
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let workout = workout {
                    WorkoutSummaryContent(workout: workout)
                } else {
                    VStack(spacing: Space.md) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(Color.accent)
                        Text("Workout Complete")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.bg)
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .task {
            await loadWorkout()
        }
    }

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
            .confirmationDialog("Finish Workout?", isPresented: $showingCompleteConfirmation) {
                Button("Complete Workout") { onFinish() }
                Button("Keep Logging", role: .cancel) { }
            }
            .alert("Workout Name", isPresented: $showingNameEditor) {
                TextField("Name", text: $editingName)
                Button("Save") { onUpdateName(editingName) }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Discard Workout?", isPresented: $showingCancelConfirmation) {
                Button("Keep Logging", role: .cancel) { }
                Button("Discard", role: .destructive) { onDiscard() }
            } message: {
                Text("Your progress will not be saved.")
            }
            .alert("Active Workout Found", isPresented: $showingResumeGate) {
                Button("Resume Workout") { onResume() }
                Button("Discard and Start New", role: .destructive) { onDiscardAndStartNew() }
            } message: {
                Text("You have an active workout in progress. Would you like to resume or start fresh?")
            }
    }
}
