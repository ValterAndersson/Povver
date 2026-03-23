import Foundation
import Combine
import FirebaseAuth

@MainActor
class ExercisesViewModel: ObservableObject {
    @Published var exercises: [Exercise] = []
    @Published var isLoading = false
    @Published var error: Error?
    @Published var sortOption: ExerciseSortOption {
        didSet { UserDefaults.standard.set(sortOption.rawValue, forKey: Self.sortOptionKey) }
    }

    // Filter options
    @Published var categories: [String] = []
    @Published var movementTypes: [String] = []
    @Published var levels: [String] = []
    @Published var equipment: [String] = []
    @Published var primaryMuscles: [String] = []
    @Published var secondaryMuscles: [String] = []

    // Current filter and search state
    private var allExercises: [Exercise] = []
    private var usageStats: [String: ExerciseUsageStats] = [:]
    private var currentSearchQuery: String = ""
    private var currentFilters: [String: String?] = [
        "category": nil,
        "movementType": nil,
        "level": nil,
        "equipment": nil,
        "primaryMuscle": nil,
        "secondaryMuscle": nil
    ]

    private let repository: ExerciseRepository

    private static let sortOptionKey = "exerciseSortOption"

    init(repository: ExerciseRepository = ExerciseRepository()) {
        self.repository = repository
        // Restore persisted sort option (default: recentlyUsed)
        if let raw = UserDefaults.standard.string(forKey: Self.sortOptionKey),
           let saved = ExerciseSortOption(rawValue: raw) {
            self.sortOption = saved
        } else {
            self.sortOption = .recentlyUsed
        }
    }

    func loadExercises() async {
        isLoading = true
        error = nil

        do {
            // Load exercises and usage stats in parallel
            async let fetchedExercises = repository.list()
            async let fetchedStats = loadUsageStats()
            let (fetched, stats) = try await (fetchedExercises, fetchedStats)

            // Deduplicate by name — keep the first occurrence of each unique name
            var seen = Set<String>()
            allExercises = fetched.filter { exercise in
                let key = exercise.name.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            usageStats = stats
            await loadFilterOptions()
            await applyFiltersAndSearch()
        } catch {
            self.error = error
        }

        isLoading = false
    }

    /// Load usage stats with graceful error handling — exercises still display
    /// alphabetically if stats fetch fails.
    private func loadUsageStats() async throws -> [String: ExerciseUsageStats] {
        guard let userId = Auth.auth().currentUser?.uid else { return [:] }
        do {
            return try await repository.fetchUsageStats(userId: userId)
        } catch {
            AppLogger.shared.error(.app, "Failed to load usage stats, falling back to empty", error)
            return [:]
        }
    }

    func setSortOption(_ option: ExerciseSortOption) {
        sortOption = option
        Task { await applyFiltersAndSearch() }
    }

    private func loadFilterOptions() async {
        // Extract unique values from all exercises
        categories = Array(Set(allExercises.map { $0.category })).sorted()
        movementTypes = Array(Set(allExercises.map { $0.movementType })).sorted()
        levels = Array(Set(allExercises.map { $0.level })).sorted()
        equipment = Array(Set(allExercises.flatMap { $0.equipment })).sorted()
        primaryMuscles = Array(Set(allExercises.flatMap { $0.primaryMuscles })).sorted()
        secondaryMuscles = Array(Set(allExercises.flatMap { $0.secondaryMuscles })).sorted()
    }

    func searchExercises(query: String) async {
        currentSearchQuery = query
        await applyFiltersAndSearch()
    }

    func filterByCategory(_ category: String?) async {
        currentFilters["category"] = category
        await applyFiltersAndSearch()
    }

    func filterByMovementType(_ type: String?) async {
        currentFilters["movementType"] = type
        await applyFiltersAndSearch()
    }

    func filterByLevel(_ level: String?) async {
        currentFilters["level"] = level
        await applyFiltersAndSearch()
    }

    func filterByEquipment(_ equipment: String?) async {
        currentFilters["equipment"] = equipment
        await applyFiltersAndSearch()
    }

    func filterByPrimaryMuscle(_ muscle: String?) async {
        currentFilters["primaryMuscle"] = muscle
        await applyFiltersAndSearch()
    }

    func filterBySecondaryMuscle(_ muscle: String?) async {
        currentFilters["secondaryMuscle"] = muscle
        await applyFiltersAndSearch()
    }

    private func applyFiltersAndSearch() async {
        var filteredExercises = allExercises

        // Apply category filter
        if let category = currentFilters["category"], let categoryValue = category {
            filteredExercises = filteredExercises.filter { $0.category == categoryValue }
        }

        // Apply movement type filter
        if let movementType = currentFilters["movementType"], let movementTypeValue = movementType {
            filteredExercises = filteredExercises.filter { $0.movementType == movementTypeValue }
        }

        // Apply level filter
        if let level = currentFilters["level"], let levelValue = level {
            filteredExercises = filteredExercises.filter { $0.level == levelValue }
        }

        // Apply equipment filter
        if let equipment = currentFilters["equipment"], let equipmentValue = equipment {
            filteredExercises = filteredExercises.filter { $0.equipment.contains(equipmentValue) }
        }

        // Apply primary muscle filter
        if let primaryMuscle = currentFilters["primaryMuscle"], let primaryMuscleValue = primaryMuscle {
            filteredExercises = filteredExercises.filter { $0.primaryMuscles.contains(primaryMuscleValue) }
        }

        // Apply secondary muscle filter
        if let secondaryMuscle = currentFilters["secondaryMuscle"], let secondaryMuscleValue = secondaryMuscle {
            filteredExercises = filteredExercises.filter { $0.secondaryMuscles.contains(secondaryMuscleValue) }
        }

        // Apply search query
        if !currentSearchQuery.isEmpty {
            let searchTerm = currentSearchQuery.lowercased()
            filteredExercises = filteredExercises.filter { exercise in
                let searchableText = [
                    exercise.name,
                    exercise.category,
                    exercise.movementType,
                    exercise.level,
                    exercise.equipment.joined(separator: " "),
                    exercise.primaryMuscles.joined(separator: " "),
                    exercise.secondaryMuscles.joined(separator: " ")
                ].joined(separator: " ").lowercased()

                return searchableText.contains(searchTerm)
            }
        }

        // Sort after filtering. Exercises without usage stats sink to the bottom,
        // sorted alphabetically among themselves. Name is the tiebreaker for stable ordering.
        filteredExercises = sortExercises(filteredExercises)

        exercises = filteredExercises
    }

    private func sortExercises(_ exercises: [Exercise]) -> [Exercise] {
        switch sortOption {
        case .recentlyUsed:
            return exercises.sorted { a, b in
                let aDate = usageStats[a.id ?? ""]?.lastWorkoutDate
                let bDate = usageStats[b.id ?? ""]?.lastWorkoutDate
                // Both have dates: sort descending by date, then by name
                if let ad = aDate, let bd = bDate {
                    return ad == bd ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                                    : ad > bd
                }
                // One has date, the other doesn't: dated exercise comes first
                if aDate != nil { return true }
                if bDate != nil { return false }
                // Neither has a date: alphabetical
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .mostUsed:
            return exercises.sorted { a, b in
                let aCount = usageStats[a.id ?? ""]?.workoutCount ?? 0
                let bCount = usageStats[b.id ?? ""]?.workoutCount ?? 0
                if aCount != bCount { return aCount > bCount }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .alphabetical:
            return exercises.sorted { a, b in
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}
