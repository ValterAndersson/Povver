import SwiftUI

// MARK: - Set Cell Model (Render Model)

/// Unified render model for displaying a set row across all modes.
/// This is a pure UI adapter - it does not contain business logic.
/// Mode is NOT stored here; SetTable owns the mode.
struct SetCellModel: Identifiable, Equatable {
    typealias ID = String
    
    let id: ID
    
    /// Display label for set index (e.g., "1", "2", "W1" for warmup)
    let indexLabel: String
    
    // Display values (unitless - unit is rendered by SetTable header)
    let weight: String?    // e.g., "95" not "95kg"
    let reps: String?      // e.g., "8"
    let rir: String?       // e.g., "2" or nil for warmup
    let e1rm: String?      // e.g., "102" or nil for warmups/high-rep sets

    /// Set type indicator for visual badge (W=warmup, F=failure, D=drop)
    let setTypeIndicator: SetTypeIndicator?
    
    // State
    let isActive: Bool
    let isCompleted: Bool
    
    // MARK: - Set Type Indicator
    
    enum SetTypeIndicator: Equatable {
        case warmup
        case failure
        case drop
        
        var label: String {
            switch self {
            case .warmup: return "W"
            case .failure: return "F"
            case .drop: return "D"
            }
        }
        
        var color: Color {
            switch self {
            case .warmup: return Color.warning
            case .failure: return Color.destructive
            case .drop: return Color.accent
            }
        }
    }
}

// MARK: - WorkoutExerciseSet Mapper

extension WorkoutExerciseSet {
    /// Maps a history/completed set to SetCellModel for read-only display.
    /// Index label is passed in to avoid requiring the model to know its position.
    func toSetCellModel(indexLabel: String, weightUnit: WeightUnit) -> SetCellModel {
        let indicator = setTypeIndicator(from: type)
        let e1rmValue = computeE1RM(weightKg: weight, reps: reps, isWarmup: indicator == .warmup)

        return SetCellModel(
            id: id,
            indexLabel: indicator != nil ? indicator!.label : indexLabel,
            weight: formatWeight(weight, unit: weightUnit),
            reps: "\(reps)",
            rir: indicator == .warmup ? nil : rir.map { "\($0)" },
            e1rm: e1rmValue.map { WeightFormatter.formatValue($0, unit: weightUnit) },
            setTypeIndicator: indicator,
            isActive: false,
            isCompleted: isCompleted
        )
    }

    /// Epley e1RM: weight * (1 + reps/30). Only for non-warmup sets with reps <= 12.
    private func computeE1RM(weightKg: Double, reps: Int, isWarmup: Bool) -> Double? {
        guard !isWarmup, reps >= 1, reps <= 12, weightKg > 0 else { return nil }
        if reps == 1 { return weightKg }
        return weightKg * (1.0 + Double(reps) / 30.0)
    }

    private func setTypeIndicator(from type: String) -> SetCellModel.SetTypeIndicator? {
        let lowercased = type.lowercased()
        if lowercased.contains("warm") {
            return .warmup
        } else if lowercased.contains("fail") || lowercased.contains("amrap") {
            return .failure
        } else if lowercased.contains("drop") {
            return .drop
        }
        return nil
    }

    /// Convert stored kg value to display unit, then format as string
    private func formatWeight(_ weightKg: Double, unit: WeightUnit) -> String {
        let displayed = WeightFormatter.display(weightKg, unit: unit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        return WeightFormatter.truncateTrailingZeros(rounded)
    }
}

// MARK: - Array Helper for Building SetCellModels

extension Array where Element == WorkoutExerciseSet {
    /// Convert array of WorkoutExerciseSet to SetCellModels with proper index labels.
    /// Handles warmup vs working set numbering.
    func toSetCellModels(weightUnit: WeightUnit) -> [SetCellModel] {
        var warmupIndex = 0
        var workingIndex = 0

        return self.map { set in
            let indexLabel: String
            let lowercased = set.type.lowercased()

            if lowercased.contains("warm") {
                warmupIndex += 1
                indexLabel = "W\(warmupIndex)"
            } else {
                workingIndex += 1
                indexLabel = "\(workingIndex)"
            }

            return set.toSetCellModel(indexLabel: indexLabel, weightUnit: weightUnit)
        }
    }
}

// MARK: - WorkoutTemplateSet Mapper (Library/Templates)

extension WorkoutTemplateSet {
    /// Maps a template set to SetCellModel for display.
    /// Follows the same pattern as WorkoutExerciseSet mapper.
    func toSetCellModel(indexLabel: String, weightUnit: WeightUnit) -> SetCellModel {
        let indicator = setTypeIndicator(from: type)

        return SetCellModel(
            id: id,
            indexLabel: indicator != nil ? indicator!.label : indexLabel,
            weight: formatWeight(weight, unit: weightUnit),
            reps: "\(reps)",
            rir: indicator == .warmup ? nil : rir.map { "\($0)" },
            e1rm: nil,
            setTypeIndicator: indicator,
            isActive: false,
            isCompleted: false
        )
    }

    private func setTypeIndicator(from type: String) -> SetCellModel.SetTypeIndicator? {
        let lowercased = type.lowercased()
        if lowercased.contains("warm") {
            return .warmup
        } else if lowercased.contains("fail") || lowercased.contains("amrap") {
            return .failure
        } else if lowercased.contains("drop") {
            return .drop
        }
        return nil
    }

    /// Convert stored kg value to display unit, then format as string
    private func formatWeight(_ weightKg: Double, unit: WeightUnit) -> String {
        if weightKg == 0 { return "BW" }
        let displayed = WeightFormatter.display(weightKg, unit: unit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        return WeightFormatter.truncateTrailingZeros(rounded)
    }
}

extension Array where Element == WorkoutTemplateSet {
    /// Convert array of WorkoutTemplateSet to SetCellModels with proper index labels.
    /// Handles warmup vs working set numbering.
    func toSetCellModels(weightUnit: WeightUnit) -> [SetCellModel] {
        var warmupIndex = 0
        var workingIndex = 0

        return self.map { set in
            let indexLabel: String
            let lowercased = set.type.lowercased()

            if lowercased.contains("warm") {
                warmupIndex += 1
                indexLabel = "W\(warmupIndex)"
            } else {
                workingIndex += 1
                indexLabel = "\(workingIndex)"
            }

            return set.toSetCellModel(indexLabel: indexLabel, weightUnit: weightUnit)
        }
    }
}

// MARK: - PlanSet Mapper (Canvas/Planning)

extension PlanSet {
    /// Maps a planning set to SetCellModel for display.
    /// Index label is passed in to avoid requiring the model to know its position.
    /// Used in read-only planning previews and future unified editing.
    func toSetCellModel(indexLabel: String, isActive: Bool = false, weightUnit: WeightUnit) -> SetCellModel {
        let indicator = setTypeIndicator(from: type)

        return SetCellModel(
            id: id,
            indexLabel: indicator != nil ? indicator!.label : indexLabel,
            weight: weight.map { formatWeight($0, unit: weightUnit) },
            reps: "\(reps)",
            rir: isWarmup ? nil : (rir.map { "\($0)" }),
            e1rm: nil,
            setTypeIndicator: indicator,
            isActive: isActive,
            isCompleted: isCompleted ?? false
        )
    }

    private func setTypeIndicator(from type: SetType?) -> SetCellModel.SetTypeIndicator? {
        switch type {
        case .warmup: return .warmup
        case .failureSet: return .failure
        case .dropSet: return .drop
        case .working, .none: return nil
        }
    }

    /// Convert stored kg value to display unit, then format as string
    private func formatWeight(_ weightKg: Double, unit: WeightUnit) -> String {
        let displayed = WeightFormatter.display(weightKg, unit: unit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        return WeightFormatter.truncateTrailingZeros(rounded)
    }
}

extension Array where Element == PlanSet {
    /// Convert array of PlanSet to SetCellModels with proper index labels.
    /// Handles warmup vs working set numbering.
    /// Optional activeSetId parameter to mark which set is active.
    func toSetCellModels(activeSetId: String? = nil, weightUnit: WeightUnit) -> [SetCellModel] {
        var warmupIndex = 0
        var workingIndex = 0

        return self.map { set in
            let indexLabel: String

            if set.isWarmup {
                warmupIndex += 1
                indexLabel = "W\(warmupIndex)"
            } else {
                workingIndex += 1
                indexLabel = "\(workingIndex)"
            }

            return set.toSetCellModel(
                indexLabel: indexLabel,
                isActive: set.id == activeSetId,
                weightUnit: weightUnit
            )
        }
    }
}

// MARK: - FocusModeSet Mapper (Execution)

extension FocusModeSet {
    /// Maps an execution set to SetCellModel for display.
    /// Index label is passed in to avoid requiring the model to know its position.
    /// Used for read-only views of active workouts; the specialized FocusModeSetGrid
    /// handles the full interactive editing experience.
    func toSetCellModel(indexLabel: String, isActive: Bool = false, weightUnit: WeightUnit) -> SetCellModel {
        let indicator = setTypeIndicator()

        return SetCellModel(
            id: id,
            indexLabel: indicator != nil ? indicator!.label : indexLabel,
            weight: displayWeight.map { formatWeight($0, unit: weightUnit) },
            reps: displayReps.map { "\($0)" },
            rir: isWarmup ? nil : (displayRir.map { "\($0)" }),
            e1rm: nil,
            setTypeIndicator: indicator,
            isActive: isActive,
            isCompleted: isDone
        )
    }

    private func setTypeIndicator() -> SetCellModel.SetTypeIndicator? {
        if isWarmup {
            return .warmup
        }
        if tags?.isFailure == true {
            return .failure
        }
        if setType == .dropset {
            return .drop
        }
        return nil
    }

    /// Convert stored kg value to display unit, then format as string
    private func formatWeight(_ weightKg: Double, unit: WeightUnit) -> String {
        let displayed = WeightFormatter.display(weightKg, unit: unit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        return WeightFormatter.truncateTrailingZeros(rounded)
    }
}

extension Array where Element == FocusModeSet {
    /// Convert array of FocusModeSet to SetCellModels with proper index labels.
    /// Handles warmup vs working set numbering.
    /// Optional activeSetId parameter to mark which set is active.
    func toSetCellModels(activeSetId: String? = nil, weightUnit: WeightUnit) -> [SetCellModel] {
        var warmupIndex = 0
        var workingIndex = 0

        return self.map { set in
            let indexLabel: String

            if set.isWarmup {
                warmupIndex += 1
                indexLabel = "W\(warmupIndex)"
            } else {
                workingIndex += 1
                indexLabel = "\(workingIndex)"
            }

            return set.toSetCellModel(
                indexLabel: indexLabel,
                isActive: set.id == activeSetId,
                weightUnit: weightUnit
            )
        }
    }
}
