import SwiftUI

/// Library Tab - Content-rich dashboard with active routine hero,
/// template cards, and exercise browsing
struct LibraryView: View {
    @State private var routines: [FocusModeWorkoutService.RoutineInfo] = []
    @State private var templates: [FocusModeWorkoutService.TemplateInfo] = []
    @State private var nextWorkoutInfo: FocusModeWorkoutService.NextWorkoutInfo? = nil
    @State private var isLoading = true
    @State private var hasAppeared = false

    private var activeRoutine: FocusModeWorkoutService.RoutineInfo? {
        routines.first(where: { $0.isActive })
    }

    private var inactiveRoutines: [FocusModeWorkoutService.RoutineInfo] {
        routines.filter { !$0.isActive }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Header
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Library")
                        .textStyle(.screenTitle)
                        .foregroundColor(Color.textPrimary)

                    Text("\(routines.count) routines, \(templates.count) templates")
                        .textStyle(.secondary)
                        .foregroundColor(Color.textSecondary)
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                .staggeredEntrance(index: 0, active: hasAppeared)

                // MARK: - Your Program
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("YOUR PROGRAM")
                        .textStyle(.sectionLabel)
                        .foregroundColor(Color.textSecondary)
                        .padding(.horizontal, Space.lg)

                    if let routine = activeRoutine {
                        NavigationLink(destination: RoutineDetailView(routineId: routine.id, routineName: routine.name)) {
                            activeRoutineCard(routine)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            AnalyticsService.shared.librarySectionOpened(section: .routines)
                        })
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, Space.lg)
                    } else if !isLoading {
                        emptyRoutineCard
                            .padding(.horizontal, Space.lg)
                    }
                }
                .staggeredEntrance(index: 1, active: hasAppeared)

                // MARK: - Other Routines
                if !inactiveRoutines.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("OTHER ROUTINES")
                            .textStyle(.sectionLabel)
                            .foregroundColor(Color.textSecondary)
                            .padding(.horizontal, Space.lg)

                        VStack(spacing: Space.xs) {
                            ForEach(inactiveRoutines) { routine in
                                NavigationLink(destination: RoutineDetailView(routineId: routine.id, routineName: routine.name)) {
                                    inactiveRoutineRow(routine)
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    AnalyticsService.shared.librarySectionOpened(section: .routines)
                                })
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, Space.lg)
                    }
                    .staggeredEntrance(index: 2, active: hasAppeared)
                }

                // MARK: - Templates
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("TEMPLATES")
                        .textStyle(.sectionLabel)
                        .foregroundColor(Color.textSecondary)
                        .padding(.horizontal, Space.lg)

                    if templates.isEmpty && !isLoading {
                        SurfaceCard {
                            Text("No templates yet \u{2014} create one or ask your coach.")
                                .textStyle(.secondary)
                                .foregroundColor(Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, Space.lg)
                    } else {
                        VStack(spacing: Space.xs) {
                            ForEach(templates.prefix(3)) { template in
                                NavigationLink(destination: TemplateDetailView(templateId: template.id, templateName: template.name)) {
                                    templateCard(template)
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    AnalyticsService.shared.librarySectionOpened(section: .templates)
                                })
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, Space.lg)

                        if templates.count > 3 {
                            NavigationLink(destination: TemplatesListView()) {
                                Text("See all (\(templates.count))")
                                    .textStyle(.secondary)
                                    .foregroundColor(Color.accent)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                AnalyticsService.shared.librarySectionOpened(section: .templates)
                            })
                            .padding(.horizontal, Space.lg)
                        }
                    }
                }
                .staggeredEntrance(index: 3, active: hasAppeared)

                // MARK: - Exercises
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("EXERCISES")
                        .textStyle(.sectionLabel)
                        .foregroundColor(Color.textSecondary)
                        .padding(.horizontal, Space.lg)

                    NavigationLink(destination: ExercisesListView()) {
                        LibraryRow(
                            title: "Browse all exercises",
                            subtitle: "Exercise catalog and movements",
                            icon: "figure.strengthtraining.traditional"
                        )
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        AnalyticsService.shared.librarySectionOpened(section: .exercises)
                    })
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, Space.lg)
                }
                .staggeredEntrance(index: 4, active: hasAppeared)

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !hasAppeared {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    hasAppeared = true
                }
            }
        }
        .task {
            let service = FocusModeWorkoutService.shared
            routines = (try? await service.getUserRoutines()) ?? []
            templates = (try? await service.getUserTemplates()) ?? []
            nextWorkoutInfo = try? await service.getNextWorkout()
            isLoading = false
        }
    }

    // MARK: - Active Routine Hero Card (Tier 2)

    private func activeRoutineCard(_ routine: FocusModeWorkoutService.RoutineInfo) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(routine.name)
                    .textStyle(.bodyStrong)
                    .foregroundColor(Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.textTertiary)
            }

            if routine.workoutCount > 0 {
                MiniWeekStrip(
                    totalDays: routine.workoutCount,
                    completedThisWeek: nextWorkoutInfo?.templateIndex ?? 0,
                    currentDayIndex: nextWorkoutInfo?.templateIndex ?? 0
                )
            }

            if let next = nextWorkoutInfo, let template = next.template {
                Text("Next: \(template.name)")
                    .textStyle(.secondary)
                    .foregroundColor(Color.textSecondary)
            }
        }
        .padding(Space.lg)
        .background(Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
        .shadowStyle(ShadowsToken.level1)
    }

    // MARK: - Empty Routine State

    private var emptyRoutineCard: some View {
        SurfaceCard {
            Text("No programs yet \u{2014} want me to design one for you?")
                .textStyle(.secondary)
                .foregroundColor(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Inactive Routine Row (Tier 0)

    private func inactiveRoutineRow(_ routine: FocusModeWorkoutService.RoutineInfo) -> some View {
        HStack {
            Text(routine.name)
                .textStyle(.bodyStrong)
                .foregroundColor(Color.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.textTertiary)
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }

    // MARK: - Template Card (Tier 1)

    private func templateCard(_ template: FocusModeWorkoutService.TemplateInfo) -> some View {
        SurfaceCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .textStyle(.bodyStrong)
                        .foregroundColor(Color.textPrimary)
                    Text("\(template.exerciseCount) exercises \u{00B7} \(template.setCount) sets")
                        .textStyle(.secondary)
                        .foregroundColor(Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.textTertiary)
            }
        }
    }
}

// MARK: - Library Row

private struct LibraryRow: View {
    let title: String
    let subtitle: String
    let icon: String
    
    var body: some View {
        HStack(spacing: Space.md) {
            // Icon - monochrome for premium aesthetic
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Color.textSecondary)
                .frame(width: 44, height: 44)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.bodyStrong)
                    .foregroundColor(Color.textPrimary)

                Text(subtitle)
                    .textStyle(.caption)
                    .foregroundColor(Color.textSecondary)
            }
            
            Spacer()
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.textTertiary)
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
}

// MARK: - Routines List View (Scaffold)

struct RoutinesListView: View {
    @ObservedObject private var saveService = BackgroundSaveService.shared
    @State private var routines: [RoutineItem] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if routines.isEmpty {
                emptyStateView
            } else {
                routinesList
            }
        }
        .background(Color.bg)
        .navigationTitle("Routines")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadRoutines()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: Space.md) {
            ProgressView()
            Text("Loading...")
                .textStyle(.caption)
                .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: Space.lg) {
            CoachPresenceIndicator(size: 32)

            VStack(spacing: Space.sm) {
                Text("No programs yet")
                    .textStyle(.sectionHeader)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Want me to design one for you?")
                    .textStyle(.secondary)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(InsetsToken.screen)
    }
    
    private var routinesList: some View {
        ScrollView {
            LazyVStack(spacing: Space.sm) {
                ForEach(routines) { routine in
                    NavigationLink(destination: RoutineDetailView(routineId: routine.id, routineName: routine.name)) {
                        WorkoutRow.routine(
                            name: routine.name,
                            workoutCount: routine.workoutCount,
                            isActive: routine.isActive,
                            isSyncing: saveService.isSaving(routine.id)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(Space.lg)
        }
    }
    
    private func loadRoutines() async {
        // Use prefetched cache if available
        if let cached = FocusModeWorkoutService.shared.cachedRoutines {
            routines = cached.map { info in
                RoutineItem(id: info.id, name: info.name, workoutCount: info.workoutCount, isActive: info.isActive)
            }
            isLoading = false
            return
        }
        // Fallback to network fetch
        do {
            let fetchedRoutines = try await FocusModeWorkoutService.shared.getUserRoutines()
            routines = fetchedRoutines.map { info in
                RoutineItem(
                    id: info.id,
                    name: info.name,
                    workoutCount: info.workoutCount,
                    isActive: info.isActive
                )
            }
        } catch {
            AppLogger.shared.error(.app, "Failed to load routines", error)
        }
        isLoading = false
    }
}

// MARK: - Routine Item Model

struct RoutineItem: Identifiable {
    let id: String
    let name: String
    let workoutCount: Int
    let isActive: Bool
}


// MARK: - Templates List View (Scaffold)

struct TemplatesListView: View {
    @ObservedObject private var saveService = BackgroundSaveService.shared
    @State private var templates: [TemplateItem] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if templates.isEmpty {
                emptyStateView
            } else {
                templatesList
            }
        }
        .background(Color.bg)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadTemplates()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: Space.md) {
            ProgressView()
            Text("Loading...")
                .textStyle(.caption)
                .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: Space.lg) {
            CoachPresenceIndicator(size: 32)

            VStack(spacing: Space.sm) {
                Text("No templates yet")
                    .textStyle(.sectionHeader)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Create one or ask your coach.")
                    .textStyle(.secondary)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(InsetsToken.screen)
    }

    private var templatesList: some View {
        ScrollView {
            LazyVStack(spacing: Space.sm) {
                ForEach(templates) { template in
                    NavigationLink(destination: TemplateDetailView(templateId: template.id, templateName: template.name)) {
                        WorkoutRow.template(
                            name: template.name,
                            exerciseCount: template.exerciseCount,
                            setCount: template.setCount,
                            isSyncing: saveService.isSaving(template.id)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(Space.lg)
        }
    }
    
    private func loadTemplates() async {
        // Use prefetched cache if available
        if let cached = FocusModeWorkoutService.shared.cachedTemplates {
            templates = cached.map { info in
                TemplateItem(id: info.id, name: info.name, exerciseCount: info.exerciseCount, setCount: info.setCount)
            }
            isLoading = false
            return
        }
        // Fallback to network fetch
        do {
            let fetchedTemplates = try await FocusModeWorkoutService.shared.getUserTemplates()
            templates = fetchedTemplates.map { info in
                TemplateItem(
                    id: info.id,
                    name: info.name,
                    exerciseCount: info.exerciseCount,
                    setCount: info.setCount
                )
            }
        } catch {
            AppLogger.shared.error(.app, "Failed to load templates", error)
        }
        isLoading = false
    }
}

// MARK: - Template Item Model

struct TemplateItem: Identifiable {
    let id: String
    let name: String
    let exerciseCount: Int
    let setCount: Int
}


// MARK: - Exercises List View (Browse Mode)
// Reuses FocusModeExerciseSearch patterns for consistency - loads exercises on open, tap for details

struct ExercisesListView: View {
    @StateObject private var viewModel = ExercisesViewModel()
    
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
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.loadExercises()
        }
        .onChange(of: searchText) { _, newValue in
            Task {
                await viewModel.searchExercises(query: newValue)
                // Track exercise search
                AnalyticsService.shared.exerciseSearched(
                    hasQuery: !newValue.isEmpty,
                    filterCount: filters.activeCount,
                    resultCount: filteredExercises.count
                )
            }
        }
        .onChange(of: filters) { _, _ in
            // Track filter changes
            if !searchText.isEmpty || !filters.isEmpty {
                AnalyticsService.shared.exerciseSearched(
                    hasQuery: !searchText.isEmpty,
                    filterCount: filters.activeCount,
                    resultCount: filteredExercises.count
                )
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
                        .textStyle(.secondary)
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
                                .textStyle(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                    .foregroundColor(filters.isEmpty ? Color.textSecondary : Color.textPrimary)
                    .fontWeight(filters.isEmpty ? .regular : .semibold)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 12)
                    .background(filters.isEmpty ? Color.surface : Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                            .stroke(
                                Color.separatorLine,
                                lineWidth: filters.isEmpty ? StrokeWidthToken.hairline : StrokeWidthToken.thin
                            )
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
                            .textStyle(.micro)
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
                    activeFilterPill(label: group, color: Color.textSecondary) {
                        filters.muscleGroups.remove(group)
                    }
                }
                
                // Equipment
                ForEach(Array(filters.equipment), id: \.self) { equip in
                    activeFilterPill(label: equip.capitalized, color: Color.textSecondary) {
                        filters.equipment.remove(equip)
                    }
                }

                // Movement patterns
                ForEach(Array(filters.movementPatterns), id: \.self) { pattern in
                    activeFilterPill(label: pattern.capitalized, color: Color.warning) {
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
                .textStyle(.micro)

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
                        .textStyle(.caption)
                        .foregroundColor(Color.textTertiary)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)

                ForEach(filteredExercises) { exercise in
                    LibraryExerciseRow(
                        exercise: exercise,
                        onTap: {
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
                        .textStyle(.micro)
                        .fontWeight(viewModel.sortOption == option ? .semibold : .regular)
                        .foregroundColor(viewModel.sortOption == option ? Color.textPrimary : Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(viewModel.sortOption == option ? Color.surface : Color.clear)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(
                                    viewModel.sortOption == option ? Color.separatorLine : Color.separatorLine,
                                    lineWidth: viewModel.sortOption == option ? StrokeWidthToken.thin : StrokeWidthToken.hairline
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            VStack(spacing: Space.md) {
                ProgressView()
                Text("Loading exercises...")
                    .textStyle(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
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
                .textStyle(.bodyStrong)
                .foregroundColor(Color.textSecondary)

            if !searchText.isEmpty {
                Text("Try a different search term")
                    .textStyle(.caption)
                    .foregroundColor(Color.textTertiary)
            }

            if !filters.isEmpty {
                Button {
                    filters.clear()
                } label: {
                    Text("Clear all filters")
                        .textStyle(.caption)
                        .foregroundColor(Color.accent)
                }
                .padding(.top, Space.sm)
            }
            
            Spacer()
        }
    }
}

// MARK: - Library Exercise Row (Browse Mode - No Add Button)

private struct LibraryExerciseRow: View {
    let exercise: Exercise
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.md) {
                // Exercise info
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.capitalizedName)
                        .textStyle(.secondary)
                        .foregroundColor(Color.textPrimary)
                        .lineLimit(1)

                    Text(exerciseSubtitle)
                        .textStyle(.caption)
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Chevron for detail navigation
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.textTertiary)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 12)
            .background(Color.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
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

// MARK: - Template Detail View (Reuses ExerciseRowView from Canvas)

struct TemplateDetailView: View {
    let templateId: String
    let templateName: String

    @ObservedObject private var saveService = BackgroundSaveService.shared
    @State private var template: WorkoutTemplate?
    @State private var planExercises: [PlanExercise] = []
    @State private var isLoading = true

    // State for ExerciseRowView
    @State private var expandedExerciseId: String? = nil
    @State private var selectedCell: GridCellField? = nil
    @State private var warmupCollapsed: [String: Bool] = [:]
    @State private var selectedExerciseForInfo: PlanExercise? = nil
    @State private var exerciseForSwap: PlanExercise? = nil

    // State for editing
    @State private var isEditing = false
    @State private var editingName: String = ""
    @State private var editingDescription: String = ""
    @State private var showAddExercise = false
    @State private var originalPlanExercises: [PlanExercise] = []

    // Delete state
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss

    private var syncState: FocusModeSyncState? {
        saveService.state(for: templateId)
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if !planExercises.isEmpty {
                templateContent
            } else {
                errorView
            }
        }
        .background(Color.bg)
        .navigationTitle(templateName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTemplate()
            // Track template view
            if let template = template {
                AnalyticsService.shared.templateViewed(
                    templateId: templateId,
                    exerciseCount: template.exercises.count,
                    source: "library"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("Done") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                    .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if let state = syncState {
                    if state.isPending {
                        HStack(spacing: 6) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                            Text("Syncing")
                                .textStyle(.secondary)
                                .foregroundColor(.textSecondary)
                        }
                    } else if state.isFailed {
                        Button("Retry") {
                            saveService.retry(entityId: templateId)
                        }
                        .foregroundColor(.warning)
                    }
                } else {
                    Menu {
                        Button { startEditing() } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Template", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Color.textSecondary)
                    }
                }
            }
        }
        .confirmationDialog("Delete this template?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                HapticManager.destructiveAction()
                deleteTemplate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This template will be permanently removed.")
        }
        .onChange(of: syncState) { oldState, newState in
            if oldState != nil && newState == nil {
                Task { await loadTemplate() }
            }
        }
        .sheet(item: $selectedExerciseForInfo) { exercise in
            ExerciseDetailSheet(
                exerciseId: exercise.exerciseId,
                exerciseName: exercise.name,
                onDismiss: { selectedExerciseForInfo = nil }
            )
        }
        .sheet(item: $exerciseForSwap) { exercise in
            ExerciseSwapSheet(
                currentExercise: exercise,
                onSwapWithAI: { _, _ in /* No AI swap in library mode */ },
                onSwapManual: { replacement in
                    handleManualSwap(exercise: exercise, with: replacement)
                },
                onDismiss: { exerciseForSwap = nil }
            )
        }
        .sheet(isPresented: $showAddExercise) {
            FocusModeExerciseSearch { exercise in
                addExerciseToTemplate(exercise)
                showAddExercise = false
            }
        }
    }
    
    private var loadingView: some View {
        VStack {
            ProgressView()
                .progressViewStyle(.circular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var errorView: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(Color.warning)
            
            Text("Template not found")
                .textStyle(.bodyStrong)
                .foregroundColor(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var templateContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header stats
                headerStats
                    .padding(Space.lg)
                
                // Divider
                Rectangle()
                    .fill(Color.separatorLine)
                    .frame(height: 1)
                
                // Exercises list using ExerciseRowView
                exercisesList
            }
        }
    }
    
    private var headerStats: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if isEditing {
                // Editable name
                TextField("Template name", text: $editingName)
                    .textStyle(.bodyStrong)
                    .foregroundColor(Color.textPrimary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))

                // Editable description
                TextField("Description (optional)", text: $editingDescription)
                    .textStyle(.caption)
                    .foregroundColor(Color.textSecondary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
            } else {
                HStack(spacing: Space.lg) {
                    templateStat(value: "\(planExercises.count)", label: "Exercises")
                    templateStat(value: "\(planExercises.reduce(0) { $0 + $1.sets.count })", label: "Sets")

                    if let duration = template?.analytics?.estimatedDuration, duration > 0 {
                        templateStat(value: "~\(duration)", label: "min")
                    }
                }

                if let description = template?.description, !description.isEmpty {
                    Text(description)
                        .textStyle(.secondary)
                        .foregroundColor(Color.textSecondary)
                }
            }
        }
    }
    
    private func templateStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .textStyle(.metricM)
                .fontWeight(.bold)
                .foregroundColor(Color.textPrimary)
            Text(label)
                .textStyle(.caption)
                .foregroundColor(Color.textSecondary)
        }
    }
    
    private var exercisesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(planExercises.indices), id: \.self) { index in
                let exercise = planExercises[index]
                let isExpanded = expandedExerciseId == exercise.id

                HStack(alignment: .top, spacing: 0) {
                    if isEditing {
                        exerciseReorderControls(for: index)
                    }

                    ExerciseRowView(
                        exerciseIndex: index,
                        exercises: $planExercises,
                        selectedCell: $selectedCell,
                        isExpanded: isExpanded,
                        isPlanningMode: !isEditing,
                        showDivider: index < planExercises.count - 1,
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedExerciseId = isExpanded ? nil : exercise.id
                            }
                        },
                        onSwap: { ex, reason in
                            if reason == .manualSearch {
                                exerciseForSwap = ex
                            }
                            // For library mode, only manual swap is supported
                        },
                        onInfo: { ex in
                            selectedExerciseForInfo = ex
                        },
                        onRemove: { exIdx in
                            withAnimation(.easeOut(duration: 0.2)) {
                                _ = planExercises.remove(at: exIdx)
                            }
                        },
                        warmupCollapsed: Binding(
                            get: { warmupCollapsed[exercise.id] ?? true },
                            set: { warmupCollapsed[exercise.id] = $0 }
                        )
                    )
                }
            }

            // Add exercise button (only in edit mode)
            if isEditing {
                Button {
                    showAddExercise = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("Add Exercise")
                            .textStyle(.secondary)
                    }
                    .foregroundColor(Color.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.lg)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func handleManualSwap(exercise: PlanExercise, with replacement: Exercise) {
        if let index = planExercises.firstIndex(where: { $0.id == exercise.id }) {
            let newExercise = PlanExercise(
                exerciseId: replacement.id,
                name: replacement.name,
                sets: exercise.sets,
                primaryMuscles: replacement.primaryMuscles,
                equipment: replacement.equipment.first
            )
            planExercises[index] = newExercise
        }
    }
    
    private func loadTemplate() async {
        do {
            template = try await FocusModeWorkoutService.shared.getTemplate(id: templateId)
            if let template = template {
                planExercises = convertToPlanExercises(template)
            }
        } catch {
            AppLogger.shared.error(.app, "Failed to load template", error)
        }
        isLoading = false
    }
    
    /// Convert WorkoutTemplate to [PlanExercise] for use with ExerciseRowView
    private func convertToPlanExercises(_ template: WorkoutTemplate) -> [PlanExercise] {
        return template.exercises.enumerated().map { index, templateEx in
            let planSets = templateEx.sets.map { templateSet in
                PlanSet(
                    id: templateSet.id,
                    type: SetType(rawValue: templateSet.type) ?? .working,
                    reps: templateSet.reps,
                    weight: templateSet.weight > 0 ? templateSet.weight : nil,
                    rir: templateSet.rir,
                    isLinkedToBase: true
                )
            }

            return PlanExercise(
                id: templateEx.id,
                exerciseId: templateEx.exerciseId,
                name: templateEx.name ?? "Exercise",
                sets: planSets,
                primaryMuscles: nil,  // Template doesn't store this
                equipment: nil,
                coachNote: nil,
                position: index,
                restBetweenSets: templateEx.restBetweenSets
            )
        }
    }

    private func deleteTemplate() {
        isDeleting = true
        Task {
            do {
                try await FocusModeWorkoutService.shared.deleteTemplate(templateId: templateId)
                await MainActor.run { dismiss() }
            } catch {
                AppLogger.shared.error(.app, "Failed to delete template", error)
                isDeleting = false
            }
        }
    }

    private func startEditing() {
        originalPlanExercises = planExercises
        editingName = template?.name ?? templateName
        editingDescription = template?.description ?? ""
        isEditing = true
    }

    private func saveChanges() {
        var patch: [String: Any] = [:]

        let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != template?.name {
            patch["name"] = trimmedName
        }
        let trimmedDesc = editingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDesc != (template?.description ?? "") {
            if trimmedDesc.isEmpty {
                patch["description"] = ""
            } else {
                patch["description"] = trimmedDesc
            }
        }

        // Only include exercises if they actually changed (avoids unnecessary analytics recomputation)
        if exercisesChanged() {
            let templateExercises: [[String: Any]] = planExercises.enumerated().map { index, planEx in
                let sets: [[String: Any]] = planEx.sets.map { set in
                    let type: String = set.type?.rawValue ?? "working"
                    let weight: Double = set.weight ?? 0
                    var setDict: [String: Any] = [
                        "id": set.id,
                        "reps": set.reps,
                        "type": type,
                        "weight": weight
                    ]
                    if let rir = set.rir {
                        setDict["rir"] = rir
                    }
                    return setDict
                }
                return [
                    "id": planEx.id,
                    "exercise_id": planEx.exerciseId ?? "",
                    "name": planEx.name,
                    "position": index,
                    "sets": sets
                ] as [String: Any]
            }
            patch["exercises"] = templateExercises
        }

        isEditing = false

        guard !patch.isEmpty else { return }

        let id = templateId
        BackgroundSaveService.shared.save(entityId: id) {
            try await FocusModeWorkoutService.shared.patchTemplate(
                templateId: id,
                patch: patch,
                changeSource: "user_edit"
            )
        }

        // Track template edit
        let editTypes = patch.keys.joined(separator: ",")
        AnalyticsService.shared.templateEdited(templateId: id, editType: editTypes)
    }

    /// Compare current exercises against the snapshot taken when editing started.
    private func exercisesChanged() -> Bool {
        guard planExercises.count == originalPlanExercises.count else { return true }
        for (current, original) in zip(planExercises, originalPlanExercises) {
            if current.id != original.id { return true }
            if current.exerciseId != original.exerciseId { return true }
            if current.name != original.name { return true }
            if current.sets.count != original.sets.count { return true }
            for (cs, os) in zip(current.sets, original.sets) {
                if cs.id != os.id { return true }
                if cs.reps != os.reps { return true }
                if cs.weight != os.weight { return true }
                if cs.rir != os.rir { return true }
                if cs.type != os.type { return true }
            }
        }
        return false
    }

    // MARK: - Exercise Reorder

    private enum MoveDirection { case up, down }

    private func moveExercise(from index: Int, direction: MoveDirection) {
        let target = direction == .up ? index - 1 : index + 1
        guard target >= 0, target < planExercises.count else { return }
        planExercises.swapAt(index, target)
    }

    private func exerciseReorderControls(for index: Int) -> some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    moveExercise(from: index, direction: .up)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(index > 0 ? Color.textSecondary : Color.textTertiary.opacity(0.3))
            }
            .disabled(index == 0)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    moveExercise(from: index, direction: .down)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(index < planExercises.count - 1 ? Color.textSecondary : Color.textTertiary.opacity(0.3))
            }
            .disabled(index >= planExercises.count - 1)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, Space.md)
        .padding(.leading, Space.sm)
    }

    private func addExerciseToTemplate(_ exercise: Exercise) {
        let newSets = [
            PlanSet(
                id: UUID().uuidString,
                type: .working,
                reps: 10,
                weight: nil,
                rir: 2
            )
        ]
        let newExercise = PlanExercise(
            exerciseId: exercise.id,
            name: exercise.name,
            sets: newSets,
            primaryMuscles: exercise.primaryMuscles,
            equipment: exercise.equipment.first
        )
        planExercises.append(newExercise)
    }
}

// MARK: - Routine Detail View

struct RoutineDetailView: View {
    let routineId: String
    let routineName: String

    @ObservedObject private var saveService = BackgroundSaveService.shared
    @State private var templates: [TemplateItem] = []
    @State private var isLoading = true
    @State private var routineDescription: String?
    @State private var frequency: Int = 0
    @State private var routine: Routine?

    // Editing state
    @State private var isEditing = false
    @State private var editingName: String = ""
    @State private var editingDescription: String = ""
    @State private var editingFrequency: Int = 3
    @State private var showTemplatePicker = false

    // Delete state
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss

    private var syncState: FocusModeSyncState? {
        saveService.state(for: routineId)
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if templates.isEmpty && !isEditing {
                emptyView
            } else {
                routineContent
            }
        }
        .background(Color.bg)
        .navigationTitle(isEditing ? "" : routineName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("Done") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                    .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if let state = syncState {
                    if state.isPending {
                        HStack(spacing: 6) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                            Text("Syncing")
                                .textStyle(.secondary)
                                .foregroundColor(.textSecondary)
                        }
                    } else if state.isFailed {
                        Button("Retry") {
                            saveService.retry(entityId: routineId)
                        }
                        .foregroundColor(.warning)
                    }
                } else if !isLoading {
                    Menu {
                        Button { startEditing() } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Routine", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Color.textSecondary)
                    }
                }
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                HapticManager.destructiveAction()
                deleteRoutine()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This routine and its schedule will be permanently removed.")
        }
        .task {
            await loadRoutineTemplates()
            // Track routine view
            AnalyticsService.shared.routineViewed(routineId: routineId, templateCount: templates.count)
        }
        .onChange(of: syncState) { oldState, newState in
            if oldState != nil && newState == nil {
                isLoading = true
                Task { await loadRoutineTemplates() }
            }
        }
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerSheet(
                existingTemplateIds: Set(templates.map { $0.id }),
                onSelect: { item in
                    templates.append(item)
                    showTemplatePicker = false
                },
                onDismiss: { showTemplatePicker = false }
            )
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
                .progressViewStyle(.circular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 48))
                .foregroundColor(Color.textTertiary)

            Text("No workouts in this routine")
                .textStyle(.bodyStrong)
                .foregroundColor(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func templateRow(index: Int, template: TemplateItem) -> some View {
        if isEditing {
            HStack(spacing: Space.sm) {
                VStack(spacing: 2) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            moveTemplate(from: index, direction: .up)
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(index > 0 ? Color.textSecondary : Color.textTertiary.opacity(0.3))
                    }
                    .disabled(index == 0)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            moveTemplate(from: index, direction: .down)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(index < templates.count - 1 ? Color.textSecondary : Color.textTertiary.opacity(0.3))
                    }
                    .disabled(index >= templates.count - 1)
                }
                .buttonStyle(PlainButtonStyle())

                WorkoutRow.routineDay(
                    day: index + 1,
                    title: template.name,
                    exerciseCount: template.exerciseCount,
                    setCount: template.setCount
                )

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        _ = templates.remove(at: index)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color.destructive)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } else {
            NavigationLink(destination: TemplateDetailView(templateId: template.id, templateName: template.name)) {
                WorkoutRow.routineDay(
                    day: index + 1,
                    title: template.name,
                    exerciseCount: template.exerciseCount,
                    setCount: template.setCount
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var routineContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Header with routine info
                routineHeader
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)

                // Templates list
                VStack(spacing: Space.sm) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        templateRow(index: index, template: template)
                    }

                    if isEditing {
                        Button {
                            showTemplatePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18))
                                Text("Add Template")
                                    .textStyle(.secondary)
                            }
                            .foregroundColor(Color.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.md)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, Space.lg)

                Spacer(minLength: Space.xxl)
            }
        }
    }

    @ViewBuilder
    private var routineHeader: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: Space.sm) {
                TextField("Routine name", text: $editingName)
                    .textStyle(.bodyStrong)
                    .foregroundColor(Color.textPrimary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))

                TextField("Description (optional)", text: $editingDescription)
                    .textStyle(.caption)
                    .foregroundColor(Color.textSecondary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))

                HStack {
                    Text("Frequency")
                        .textStyle(.secondary)
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Stepper("\(editingFrequency)x per week", value: $editingFrequency, in: 1...7)
                        .textStyle(.caption)
                        .foregroundColor(Color.textSecondary)
                }
                .padding(.top, Space.xs)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.lg) {
                    routineStat(value: "\(templates.count)", label: "Workouts")
                    routineStat(value: "\(frequency)x", label: "Per Week")
                }

                if let description = routineDescription, !description.isEmpty {
                    Text(description)
                        .textStyle(.secondary)
                        .foregroundColor(Color.textSecondary)
                }
            }
        }
    }

    private func routineStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .textStyle(.metricM)
                .fontWeight(.bold)
                .foregroundColor(Color.textPrimary)
            Text(label)
                .textStyle(.caption)
                .foregroundColor(Color.textSecondary)
        }
    }

    // MARK: - Delete

    private func deleteRoutine() {
        isDeleting = true
        Task {
            do {
                try await FocusModeWorkoutService.shared.deleteRoutine(routineId: routineId)
                await MainActor.run { dismiss() }
            } catch {
                AppLogger.shared.error(.app, "Failed to delete routine", error)
                isDeleting = false
            }
        }
    }

    // MARK: - Editing

    private func startEditing() {
        editingName = routine?.name ?? routineName
        editingDescription = routine?.description ?? ""
        editingFrequency = routine?.frequency ?? max(frequency, 1)
        isEditing = true
    }

    private enum MoveDirection { case up, down }

    private func moveTemplate(from index: Int, direction: MoveDirection) {
        let target = direction == .up ? index - 1 : index + 1
        guard target >= 0, target < templates.count else { return }
        templates.swapAt(index, target)
    }

    private func saveChanges() {
        var patch: [String: Any] = [:]

        let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != (routine?.name ?? routineName) {
            patch["name"] = trimmedName
        }
        let trimmedDesc = editingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDesc != (routine?.description ?? "") {
            if trimmedDesc.isEmpty {
                patch["description"] = ""
            } else {
                patch["description"] = trimmedDesc
            }
        }
        if editingFrequency != (routine?.frequency ?? frequency) {
            patch["frequency"] = editingFrequency
        }

        let currentIds = templates.map { $0.id }
        if currentIds != (routine?.templateIds ?? []) {
            patch["template_ids"] = currentIds
        }

        isEditing = false

        guard !patch.isEmpty else { return }

        let id = routineId
        BackgroundSaveService.shared.save(entityId: id) {
            try await FocusModeWorkoutService.shared.patchRoutine(
                routineId: id,
                patch: patch
            )
        }

        // Track routine edit
        let editTypes = patch.keys.joined(separator: ",")
        AnalyticsService.shared.routineEdited(routineId: id, editType: editTypes)
    }

    // MARK: - Data Loading

    private func loadRoutineTemplates() async {
        do {
            // Fetch the actual routine to get template_ids
            let fetchedRoutine = try await FocusModeWorkoutService.shared.getRoutine(id: routineId)
            routine = fetchedRoutine
            frequency = fetchedRoutine.frequency ?? 0
            routineDescription = fetchedRoutine.description

            // Fetch only the routine's templates by ID (in parallel)
            let templateResults = await withTaskGroup(of: (String, WorkoutTemplate?).self) { group in
                for templateId in fetchedRoutine.templateIds {
                    group.addTask {
                        let template = try? await FocusModeWorkoutService.shared.getTemplate(id: templateId)
                        return (templateId, template)
                    }
                }
                var results: [(String, WorkoutTemplate?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            // Build template items preserving template_ids order
            templates = fetchedRoutine.templateIds.compactMap { tid in
                guard let (_, tmpl) = templateResults.first(where: { $0.0 == tid }),
                      let template = tmpl else { return nil }
                return TemplateItem(
                    id: template.id,
                    name: template.name,
                    exerciseCount: template.exercises.count,
                    setCount: template.exercises.reduce(0) { $0 + $1.sets.count }
                )
            }
        } catch {
            AppLogger.shared.error(.app, "Failed to load routine", error)
        }
        isLoading = false
    }
}

// MARK: - Template Picker Sheet (for adding templates to routines)

private struct TemplatePickerSheet: View {
    let existingTemplateIds: Set<String>
    let onSelect: (TemplateItem) -> Void
    let onDismiss: () -> Void

    @State private var allTemplates: [TemplateItem] = []
    @State private var isLoading = true

    private var availableTemplates: [TemplateItem] {
        allTemplates.filter { !existingTemplateIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if availableTemplates.isEmpty {
                    VStack(spacing: Space.md) {
                        Text("No more templates to add")
                            .textStyle(.secondary)
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(availableTemplates) { template in
                        Button {
                            onSelect(template)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .textStyle(.bodyStrong)
                                    .foregroundColor(Color.textPrimary)
                                Text("\(template.exerciseCount) exercises, \(template.setCount) sets")
                                    .textStyle(.caption)
                                    .foregroundColor(Color.textSecondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
        .task {
            await loadTemplates()
        }
    }

    private func loadTemplates() async {
        do {
            let fetched = try await FocusModeWorkoutService.shared.getUserTemplates()
            allTemplates = fetched.map { info in
                TemplateItem(
                    id: info.id,
                    name: info.name,
                    exerciseCount: info.exerciseCount,
                    setCount: info.setCount
                )
            }
        } catch {
            AppLogger.shared.error(.app, "Failed to load templates", error)
        }
        isLoading = false
    }
}

#if DEBUG
struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            LibraryView()
        }
    }
}
#endif
