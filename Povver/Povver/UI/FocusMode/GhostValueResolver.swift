/**
 * GhostValueResolver.swift
 *
 * Pure logic for resolving ghost values — what to display in undone sets at 40% opacity.
 * When the user taps "done" on a set showing ghost values, those values become the actuals.
 *
 * Resolution priority:
 *   1. Last session data (matched by set index within the exercise)
 *   2. Template prescription (targetWeight / targetReps / targetRir)
 *   3. Blank (no ghost values)
 *
 * Sets that already have user-entered actual values are skipped (no ghost needed).
 * Done sets are excluded entirely — they already show their actual values.
 */

import Foundation

// MARK: - Ghost Values

/// Resolved ghost values for an undone set.
/// Display at 40% opacity. Tapping done accepts all ghost values as actuals.
struct GhostValues: Equatable {
    let weight: Double?
    let reps: Int?
    let rir: Int?

    var hasValues: Bool { weight != nil || reps != nil || rir != nil }
    static let empty = GhostValues(weight: nil, reps: nil, rir: nil)
}

// MARK: - Last Session Data

/// Per-exercise data from the most recent completed workout containing this exercise.
/// Populated from the set_facts Firestore subcollection.
struct LastSessionExerciseData {
    let sets: [LastSessionSetData]
}

/// Per-set data from a previous session, used as ghost value source.
struct LastSessionSetData {
    let weight: Double?
    let reps: Int?
    let rir: Int?
}

// MARK: - Resolver

/// Resolves ghost values for undone sets within an exercise.
/// Priority: last session for this exercise > template prescription (targetWeight/Reps/Rir) > blank
enum GhostValueResolver {

    /// Resolve ghost values for all undone sets in the given exercise.
    /// - Parameters:
    ///   - exercise: The current exercise with its sets.
    ///   - lastSession: Optional last session data for this exercise (keyed by exerciseId externally).
    /// - Returns: Dictionary mapping set ID to resolved ghost values. Done sets are not included.
    static func resolve(
        exercise: FocusModeExercise,
        lastSession: LastSessionExerciseData?
    ) -> [String: GhostValues] {
        var result: [String: GhostValues] = [:]
        let undoneSets = exercise.sets.enumerated().filter { !$0.element.isDone }

        for (index, set) in undoneSets {
            // Skip sets that already have user-entered actual values
            if set.weight != nil || (set.reps ?? 0) > 0 {
                result[set.id] = .empty
                continue
            }

            // Priority 1: Last session (matched by set index within the exercise)
            if let lastSession, index < lastSession.sets.count {
                let lastSet = lastSession.sets[index]
                result[set.id] = GhostValues(weight: lastSet.weight, reps: lastSet.reps, rir: lastSet.rir)
                continue
            }

            // Priority 2: Template prescription fields (targetWeight/Reps/Rir)
            if set.targetWeight != nil || set.targetReps != nil || set.targetRir != nil {
                result[set.id] = GhostValues(weight: set.targetWeight, reps: set.targetReps, rir: set.targetRir)
                continue
            }

            // Priority 3: Blank
            result[set.id] = .empty
        }
        return result
    }
}
