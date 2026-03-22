/**
 * FocusModeExerciseSearch.swift
 * 
 * Exercise search sheet for Focus Mode workout.
 * Uses existing ExercisesViewModel for data fetching.
 * Optimized for quick gym use - large tap targets, fast filtering.
 * 
 * Filter system with multi-select sheet for:
 * - Muscle groups
 * - Equipment
 * - Movement patterns
 */

import SwiftUI

// MARK: - Filter Model

struct ExerciseFilters: Equatable {
    var muscleGroups: Set<String> = []
    var equipment: Set<String> = []
    var movementPatterns: Set<String> = []
    var difficulty: Set<String> = []
    
    var activeCount: Int {
        muscleGroups.count + equipment.count + movementPatterns.count + difficulty.count
    }
    
    var isEmpty: Bool {
        activeCount == 0
    }
    
    mutating func clear() {
        muscleGroups.removeAll()
        equipment.removeAll()
        movementPatterns.removeAll()
        difficulty.removeAll()
    }
}

enum ExerciseSortOption: String, CaseIterable {
    case recentlyUsed = "Recent"
    case mostUsed = "Frequent"
    case alphabetical = "A–Z"
}

// MARK: - Muscle Group Mapping

enum MuscleGroupMapping: String, CaseIterable {
    case chest = "Chest"
    case back = "Back"
    case shoulders = "Shoulders"
    case arms = "Arms"
    case legs = "Legs"
    case core = "Core"
    
    var muscles: [String] {
        switch self {
        case .chest: return ["chest", "pectorals", "pectoralis major", "pectoralis minor"]
        case .back: return ["back", "lats", "latissimus dorsi", "rhomboids", "traps", "trapezius", "erector spinae"]
        case .shoulders: return ["shoulders", "deltoids", "anterior deltoid", "lateral deltoid", "posterior deltoid", "deltoid", "delts"]
        case .arms: return ["biceps", "biceps brachii", "triceps", "triceps brachii", "forearms", "brachialis"]
        case .legs: return ["quads", "quadriceps", "hamstrings", "glutes", "gluteus maximus", "gluteus medius", "calves", "gastrocnemius", "soleus", "adductors", "abductors"]
        case .core: return ["abs", "abdominals", "obliques", "core", "lower back", "erector spinae", "rectus abdominis", "transverse abdominis"]
        }
    }
}

struct FocusModeExerciseSearch: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ExercisesViewModel()
    
    let onSelect: (Exercise) -> Void
    
    @State private var searchText = ""
    @State private var filters = ExerciseFilters()
    @State private var showingFilterSheet = false
    @State private var showingExerciseDetail: Exercise?
    
    // Filtered exercises based on current filters
    private var filteredExercises: [Exercise] {
        var result = viewModel.exercises
        
        // Apply muscle group filter
        if !filters.muscleGroups.isEmpty {
            result = result.filter { exercise in
                let exerciseMuscles = Set(exercise.primaryMuscles.map { $0.lowercased() })
                let filterMuscles = Set(filters.muscleGroups.flatMap { group -> [String] in
                    (MuscleGroupMapping(rawValue: group)?.muscles ?? []).map { $0.lowercased() }
                })
                return !exerciseMuscles.isDisjoint(with: filterMuscles)
            }
        }
        
        // Apply equipment filter (exact case-insensitive — values derived from data)
        if !filters.equipment.isEmpty {
            result = result.filter { exercise in
                let exerciseEquipSet = Set(exercise.equipment.map { $0.lowercased() })
                return filters.equipment.contains { exerciseEquipSet.contains($0.lowercased()) }
            }
        }

        // Apply movement pattern filter (exact case-insensitive — values derived from data)
        if !filters.movementPatterns.isEmpty {
            result = result.filter { exercise in
                filters.movementPatterns.contains { $0.lowercased() == exercise.movementType.lowercased() }
            }
        }

        // Apply difficulty filter
        if !filters.difficulty.isEmpty {
            result = result.filter { exercise in
                filters.difficulty.contains(exercise.level.capitalized)
            }
        }
        
        return result
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar with filter button
                searchAndFilterBar
                
                // Exercise list
                if viewModel.isLoading {
                    loadingView
                } else if filteredExercises.isEmpty {
                    emptyView
                } else {
                    exerciseList
                }
            }
            .background(Color.bg)
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.textSecondary)
                }
            }
        }
        .task {
            await viewModel.loadExercises()
        }
        .onChange(of: searchText) { _, newValue in
            Task {
                await viewModel.searchExercises(query: newValue)
            }
        }
        .sheet(isPresented: $showingFilterSheet) {
            ExerciseFilterSheet(
                filters: $filters,
                equipmentOptions: viewModel.equipment,
                movementPatternOptions: viewModel.movementTypes,
                onApply: { showingFilterSheet = false },
                onClear: {
                    filters.clear()
                    showingFilterSheet = false
                }
            )
        }
        .sheet(item: $showingExerciseDetail) { exercise in
            FocusModeExerciseDetailSheet(exercise: exercise)
        }
    }

    // MARK: - Search and Filter Bar
    
    private var searchAndFilterBar: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                // Search field
                HStack(spacing: Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Color.textSecondary)
                    
                    TextField("Search exercises...", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 16))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, 12)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                
                // Filter button
                Button {
                    showingFilterSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 14, weight: .medium))
                        
                        if filters.activeCount > 0 {
                            Text("·")
                            Text("\(filters.activeCount)")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                    }
                    .foregroundColor(filters.isEmpty ? Color.textSecondary : Color.accent)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 12)
                    .background(filters.isEmpty ? Color.surface : Color.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                            .stroke(filters.isEmpty ? Color.clear : Color.accent.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.sm)
            
            // Active filter pills (quick dismissal)
            if !filters.isEmpty {
                activeFilterPills
            }
        }
        .padding(.bottom, Space.sm)
        .background(Color.bg)
    }
    
    // MARK: - Active Filter Pills
    
    private var activeFilterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                // Clear all
                Button {
                    filters.clear()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Clear all")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.surfaceElevated)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                
                // Muscle groups
                ForEach(Array(filters.muscleGroups), id: \.self) { group in
                    activeFilterPill(label: group, color: Color.accent) {
                        filters.muscleGroups.remove(group)
                    }
                }
                
                // Equipment
                ForEach(Array(filters.equipment), id: \.self) { equip in
                    activeFilterPill(label: equip.capitalized, color: Color.accent) {
                        filters.equipment.remove(equip)
                    }
                }

                // Movement patterns
                ForEach(Array(filters.movementPatterns), id: \.self) { pattern in
                    activeFilterPill(label: pattern.replacingOccurrences(of: "_", with: " ").capitalized, color: Color.warning) {
                        filters.movementPatterns.remove(pattern)
                    }
                }
            }
            .padding(.horizontal, Space.md)
        }
    }

    private func activeFilterPill(label: String, color: Color, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
    
    // MARK: - Exercise List

    private var exerciseList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Sort chips + results count
                HStack(spacing: Space.sm) {
                    sortChips
                    Spacer()
                    Text("\(filteredExercises.count) exercises")
                        .font(.system(size: 13))
                        .foregroundColor(Color.textTertiary)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)

                ForEach(filteredExercises) { exercise in
                    ExerciseRowNew(
                        exercise: exercise,
                        onTap: {
                            onSelect(exercise)
                            dismiss()
                        },
                        onInfo: {
                            showingExerciseDetail = exercise
                        }
                    )
                    
                    Divider()
                        .padding(.leading, Space.md)
                }
            }
            .padding(.bottom, Space.xl)
        }
    }
    
    // MARK: - Sort Chips

    private var sortChips: some View {
        HStack(spacing: 6) {
            ForEach(ExerciseSortOption.allCases, id: \.self) { option in
                Button {
                    viewModel.setSortOption(option)
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 12, weight: viewModel.sortOption == option ? .semibold : .medium))
                        .foregroundColor(viewModel.sortOption == option ? .textInverse : Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(viewModel.sortOption == option ? Color.accent : Color.surfaceElevated)
                        .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading exercises...")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
                .padding(.top, Space.md)
            Spacer()
        }
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: Space.md) {
            Spacer()
            
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(Color.textTertiary)
            
            Text("No exercises found")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color.textSecondary)
            
            if !searchText.isEmpty {
                Text("Try a different search term")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textTertiary)
            }
            
            if !filters.isEmpty {
                Button {
                    filters.clear()
                } label: {
                    Text("Clear all filters")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.accent)
                }
                .padding(.top, Space.sm)
            }
            
            Spacer()
        }
    }
}

// MARK: - Exercise Filter Sheet

struct ExerciseFilterSheet: View {
    @Binding var filters: ExerciseFilters
    let equipmentOptions: [String]
    let movementPatternOptions: [String]
    let onApply: () -> Void
    let onClear: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    // Muscle Groups
                    filterSection(title: "Muscle Groups") {
                        FlowLayout(spacing: Space.sm) {
                            ForEach(MuscleGroupMapping.allCases, id: \.rawValue) { group in
                                FilterToggleChip(
                                    label: group.rawValue,
                                    isSelected: filters.muscleGroups.contains(group.rawValue),
                                    color: Color.accent
                                ) {
                                    toggleFilter(group.rawValue, in: &filters.muscleGroups)
                                }
                            }
                        }
                    }
                    
                    // Equipment (dynamic — derived from loaded exercise data)
                    filterSection(title: "Equipment") {
                        FlowLayout(spacing: Space.sm) {
                            ForEach(equipmentOptions, id: \.self) { equip in
                                FilterToggleChip(
                                    label: equip.capitalized,
                                    isSelected: filters.equipment.contains(equip),
                                    color: Color.accent
                                ) {
                                    toggleFilter(equip, in: &filters.equipment)
                                }
                            }
                        }
                    }

                    // Movement Patterns (dynamic — derived from loaded exercise data)
                    filterSection(title: "Movement Pattern") {
                        FlowLayout(spacing: Space.sm) {
                            ForEach(movementPatternOptions, id: \.self) { pattern in
                                FilterToggleChip(
                                    label: pattern.replacingOccurrences(of: "_", with: " ").capitalized,
                                    isSelected: filters.movementPatterns.contains(pattern),
                                    color: Color.warning
                                ) {
                                    toggleFilter(pattern, in: &filters.movementPatterns)
                                }
                            }
                        }
                    }
                    
                    // Difficulty
                    filterSection(title: "Difficulty") {
                        FlowLayout(spacing: Space.sm) {
                            ForEach(["Beginner", "Intermediate", "Advanced"], id: \.self) { level in
                                FilterToggleChip(
                                    label: level,
                                    isSelected: filters.difficulty.contains(level),
                                    color: Color.textSecondary
                                ) {
                                    toggleFilter(level, in: &filters.difficulty)
                                }
                            }
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(Color.bg)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        onClear()
                    }
                    .foregroundColor(filters.isEmpty ? Color.textTertiary : Color.destructive)
                    .disabled(filters.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Changed from "Apply" to "Done" - primary Apply is at bottom
                    Button("Done") {
                        onApply()
                    }
                    .foregroundColor(Color.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Apply button at bottom
                Button {
                    onApply()
                } label: {
                    HStack {
                        Text("Apply")
                        if filters.activeCount > 0 {
                            Text("(\(filters.activeCount))")
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.textInverse)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
                .background(Color.bg)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    private func filterSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.textSecondary)
                .textCase(.uppercase)
            
            content()
        }
    }
    
    private func toggleFilter(_ value: String, in set: inout Set<String>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
        HapticManager.selectionChanged()
    }
}

// MARK: - Filter Toggle Chip

private struct FilterToggleChip: View {
    let label: String
    let isSelected: Bool
    let color: Color
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .textInverse : Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? color : Color.surface)
            .clipShape(Capsule())
            .overlay(
                isSelected ? nil : Capsule().stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Exercise Row New (consistent size buttons)

private struct ExerciseRowNew: View {
    let exercise: Exercise
    let onTap: () -> Void
    let onInfo: () -> Void
    
    var body: some View {
        HStack(spacing: Space.md) {
            // Exercise info - tap to add
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.capitalizedName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.textPrimary)
                        .lineLimit(1)
                    
                    Text(exerciseSubtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PlainButtonStyle())
            
            // Info button (secondary, smaller)
            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundColor(Color.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PlainButtonStyle())
            
            // Add button (primary, consistent size)
            Button(action: onTap) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 12)
        .background(Color.surface)
        .contentShape(Rectangle())
    }
    
    private var exerciseSubtitle: String {
        let muscles = exercise.capitalizedPrimaryMuscles.joined(separator: ", ")
        let equipment = exercise.capitalizedEquipment
        
        if !muscles.isEmpty && !equipment.isEmpty {
            return "\(muscles) • \(equipment)"
        } else if !muscles.isEmpty {
            return muscles
        } else if !equipment.isEmpty {
            return equipment
        }
        return ""
    }
}

// MARK: - Exercise Detail Sheet (Focus Mode variant)

struct FocusModeExerciseDetailSheet: View {
    let exercise: Exercise
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    // Header
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(exercise.capitalizedName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color.textPrimary)
                        
                        if !exercise.capitalizedEquipment.isEmpty {
                            Label(exercise.capitalizedEquipment, systemImage: "dumbbell")
                                .font(.system(size: 14))
                                .foregroundColor(Color.textSecondary)
                        }
                    }
                    
                    Divider()
                    
                    // Muscles
                    if !exercise.primaryMuscles.isEmpty {
                        infoSection(title: "Primary Muscles") {
                            Text(exercise.capitalizedPrimaryMuscles.joined(separator: ", "))
                                .font(.system(size: 15))
                                .foregroundColor(Color.textPrimary)
                        }
                    }
                    
                    if !exercise.secondaryMuscles.isEmpty {
                        infoSection(title: "Secondary Muscles") {
                            Text(exercise.capitalizedSecondaryMuscles.joined(separator: ", "))
                                .font(.system(size: 15))
                                .foregroundColor(Color.textPrimary)
                        }
                    }
                    
                    // Movement info
                    if !exercise.movementType.isEmpty {
                        infoSection(title: "Movement Type") {
                            Text(exercise.capitalizedMovementType)
                                .font(.system(size: 15))
                                .foregroundColor(Color.textPrimary)
                        }
                    }
                    
                    // Level
                    if !exercise.level.isEmpty {
                        infoSection(title: "Difficulty") {
                            Text(exercise.capitalizedLevel)
                                .font(.system(size: 15))
                                .foregroundColor(Color.textPrimary)
                        }
                    }
                    
                    // Execution notes
                    if !exercise.executionNotes.isEmpty {
                        infoSection(title: "Execution Notes") {
                            ForEach(exercise.executionNotes, id: \.self) { note in
                                HStack(alignment: .top, spacing: Space.sm) {
                                    Text("•")
                                    Text(note)
                                }
                                .font(.system(size: 14))
                                .foregroundColor(Color.textPrimary)
                            }
                        }
                    }
                    
                    // Common mistakes
                    if !exercise.commonMistakes.isEmpty {
                        infoSection(title: "Common Mistakes") {
                            ForEach(exercise.commonMistakes, id: \.self) { mistake in
                                HStack(alignment: .top, spacing: Space.sm) {
                                    Text("•")
                                    Text(mistake)
                                }
                                .font(.system(size: 14))
                                .foregroundColor(Color.textPrimary)
                            }
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(Color.bg)
            .navigationTitle("Exercise Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func infoSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.textSecondary)
                .textCase(.uppercase)
            
            content()
        }
    }
}

// MARK: - Preview

#Preview {
    FocusModeExerciseSearch { exercise in
        print("Selected: \(exercise.name)")
    }
}
