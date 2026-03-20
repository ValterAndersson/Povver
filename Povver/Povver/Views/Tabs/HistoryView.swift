import SwiftUI
import Charts

/// History Tab - Review what happened
/// Chronological list of completed sessions with infinite scroll
struct HistoryView: View {
    @ObservedObject private var saveService = BackgroundSaveService.shared
    @State private var workouts: [HistoryWorkoutItem] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMorePages = true
    @State private var totalWorkoutCount: Int = 0
    @State private var hasAppeared = false

    /// All workouts fetched from repository (full list for pagination)
    @State private var allWorkouts: [Workout] = []

    /// Initial page size and load increment
    private let initialPageSize = 25
    private let loadMoreIncrement = 25
    
    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if workouts.isEmpty {
                emptyStateView
            } else {
                workoutsList
            }
        }
        .background(Color.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadInitialWorkouts()
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Loading history...")
                .textStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: Space.lg) {
            CoachPresenceIndicator(size: 32)

            VStack(spacing: Space.sm) {
                Text("No workouts yet")
                    .textStyle(.sectionHeader)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Your training story starts with the first session.")
                    .textStyle(.secondary)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(InsetsToken.screen)
    }
    
    // MARK: - Workouts List
    
    private var workoutsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Header
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("History")
                        .textStyle(.screenTitle)

                    Text("\(totalWorkoutCount) completed sessions")
                        .textStyle(.secondary)
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                .staggeredEntrance(index: 0, active: hasAppeared)

                // Weekly frequency chart
                if !allWorkouts.isEmpty {
                    WeeklyWorkoutChart(workouts: allWorkouts)
                        .padding(.horizontal, Space.lg)
                        .staggeredEntrance(index: 1, active: hasAppeared)

                    Divider()
                        .padding(.horizontal, Space.lg)
                }

                // Grouped by date
                LazyVStack(spacing: Space.md, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedWorkouts, id: \.date) { group in
                        Section {
                        ForEach(group.workouts) { workout in
                            NavigationLink(destination: WorkoutDetailView(workoutId: workout.id, onDelete: { deletedId in
                                allWorkouts.removeAll { $0.id == deletedId }
                                workouts.removeAll { $0.id == deletedId }
                                totalWorkoutCount = allWorkouts.count
                            })) {
                                WorkoutRow.history(
                                    name: workout.name,
                                    time: formatTime(workout.date),
                                    duration: formatDuration(workout.duration),
                                    exerciseCount: workout.exerciseCount,
                                    hasPR: workout.hasPR,
                                    isSyncing: saveService.isSaving(workout.id)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        } header: {
                            DateHeaderView(date: group.date)
                        }
                    }
                    
                    // Load more button
                    if hasMorePages {
                        Button {
                            Task { await loadMoreWorkouts() }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Load More")
                                    .textStyle(.secondary)
                                    .foregroundStyle(Color.textSecondary)
                                Spacer()
                            }
                            .padding(.vertical, Space.md)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, Space.lg)
                .staggeredEntrance(index: 2, active: hasAppeared)

                Spacer(minLength: Space.xxl)
            }
        }
        .onAppear {
            if !hasAppeared {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    hasAppeared = true
                }
            }
        }
    }
    
    // MARK: - Grouped Workouts
    
    private var groupedWorkouts: [WorkoutGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: workouts) { workout in
            calendar.startOfDay(for: workout.date)
        }
        
        return grouped.map { date, workouts in
            WorkoutGroup(date: date, workouts: workouts.sorted { $0.date > $1.date })
        }.sorted { $0.date > $1.date }
    }
    
    // MARK: - Data Loading
    
    private func loadInitialWorkouts() async {
        guard let userId = AuthService.shared.currentUser?.uid else {
            isLoading = false
            return
        }
        
        do {
            let fetchedWorkouts = try await WorkoutRepository().getWorkouts(userId: userId)
            
            // Store all workouts and set total count
            allWorkouts = fetchedWorkouts.sorted { $0.endTime > $1.endTime }
            totalWorkoutCount = allWorkouts.count
            
            // Load initial page
            let initialItems = allWorkouts
                .prefix(initialPageSize)
                .map { workout in
                    HistoryWorkoutItem(
                        id: workout.id,
                        name: workout.displayName,  // Use computed property from Workout model
                        date: workout.endTime,
                        duration: workout.endTime.timeIntervalSince(workout.startTime),
                        exerciseCount: workout.exercises.count,
                        setCount: workout.exercises.flatMap { $0.sets }.count,
                        totalVolume: workout.analytics.totalWeight,
                        hasPR: false  // TODO: Derive from analysis_insights when wired
                    )
                }
            
            workouts = Array(initialItems)
            hasMorePages = allWorkouts.count > initialPageSize
        } catch {
            print("[HistoryView] Failed to load workouts: \(error)")
        }
        
        isLoading = false
    }
    
    private func loadMoreWorkouts() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        
        let currentCount = workouts.count
        let endIndex = min(currentCount + loadMoreIncrement, allWorkouts.count)
        
        let moreItems = allWorkouts[currentCount..<endIndex].map { workout in
            HistoryWorkoutItem(
                id: workout.id,
                name: workout.displayName,
                date: workout.endTime,
                duration: workout.endTime.timeIntervalSince(workout.startTime),
                exerciseCount: workout.exercises.count,
                setCount: workout.exercises.flatMap { $0.sets }.count,
                totalVolume: workout.analytics.totalWeight,
                hasPR: false  // TODO: Derive from analysis_insights when wired
            )
        }
        
        workouts.append(contentsOf: moreItems)
        hasMorePages = workouts.count < allWorkouts.count
        isLoadingMore = false
    }
    
    // MARK: - Formatting Helpers
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - History Workout Item

struct HistoryWorkoutItem: Identifiable {
    let id: String
    let name: String
    let date: Date
    let duration: TimeInterval
    let exerciseCount: Int
    let setCount: Int
    let totalVolume: Double
    let hasPR: Bool  // TODO: Wire to analysis_insights.highlights (type: "pr") when available
}

// MARK: - Workout Group

private struct WorkoutGroup {
    let date: Date
    let workouts: [HistoryWorkoutItem]
}

// MARK: - Date Header View

private struct DateHeaderView: View {
    let date: Date
    
    private var formattedDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
    
    var body: some View {
        HStack {
            Text(formattedDate)
                .textStyle(.sectionLabel)
            Spacer()
        }
        .padding(.vertical, Space.sm)
        .background(Color.bg)
    }
}

// MARK: - Workout Detail View (Scaffold)

struct WorkoutDetailView: View {
    let workoutId: String
    var onDelete: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var saveService = BackgroundSaveService.shared
    @State private var workout: Workout?
    @State private var isLoading = true
    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showWorkoutNoteEditor = false
    @State private var editingExerciseIndex: Int? = nil

    private var syncState: FocusModeSyncState? {
        saveService.state(for: workoutId)
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let workout = workout {
                WorkoutSummaryContent(
                    workout: workout,
                    onEditWorkoutNote: { showWorkoutNoteEditor = true },
                    onEditExerciseNote: { index in editingExerciseIndex = index }
                )
            } else {
                errorView
            }
        }
        .background(Color.bg)
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let state = syncState {
                    if state.isPending {
                        HStack(spacing: 6) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                            Text("Syncing")
                                .textStyle(.secondary)
                        }
                    } else if state.isFailed {
                        Button("Retry") {
                            saveService.retry(entityId: workoutId)
                        }
                        .foregroundColor(.warning)
                    }
                } else if workout != nil {
                    Menu {
                        Button {
                            showWorkoutNoteEditor = true
                        } label: {
                            Label(
                                workout?.notes != nil ? "Edit Note" : "Add Note",
                                systemImage: "note.text"
                            )
                        }
                        Button("Edit") {
                            showEditSheet = true
                        }
                        Button("Delete Workout", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17))
                    }
                } else if !isLoading {
                    // Workout failed to load — still allow deletion
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                            .foregroundColor(.destructive)
                    }
                }
            }
        }
        .alert("Delete Workout", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { await deleteWorkout() }
            }
        } message: {
            Text("This workout will be permanently deleted. This action cannot be undone.")
        }
        .sheet(isPresented: $showEditSheet) {
            if let workout = workout {
                WorkoutEditView(workout: workout) {
                    // Will auto-reload when background save completes
                }
            }
        }
        .sheet(isPresented: $showWorkoutNoteEditor) {
            NoteEditorSheet(
                title: workout?.notes != nil ? "Edit Note" : "Add Note",
                existingNote: workout?.notes,
                onSave: { newNote in
                    showWorkoutNoteEditor = false
                    workout?.notes = newNote
                    guard let userId = AuthService.shared.currentUser?.uid else { return }
                    let noteCopy = newNote
                    BackgroundSaveService.shared.save(entityId: workoutId) {
                        try await WorkoutRepository().patchWorkoutNotes(
                            userId: userId, workoutId: workoutId, notes: noteCopy
                        )
                    }
                },
                onCancel: { showWorkoutNoteEditor = false }
            )
        }
        .sheet(isPresented: Binding(
            get: { editingExerciseIndex != nil },
            set: { if !$0 { editingExerciseIndex = nil } }
        )) {
            if let index = editingExerciseIndex,
               index < (workout?.exercises.count ?? 0) {
                let exercise = workout?.exercises[index]
                NoteEditorSheet(
                    title: "Exercise Note",
                    existingNote: exercise?.notes,
                    onSave: { newNote in
                        editingExerciseIndex = nil
                        workout?.exercises[index].notes = newNote
                        guard let userId = AuthService.shared.currentUser?.uid else { return }
                        let noteCopy = newNote
                        let idx = index
                        BackgroundSaveService.shared.save(entityId: "\(workoutId)-ex\(idx)") {
                            try await WorkoutRepository().patchExerciseNotes(
                                userId: userId, workoutId: workoutId,
                                exerciseIndex: idx, notes: noteCopy
                            )
                        }
                    },
                    onCancel: { editingExerciseIndex = nil }
                )
            }
        }
        .task {
            await loadWorkout()
            // Track workout history view
            if let workout = workout {
                let daysAgo = Calendar.current.dateComponents([.day], from: workout.endTime, to: Date()).day ?? 0
                AnalyticsService.shared.workoutHistoryViewed(workoutId: workoutId, daysAgo: daysAgo)
            }
        }
        .onChange(of: syncState) { oldState, newState in
            // Save completed (entry removed) — reload fresh data
            if oldState != nil && newState == nil {
                Task { await reloadWorkout() }
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

            Text("Workout not found")
                .textStyle(.bodyStrong)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadWorkout() async {
        guard let userId = AuthService.shared.currentUser?.uid else {
            isLoading = false
            return
        }

        do {
            workout = try await WorkoutRepository().getWorkout(id: workoutId, userId: userId)
        } catch {
            print("[WorkoutDetailView] Failed to load workout: \(error)")
        }

        isLoading = false
    }

    private func reloadWorkout() async {
        guard let userId = AuthService.shared.currentUser?.uid else { return }
        do {
            workout = try await WorkoutRepository().getWorkout(id: workoutId, userId: userId)
        } catch {
            print("[WorkoutDetailView] Failed to reload workout: \(error)")
        }
    }

    private func deleteWorkout() async {
        guard let userId = AuthService.shared.currentUser?.uid else { return }
        isDeleting = true
        do {
            // Track deletion analytics
            if let workout = workout {
                let daysAgo = Calendar.current.dateComponents([.day], from: workout.endTime, to: Date()).day ?? 0
                AnalyticsService.shared.workoutHistoryDeleted(workoutId: workoutId, daysAgo: daysAgo)
            }
            try await WorkoutRepository().deleteWorkout(userId: userId, id: workoutId)
            onDelete?(workoutId)
            dismiss()
        } catch {
            print("[WorkoutDetailView] Failed to delete workout: \(error)")
            isDeleting = false
        }
    }
}

// MARK: - Weekly Workout Chart

/// Compact bar chart showing workouts per week for the last 8 weeks.
/// Gives users a quick snapshot of their training frequency over time.
private struct WeeklyWorkoutChart: View {
    let workouts: [Workout]

    private let weekCount = 8

    private static func buildWeeklyData(from workouts: [Workout], weekCount: Int) -> [WeekBucket] {
        let calendar = Calendar.current
        let today = Date()

        // Find the Monday of the current week
        let currentWeekday = calendar.component(.weekday, from: today)
        // .weekday: 1=Sun, 2=Mon, ... 7=Sat → offset to Monday
        let daysFromMonday = (currentWeekday + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: calendar.startOfDay(for: today))!

        var buckets: [WeekBucket] = []
        for i in (0..<weekCount).reversed() {
            let monday = calendar.date(byAdding: .day, value: -7 * i, to: currentMonday)!
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: monday)!
            let count = workouts.filter { $0.endTime >= monday && $0.endTime < weekEnd }.count
            buckets.append(WeekBucket(weekStart: monday, count: count, isCurrent: i == 0))
        }
        return buckets
    }

    /// Short label: show "d" normally, "MMM d" when the month changes from the previous bucket.
    private static func weekLabel(for bucket: WeekBucket, previous: WeekBucket?) -> String {
        let cal = Calendar.current
        let day = cal.component(.day, from: bucket.weekStart)
        let showMonth = previous == nil
            || cal.component(.month, from: bucket.weekStart) != cal.component(.month, from: previous!.weekStart)

        if showMonth {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: bucket.weekStart)
        }
        return "\(day)"
    }

    var body: some View {
        let data = Self.buildWeeklyData(from: workouts, weekCount: weekCount)
        let total = data.map(\.count).reduce(0, +)
        let average = Double(total) / Double(data.count)

        // Pre-compute labels so the chart gets stable categorical strings
        let labeled: [(bucket: WeekBucket, label: String)] = data.enumerated().map { i, bucket in
            (bucket, Self.weekLabel(for: bucket, previous: i > 0 ? data[i - 1] : nil))
        }

        VStack(alignment: .leading, spacing: Space.md) {
            // Section label + average
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly frequency")
                    .font(TypographyToken.footnote)
                    .fontWeight(.medium)
                    .foregroundColor(Color.textSecondary)
                Spacer()
                Text("avg \(String(format: "%.1f", average))/wk")
                    .font(TypographyToken.footnote)
                    .foregroundColor(Color.textTertiary)
            }

            Chart(labeled, id: \.bucket.id) { item in
                BarMark(
                    x: .value("Week", item.label),
                    y: .value("Workouts", item.bucket.count)
                )
                .foregroundStyle(item.bucket.isCurrent ? Color.accent : Color.chartInactive)
                .cornerRadius(CornerRadiusToken.radiusIcon / 2)
                .annotation(position: .top, spacing: Space.xs) {
                    if item.bucket.isCurrent && item.bucket.count > 0 {
                        Text("\(item.bucket.count)")
                            .font(TypographyToken.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(Color.textPrimary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: StrokeWidthToken.hairline))
                        .foregroundStyle(Color.separatorLine)
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text("\(intVal)")
                                .font(TypographyToken.caption)
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel()
                        .font(TypographyToken.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .frame(height: 140)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
}

/// A single week bucket for the frequency chart.
private struct WeekBucket: Identifiable {
    let weekStart: Date
    let count: Int
    let isCurrent: Bool
    var id: Date { weekStart }
}

#if DEBUG
struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            HistoryView()
        }
    }
}
#endif
