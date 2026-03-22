/**
 * FocusModeWorkoutScreen.swift
 * 
 * Full-screen workout execution view - Premium Execution Surface.
 * 
 * Design principles:
 * - Strong depth + hierarchy with card elevation system
 * - Fast set entry with inline editing dock
 * - AI Copilot as first-class control (Coach button)
 * - Mode-driven reordering with visual mode distinction
 * - Finish action at bottom of flow, not header
 */

import SwiftUI

// MARK: - Auto-Advance Logic

/// Pure logic for auto-advance after set completion.
/// Extracted at file scope for testability — no SwiftUI dependencies.
enum AutoAdvance {
    struct Target {
        let exerciseIndex: Int
        let exerciseId: String
        let setId: String
    }

    /// Find the next undone set after the given exercise/set.
    /// Searches remaining sets in the same exercise first, then subsequent exercises.
    static func findNextUndoneSet(
        exercises: [FocusModeExercise],
        afterExercise exerciseId: String,
        afterSet setId: String
    ) -> Target? {
        guard let currentExerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }) else { return nil }
        let currentExercise = exercises[currentExerciseIndex]

        // Same exercise: next undone set after current
        if let currentSetIndex = currentExercise.sets.firstIndex(where: { $0.id == setId }) {
            let remaining = currentExercise.sets[(currentSetIndex + 1)...]
            if let next = remaining.first(where: { !$0.isDone }) {
                return Target(exerciseIndex: currentExerciseIndex, exerciseId: exerciseId, setId: next.id)
            }
        }

        // Next exercises
        for i in (currentExerciseIndex + 1)..<exercises.count {
            let ex = exercises[i]
            if let first = ex.sets.first(where: { !$0.isDone }) {
                return Target(exerciseIndex: i, exerciseId: ex.id, setId: first.id)
            }
        }
        return nil
    }
}

struct FocusModeWorkoutScreen: View {
    @StateObject private var service = FocusModeWorkoutService.shared
    // Initialized with empty ID because the workout doesn't exist yet at view init time.
    // Safe: WorkoutCoachViewModel.init only stores the ID — no network/Firestore calls.
    // The real ID is set via syncCoachWorkoutId() → updateWorkout() once the workout starts.
    @StateObject private var coachViewModel = WorkoutCoachViewModel(workoutId: "")
    @Environment(\.dismiss) private var dismiss
    
    // Workout source (template, routine, plan, or empty)
    let sourceTemplateId: String?
    let sourceRoutineId: String?
    let workoutName: String?
    let planBlocks: [[String: Any]]?  // Plan blocks from Canvas session_plan
    
    // Resume gate state
    @State private var showingResumeGate = false
    @State private var existingWorkoutId: String? = nil
    
    // MARK: - State Machine
    @State private var screenMode: FocusModeScreenMode = .normal
    @State private var activeSheet: FocusModeActiveSheet? = nil
    @State private var pendingSheetTask: Task<Void, Never>? = nil
    
    // List edit mode binding (synced with screenMode)
    @State private var listEditMode: EditMode = .inactive
    
    // Reorder toggle debounce
    @State private var isReorderTransitioning = false
    
    // Scroll tracking for hero collapse with hysteresis
    @State private var isHeroCollapsed = false
    @State private var measuredHeroHeight: CGFloat = 280  // Will be measured dynamically
    @State private var hasInitializedScroll = false  // Guards against false initial collapse
    
    // Debug: Show scroll values (set to true for debugging)
    #if DEBUG
    @State private var debugScrollMinY: CGFloat = 0
    #endif
    
    // Timer state
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    
    // Editor state
    @State private var editingName: String = ""
    @State private var editingStartTime: Date = Date()
    
    // Confirmation dialogs
    @State private var showingCancelConfirmation = false
    @State private var showingCompleteConfirmation = false
    @State private var showingNameEditor = false
    
    // Prevents duplicate starts
    @State private var isStartingWorkout = false

    // Error banner (auto-dismiss after 4s)
    @State private var errorBanner: String? = nil

    // Post-workout summary
    @State private var completedWorkout: CompletedWorkoutRef? = nil

    // Ghost values: last-session data fetched once per workout start
    @State private var hasFetchedLastSession = false

    // ScrollViewReader proxy — stored so logSet can trigger cross-exercise scroll
    @State private var scrollProxy: ScrollViewProxy? = nil
    
    // Template and routine data for start view
    @State private var templates: [FocusModeWorkoutService.TemplateInfo] = []
    @State private var nextWorkoutInfo: FocusModeWorkoutService.NextWorkoutInfo? = nil
    @State private var isLoadingStartData = false
    @State private var showingTemplatePicker = false
    
    init(
        templateId: String? = nil,
        routineId: String? = nil,
        name: String? = nil,
        planBlocks: [[String: Any]]? = nil
    ) {
        self.sourceTemplateId = templateId
        self.sourceRoutineId = routineId
        self.workoutName = name
        self.planBlocks = planBlocks
    }
    
    // MARK: - Computed Properties
    
    /// Derive selectedCell from screenMode for backward compatibility
    private var selectedCell: Binding<FocusModeGridCell?> {
        Binding(
            get: {
                if case .editingSet(let exerciseId, let setId, let cellType) = screenMode {
                    switch cellType {
                    case .weight: return .weight(exerciseId: exerciseId, setId: setId)
                    case .reps: return .reps(exerciseId: exerciseId, setId: setId)
                    case .rir: return .rir(exerciseId: exerciseId, setId: setId)
                    }
                }
                return nil
            },
            set: { newValue in
                if let cell = newValue {
                    let cellType: FocusModeEditCellType
                    switch cell {
                    case .weight: cellType = .weight
                    case .reps: cellType = .reps
                    case .rir: cellType = .rir
                    case .done: cellType = .weight  // Default to weight for done cells
                    }
                    screenMode = .editingSet(exerciseId: cell.exerciseId, setId: cell.setId, cellType: cellType)
                } else {
                    screenMode = .normal
                }
            }
        )
    }
    
    /// Active exercise based on current mode or first incomplete
    private var activeExerciseId: String? {
        if case .editingSet(let exerciseId, _, _) = screenMode {
            return exerciseId
        }
        return service.workout?.exercises.first { !$0.isComplete }?.instanceId
    }
    
    /// Compute contextual density for an exercise based on completion state and position
    private func exerciseDensity(for exercise: FocusModeExercise) -> ExerciseDensity {
        guard let workout = service.workout else { return .active }
        let firstActiveIndex = workout.exercises.firstIndex { !$0.isComplete }
        let exerciseIndex = workout.exercises.firstIndex { $0.id == exercise.id }
        guard let eIdx = exerciseIndex else { return .active }

        if exercise.isComplete { return .completed }
        if eIdx == firstActiveIndex { return .active }
        return .upcoming
    }

    /// Total and completed sets for progress display
    private var totalSets: Int {
        service.workout?.exercises.flatMap { $0.sets }.count ?? 0
    }
    
    private var completedSets: Int {
        service.workout?.exercises.flatMap { $0.sets }.filter { $0.isDone }.count ?? 0
    }
    
    var body: some View {
        mainContent
            .navigationBarHidden(true)
            .toolbar(.visible, for: .tabBar)
            .onChange(of: screenMode) { _, newMode in
                listEditMode = newMode.isReordering ? .active : .inactive
            }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
            }
            .fullScreenCover(item: $completedWorkout, onDismiss: {
                dismiss()
            }) { completed in
                WorkoutCompletionSummary(workoutId: completed.id) {
                    completedWorkout = nil
                }
            }
            .overlay(alignment: .top) {
                if let msg = errorBanner {
                    Banner(title: "Sync Issue", message: msg, kind: .warning)
                        .padding(.horizontal, Space.md)
                        .padding(.top, Space.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { withAnimation(.easeOut(duration: MotionToken.fast)) { errorBanner = nil } }
                }
            }
            .animation(.easeInOut(duration: MotionToken.fast), value: errorBanner)
            .overlay(alignment: .bottom) {
                if service.pendingUndo != nil {
                    UndoToast(undoLabel(for: service.pendingUndo), onUndo: {
                        withAnimation(MotionToken.snappy) {
                            service.performUndo()
                        }
                    }, onDismiss: {
                        withAnimation(.easeOut(duration: MotionToken.fast)) {
                            service.clearUndo()
                        }
                    })
                    .padding(.bottom, Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: MotionToken.fast), value: service.pendingUndo != nil)
            .onChange(of: service.workout != nil) { _, isActive in
                UIApplication.shared.isIdleTimerDisabled = isActive
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                stopTimer()
            }
            .task {
                await startWorkoutIfNeeded()
            }
            .modifier(WorkoutAlertsModifier(
                showingCompleteConfirmation: $showingCompleteConfirmation,
                showingNameEditor: $showingNameEditor,
                editingName: $editingName,
                showingCancelConfirmation: $showingCancelConfirmation,
                showingResumeGate: $showingResumeGate,
                onFinish: finishWorkout,
                onUpdateName: updateWorkoutName,
                onDiscard: discardWorkout,
                onResume: startTimer,
                onDiscardAndStartNew: discardAndStartNewWorkout
            ))
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                customHeaderBar

                if screenMode.isReordering {
                    ReorderModeBanner(onDone: toggleReorderMode)
                }

                ZStack {
                    Color.bgWorkout.ignoresSafeArea()

                    if let workout = service.workout {
                        workoutContent(workout, safeAreaBottom: geometry.safeAreaInsets.bottom)
                    } else {
                        workoutStartView
                    }
                }
            }
            .background(Color.bgWorkout)
        }
    }

    private func discardAndStartNewWorkout() {
        Task {
            if existingWorkoutId != nil {
                do {
                    try await service.cancelWorkout()
                    if let planBlocks = planBlocks {
                        _ = try await service.startWorkoutFromPlan(plan: planBlocks)
                    } else if sourceTemplateId != nil || sourceRoutineId != nil {
                        _ = try await service.startWorkout(
                            name: workoutName,
                            sourceTemplateId: sourceTemplateId,
                            sourceRoutineId: sourceRoutineId
                        )
                    } else {
                        _ = try await service.startWorkout(name: "Workout")
                    }
                    resetTimerForNewWorkout()
                } catch {
                    print("Failed to discard and start new: \(error)")
                }
            }
        }
    }
    
    // MARK: - Sheet Content
    
    @ViewBuilder
    private func sheetContent(for sheet: FocusModeActiveSheet) -> some View {
        switch sheet {
        case .coach:
            WorkoutCoachView(viewModel: coachViewModel)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .exerciseSearch:
            FocusModeExerciseSearch { exercise in
                addExercise(exercise)
                activeSheet = nil
            }
        case .startTimeEditor:
            startTimeEditorSheet
        case .finishWorkout:
            FinishWorkoutSheet(
                elapsedTime: elapsedTime,
                completedSets: completedSets,
                totalSets: totalSets,
                exerciseCount: service.workout?.exercises.count ?? 0,
                workoutNotes: service.workout?.notes,
                showSaveToTemplate: service.hasTemplateChanges,
                onComplete: {
                    activeSheet = nil
                    finishWorkout()
                },
                onDiscard: {
                    activeSheet = nil
                    showingCancelConfirmation = true
                },
                onDismiss: {
                    activeSheet = nil
                },
                onSaveToTemplate: {
                    Task { await service.saveChangesToTemplate() }
                }
            )
        case .exerciseDetail(let exerciseId, let exerciseName):
            ExerciseDetailSheet(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                onDismiss: { activeSheet = nil }
            )
            .presentationDetents([.medium, .large])
        case .exercisePerformance(let exerciseId, let exerciseName):
            ExercisePerformanceSheet(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                onDismiss: { activeSheet = nil }
            )
        case .noteEditorWorkout:
            NoteEditorSheet(
                title: "Workout Note",
                existingNote: service.workout?.notes,
                onSave: { note in
                    activeSheet = nil
                    Task {
                        do {
                            try await service.updateWorkoutNotes(note)
                        } catch {
                            print("Failed to update workout notes: \(error)")
                        }
                    }
                },
                onCancel: { activeSheet = nil }
            )
        case .noteEditorExercise(let exerciseInstanceId):
            let exercise = service.workout?.exercises.first(where: { $0.instanceId == exerciseInstanceId })
            NoteEditorSheet(
                title: "Exercise Note",
                existingNote: exercise?.notes,
                onSave: { note in
                    activeSheet = nil
                    Task {
                        do {
                            try await service.updateExerciseNotes(exerciseInstanceId: exerciseInstanceId, notes: note)
                        } catch {
                            print("Failed to update exercise notes: \(error)")
                        }
                    }
                },
                onCancel: { activeSheet = nil }
            )
        case .exerciseSwap(let exercise):
            ExerciseSwapSheet(
                currentExercise: PlanExercise(
                    id: exercise.instanceId,
                    exerciseId: exercise.exerciseId,
                    name: exercise.name,
                    sets: exercise.sets.map { set in
                        PlanSet(
                            id: set.id,
                            type: SetType(rawValue: set.setType.rawValue) ?? .working,
                            reps: set.displayReps ?? 10,
                            weight: set.displayWeight,
                            rir: set.displayRir
                        )
                    }
                ),
                onSwapWithAI: { _, _ in },
                onSwapManual: { replacement in
                    activeSheet = nil
                    Task {
                        do {
                            try await service.swapExercise(
                                exerciseInstanceId: exercise.instanceId,
                                newExerciseId: replacement.id ?? "",
                                newExerciseName: replacement.name
                            )
                        } catch {
                            print("[ExerciseSwap] Failed: \(error)")
                        }
                    }
                },
                onDismiss: { activeSheet = nil }
            )
        case .setTypePicker, .moreActions:
            // Handled in FocusModeSetGrid
            EmptyView()
        }
    }
    
    // MARK: - Sheet Presentation Helper
    
    /// Present a sheet with deterministic gating:
    /// - Clears editor/reorder mode first
    /// - Waits for animation to complete before presenting
    private func presentSheet(_ sheet: FocusModeActiveSheet) {
        // Cancel any pending presentation
        pendingSheetTask?.cancel()

        if screenMode.isReordering {
            // Exit reorder mode first, then present on next run loop
            withAnimation(.easeOut(duration: MotionToken.fast)) {
                screenMode = .normal
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + MotionToken.fast) {
                guard self.screenMode == .normal, self.activeSheet == nil else { return }
                self.activeSheet = sheet
            }
        } else if screenMode.isEditing {
            // Close editor first, then present
            withAnimation(.easeOut(duration: MotionToken.fast)) {
                screenMode = .normal
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + MotionToken.fast) {
                guard self.screenMode == .normal, self.activeSheet == nil else { return }
                self.activeSheet = sheet
            }
        } else {
            activeSheet = sheet
        }
    }
    
    // MARK: - Reorder Toggle
    
    private func toggleReorderMode() {
        guard !isReorderTransitioning else { return }

        isReorderTransitioning = true

        // Exit editing mode first if needed
        if screenMode.isEditing {
            withAnimation(.easeOut(duration: MotionToken.fast)) {
                screenMode = .normal
            }
        }

        withAnimation(.spring(response: 0.2)) {
            screenMode = screenMode.isReordering ? .normal : .reordering
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Re-enable after transition
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionToken.fast) {
            isReorderTransitioning = false
        }
    }
    
    // MARK: - Workout Start View
    
    private var workoutStartView: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                Spacer(minLength: 40)

                // Icon
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 48))
                    .foregroundColor(Color.accent)

                Text("Start a Workout")
                    .textStyle(.screenTitle)
                    .foregroundColor(Color.textPrimary)

                if isLoadingStartData {
                    ProgressView()
                        .padding(.vertical, Space.lg)
                } else {
                    VStack(spacing: Space.lg) {
                        // Tier 2 hero card + primary CTA when a scheduled workout exists
                        if let nextInfo = nextWorkoutInfo, nextInfo.hasNextWorkout {
                            // Hero card: workout info
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(nextInfo.template?.name ?? "Next Scheduled")
                                    .textStyle(.bodyStrong)
                                    .foregroundColor(Color.textPrimary)

                                Text("Day \(nextInfo.templateIndex + 1) of \(nextInfo.templateCount)")
                                    .textStyle(.secondary)
                                    .foregroundColor(Color.textSecondary)

                                if let template = nextInfo.template {
                                    Text("\(template.exerciseCount) exercises")
                                        .textStyle(.caption)
                                        .foregroundColor(Color.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.lg)
                            .padding(.vertical, Space.lg)
                            .background(Color.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous))
                            .shadowStyle(ShadowsToken.level1)

                            // Full-width emerald CTA
                            PovverButton("Start Session") {
                                Task { await startFromNextWorkout() }
                            }

                            // Secondary text links
                            VStack(spacing: Space.md) {
                                Button {
                                    Task { await startEmptyWorkout() }
                                } label: {
                                    Text("Start Empty Workout")
                                        .textStyle(.secondary)
                                        .foregroundColor(Color.textSecondary)
                                }
                                .buttonStyle(PlainButtonStyle())

                                if !templates.isEmpty {
                                    Button {
                                        showingTemplatePicker = true
                                    } label: {
                                        Text("From Template")
                                            .textStyle(.secondary)
                                            .foregroundColor(Color.textSecondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.top, Space.sm)
                        } else {
                            // No scheduled workout: empty workout as primary CTA
                            PovverButton("Start Empty Workout") {
                                Task { await startEmptyWorkout() }
                            }

                            // From Template as secondary text link
                            if !templates.isEmpty {
                                Button {
                                    showingTemplatePicker = true
                                } label: {
                                    Text("From Template")
                                        .textStyle(.secondary)
                                        .foregroundColor(Color.textSecondary)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(.top, Space.sm)
                            }
                        }
                    }
                    .padding(.horizontal, Space.lg)
                }

                Spacer()
            }
            .padding(.top, Space.xl)
        }
        .task {
            await loadStartViewData()
        }
        .sheet(isPresented: $showingTemplatePicker) {
            templatePickerSheet
        }
    }
    
    /// Load templates and next workout info for start view.
    /// Uses prefetched caches when available (populated by prefetchLibraryData at auth),
    /// falls back to on-demand network calls.
    private func loadStartViewData() async {
        guard !isLoadingStartData else { return }
        isLoadingStartData = true
        defer { isLoadingStartData = false }

        // Use prefetched caches if available
        let cachedTemplates = service.cachedTemplates
        let cachedNext = service.cachedNextWorkout

        // Load templates (from cache or network) and next workout in parallel
        async let templatesTask: [FocusModeWorkoutService.TemplateInfo] = {
            if let cached = cachedTemplates { return cached }
            do { return try await service.getUserTemplates() }
            catch { print("[FocusModeWorkoutScreen] getUserTemplates failed: \(error)"); return [] }
        }()

        async let nextWorkoutTask: FocusModeWorkoutService.NextWorkoutInfo? = {
            if let cached = cachedNext { return cached }
            do { return try await service.getNextWorkout() }
            catch { print("[FocusModeWorkoutScreen] getNextWorkout failed: \(error)"); return nil }
        }()

        templates = await templatesTask
        nextWorkoutInfo = await nextWorkoutTask
    }
    
    /// Start workout from routine cursor (next scheduled)
    private func startFromNextWorkout() async {
        guard let nextInfo = nextWorkoutInfo, let template = nextInfo.template else { return }
        guard !isStartingWorkout else { return }
        
        isStartingWorkout = true
        defer { isStartingWorkout = false }
        
        do {
            // P0-2 Fix: Pass routineId for cursor advancement
            _ = try await service.startWorkout(
                name: template.name,
                sourceTemplateId: template.id,
                sourceRoutineId: nextInfo.routineId  // Required for cursor to advance on complete
            )
            resetTimerForNewWorkout()
        } catch {
            print("Failed to start from next workout: \(error)")
        }
    }
    
    /// Start workout from selected template
    private func startFromTemplate(_ template: FocusModeWorkoutService.TemplateInfo) async {
        guard !isStartingWorkout else { return }
        
        isStartingWorkout = true
        defer { isStartingWorkout = false }
        
        do {
            _ = try await service.startWorkout(
                name: template.name,
                sourceTemplateId: template.id,
                sourceRoutineId: nil
            )
            resetTimerForNewWorkout()
        } catch {
            print("Failed to start from template: \(error)")
        }
    }
    
    /// Template picker sheet - uses SheetScaffold for v1.1 consistency
    private var templatePickerSheet: some View {
        SheetScaffold(
            title: "Choose Template",
            doneTitle: nil,
            onCancel: { showingTemplatePicker = false }
        ) {
            List {
                ForEach(templates) { template in
                    Button {
                        showingTemplatePicker = false
                        Task { await startFromTemplate(template) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.name)
                                    .textStyle(.secondary).fontWeight(.medium)
                                    .foregroundColor(Color.textPrimary)

                                Text("\(template.exerciseCount) exercises • \(template.setCount) sets")
                                    .textStyle(.caption)
                                    .foregroundColor(Color.textSecondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color.textTertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .listStyle(.plain)
        }
        .presentationDetents([.medium, .large])
    }
    
    // startOptionButton removed — replaced by Tier 2 hero card + PovverButton CTA in workoutStartView
    
    // MARK: - Workout Content
    
    @ViewBuilder
    private func workoutContent(_ workout: FocusModeWorkout, safeAreaBottom: CGFloat) -> some View {
        if screenMode.isReordering {
            // Reorder mode: simplified list with drag handles
            // All other interactions are disabled
            List {
                ForEach(workout.exercises) { exercise in
                    ExerciseReorderRow(exercise: exercise)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                .onMove { from, to in
                    reorderExercisesNew(from: from, to: to)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $listEditMode)
        } else {
            // Normal mode: Hero + exercise sections with scroll tracking
            ScrollView {
                ScrollViewReader { scrollProxy in
                LazyVStack(spacing: 0, pinnedViews: []) {
                    // Constant 8pt top padding - always present, no jumpiness
                    Color.clear.frame(height: Space.sm)
                    
                    // HERO: Workout identity + large timer
                    // Use .onGeometryChange for continuous scroll tracking (iOS 16+)
                    WorkoutHero(
                        workoutName: workout.name ?? "Workout",
                        workoutNotes: workout.notes,
                        startTime: workout.startTime,
                        elapsedTime: elapsedTime,
                        completedSets: completedSets,
                        totalSets: totalSets,
                        hasExercises: !workout.exercises.isEmpty,
                        onNameTap: {
                            editingName = workout.name ?? "Workout"
                            showingNameEditor = true
                        },
                        onTimerTap: {
                            presentSheet(.startTimeEditor)
                        },
                        onCoachTap: {
                            presentSheet(.coach)
                        },
                        onReorderTap: toggleReorderMode,
                        onMenuAction: { action in
                            handleHeroMenuAction(action, workout: workout)
                        }
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("workoutScroll"))
                    } action: { newFrame in
                        // Continuous scroll tracking via onGeometryChange
                        let heroBottom = newFrame.maxY
                        let collapseThreshold: CGFloat = 100
                        let expandThreshold: CGFloat = 150
                        
                        // Update measured height
                        if newFrame.height > 0 {
                            measuredHeroHeight = newFrame.height
                        }
                        
                        #if DEBUG
                        debugScrollMinY = newFrame.minY
                        // Throttled debug logging
                        if Int(newFrame.minY) % 50 == 0 {
                            print("🔍 [ScrollDebug] heroMinY=\(Int(newFrame.minY)) heroMaxY=\(Int(heroBottom)) collapsed=\(isHeroCollapsed) initialized=\(hasInitializedScroll)")
                        }
                        #endif
                        
                        // GUARD: On first render, confirm hero is visible before allowing collapse
                        // This prevents false collapse when onGeometryChange fires with stale values
                        if !hasInitializedScroll {
                            // Hero is considered "properly visible" when bottom > expandThreshold
                            if heroBottom > expandThreshold {
                                hasInitializedScroll = true
                                print("🔍 [ScrollDebug] ✅ Scroll initialized (heroBottom=\(Int(heroBottom)))")
                            }
                            return  // Skip collapse detection until initialized
                        }
                        
                        // Hysteresis-based collapse detection (only after initialization)
                        if heroBottom < collapseThreshold && !isHeroCollapsed {
                            print("🔍 [ScrollDebug] → COLLAPSING")
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHeroCollapsed = true
                            }
                        } else if heroBottom > expandThreshold && isHeroCollapsed {
                            print("🔍 [ScrollDebug] → EXPANDING")
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHeroCollapsed = false
                            }
                        }
                    }
                    
                    // Empty state OR exercise list
                    if workout.exercises.isEmpty {
                        // Empty state: instructional card
                        EmptyStateCard {
                            presentSheet(.exerciseSearch)
                        }
                        .padding(.top, Space.lg)
                        
                        // No bottom CTA for empty state - discard is in hero ellipsis menu
                        // Just add safe area padding
                        Color.clear
                            .frame(height: safeAreaBottom + Space.lg)
                    } else {
                        // Exercises - each as a card with full set grid
                        ForEach(workout.exercises) { exercise in
                            let isActive = exercise.instanceId == activeExerciseId
                            let isCompleted = exercise.isComplete
                            let density = exerciseDensity(for: exercise)

                            ExerciseCardContainer(isActive: isActive, isCompleted: isCompleted) {
                                FocusModeExerciseSectionNew(
                                    exercise: exercise,
                                    isActive: isActive,
                                    density: density,
                                    screenMode: $screenMode,
                                    onLogSet: logSet,
                                    onPatchField: patchField,
                                    onAddSet: {
                                        let lastWorkingSet = exercise.sets.last(where: { !$0.isWarmup }) ?? exercise.sets.last
                                        addSet(to: exercise.instanceId,
                                               weight: lastWorkingSet?.displayWeight,
                                               reps: lastWorkingSet?.displayReps ?? 10,
                                               rir: lastWorkingSet?.displayRir ?? 2)
                                    },
                                    onRemoveSet: { setId in removeSet(exerciseId: exercise.instanceId, setId: setId) },
                                    onRemoveExercise: { removeExercise(exerciseId: exercise.instanceId) },
                                    onAutofill: { autofillExercise(exercise.instanceId) },
                                    onShowDetails: { presentSheet(.exerciseDetail(exerciseId: exercise.exerciseId, exerciseName: exercise.name)) },
                                    onShowPerformance: { presentSheet(.exercisePerformance(exerciseId: exercise.exerciseId, exerciseName: exercise.name)) },
                                    onEditNote: { presentSheet(.noteEditorExercise(exerciseInstanceId: exercise.instanceId)) },
                                    onSwapExercise: { presentSheet(.exerciseSwap(exercise: exercise)) },
                                    ghostValues: ghostValues(for: exercise),
                                    isLastExercise: exercise.instanceId == workout.exercises.last?.instanceId
                                )
                            }
                            .padding(.top, Space.md)
                            .animation(MotionToken.snappy, value: density)
                        }
                        
                        // Add Exercise Button (hidden during reorder mode via parent check)
                        addExerciseButton
                            .padding(.top, Space.lg)
                        
                        // Bottom CTA Section: Finish + Discard
                        bottomCTASection(safeAreaBottom: safeAreaBottom)
                    }
                }
                .padding(.horizontal, Space.md)
                .onAppear { self.scrollProxy = scrollProxy }
                .onChange(of: screenMode) { _, newMode in
                    // Scroll to editing dock when editing starts
                    if case .editingSet(let exerciseId, let setId, let cellType) = newMode {
                        let cell: FocusModeGridCell
                        switch cellType {
                        case .weight: cell = .weight(exerciseId: exerciseId, setId: setId)
                        case .reps: cell = .reps(exerciseId: exerciseId, setId: setId)
                        case .rir: cell = .rir(exerciseId: exerciseId, setId: setId)
                        }
                        // Delay to let keyboard animation start
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: MotionToken.medium)) {
                                scrollProxy.scrollTo(cell, anchor: .bottom)
                            }
                        }
                    }
                }
                } // ScrollViewReader
            }
            .coordinateSpace(name: "workoutScroll")
            .scrollDismissesKeyboard(.interactively)
        }
    }
    
    /// Handle hero menu actions
    private func handleHeroMenuAction(_ action: WorkoutHero.HeroMenuAction, workout: FocusModeWorkout) {
        switch action {
        case .editName:
            editingName = workout.name ?? "Workout"
            showingNameEditor = true
        case .editStartTime:
            presentSheet(.startTimeEditor)
        case .addNote:
            presentSheet(.noteEditorWorkout)
        case .reorder:
            toggleReorderMode()
        case .discard:
            showingCancelConfirmation = true
        }
    }
    
    // MARK: - Reorder Exercises
    
    private func reorderExercisesNew(from source: IndexSet, to destination: Int) {
        // Apply the reorder to the service
        service.reorderExercises(from: source, to: destination)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - Computed Flags for Nav
    
    /// Whether to show collapsed actions (Coach/Reorder/More)
    /// True when hero is collapsed AND not in reorder mode
    private var showCollapsedActions: Bool {
        isHeroCollapsed && !screenMode.isReordering
    }
    
    /// Whether reorder is possible (>= 2 exercises)
    private var canReorder: Bool {
        (service.workout?.exercises.count ?? 0) >= 2
    }
    
    // MARK: - Nav Bar (Balanced: Name left, Timer center, Actions right)
    
    /// Balanced nav bar (P0.4 + P0.5):
    /// - Workout name on left when collapsed (context)
    /// - Timer always centered
    /// - Coach + Reorder + More icons on right when collapsed
    /// - All icons use opacity/hitTesting for stable layout (no reflow)
    private var customHeaderBar: some View {
        VStack(spacing: 0) {
            if service.workout != nil {
                // Simple header: Timer (left), Reorder + AI (right)
                // No workout name, no ellipsis menu
                HStack(spacing: 0) {
                    // Timer on left (hidden when hero visible)
                    NavCompactTimer(elapsedTime: elapsedTime) {
                        presentSheet(.startTimeEditor)
                    }
                    .opacity(showCollapsedActions ? 1.0 : 0)
                    .allowsHitTesting(showCollapsedActions)
                    
                    Spacer()
                    
                    // Reorder + AI icons on right
                    HStack(spacing: 2) {
                        // Reorder icon
                        Button {
                            if canReorder { toggleReorderMode() }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(canReorder ? Color.textSecondary : Color.textTertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .opacity(showCollapsedActions && canReorder ? 1.0 : 0)
                        .allowsHitTesting(showCollapsedActions && canReorder)
                        .accessibilityHidden(!(showCollapsedActions && canReorder))
                        .accessibilityLabel("Reorder exercises")
                        
                        // AI/Coach icon
                        Button {
                            presentSheet(.coach)
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(Color.accent)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .overlay(alignment: .topTrailing) {
                                    Circle()
                                        .fill(Color.accent)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 2, y: -2)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .opacity(showCollapsedActions ? 1.0 : 0)
                        .allowsHitTesting(showCollapsedActions)
                        .accessibilityHidden(!showCollapsedActions)
                        .accessibilityLabel("Coach")
                    }
                }
                .frame(height: 52)  // Fixed nav bar height
                .padding(.horizontal, Space.md)
                .animation(.easeInOut(duration: 0.2), value: isHeroCollapsed)
                .animation(.easeInOut(duration: 0.2), value: screenMode.isReordering)
            } else {
                // Pre-workout state (tab bar is visible for navigation)
                HStack {
                    Text("Train")
                        .textStyle(.sectionHeader)
                        .foregroundColor(Color.textPrimary)

                    Spacer()
                    // No X button - users can navigate via tab bar
                }
                .frame(height: 52)  // Fixed nav bar height
                .padding(.horizontal, Space.md)
            }
            
            Divider()
        }
        .background(Color.bg)
    }
    
    // MARK: - Start Time Editor Sheet - uses SheetScaffold for v1.1 consistency
    
    private var startTimeEditorSheet: some View {
        SheetScaffold(
            title: "Edit Start Time",
            doneTitle: "Save",
            onCancel: { activeSheet = nil },
            onDone: {
                Task {
                    do {
                        try await service.updateStartTime(editingStartTime)
                        print("✅ Start time updated to: \(editingStartTime)")
                    } catch {
                        print("❌ Failed to update start time: \(error)")
                    }
                }
                activeSheet = nil
            }
        ) {
            VStack(spacing: 0) {
                // Time picker - wheel style with explicit height
                DatePicker(
                    "",
                    selection: $editingStartTime,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 216)  // Standard wheel picker height
                .frame(maxWidth: .infinity)
                .padding(.top, Space.lg)
                
                // Timezone info
                HStack {
                    Image(systemName: "globe")
                        .foregroundColor(Color.textSecondary)
                    Text(TimeZone.current.identifier)
                        .textStyle(.caption)
                        .foregroundColor(Color.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                editingStartTime = service.workout?.startTime ?? Date()
            }
        }
        .presentationDetents([.large])
    }
    
    private func formatStartTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday at' h:mm a"
        } else {
            formatter.dateFormat = "MMM d 'at' h:mm a"
        }
        
        return formatter.string(from: date)
    }
    
    private func updateWorkoutName(_ name: String) {
        guard !name.isEmpty else { return }
        Task {
            do {
                try await service.updateWorkoutName(name)
                print("✅ Workout name updated to: \(name)")
            } catch {
                print("❌ Failed to update workout name: \(error)")
            }
        }
    }
    
    private func discardWorkout() {
        stopTimer()
        Task {
            do {
                try await service.cancelWorkout()
                print("✅ Workout discarded")
                // Dismiss after successful cancel
                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("❌ Failed to discard workout: \(error)")
                // Still dismiss even on error (local state is cleared)
                await MainActor.run {
                    dismiss()
                }
            }
        }
    }
    
    private func finishWorkout() {
        stopTimer()
        Task {
            do {
                let archivedId = try await service.completeWorkout()
                print("✅ Workout completed and archived with ID: \(archivedId)")
                await MainActor.run {
                    completedWorkout = CompletedWorkoutRef(id: archivedId)
                }
            } catch {
                print("❌ Failed to complete workout: \(error)")
                await MainActor.run {
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: Space.lg) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Starting workout...")
                .textStyle(.secondary)
                .foregroundColor(Color.textSecondary)
        }
    }
    
    // MARK: - Add Exercise Button
    
    private var addExerciseButton: some View {
        Button { presentSheet(.exerciseSearch) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                Text("Add Exercise")
                    .textStyle(.secondary).fontWeight(.medium)
            }
            .foregroundColor(Color.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentMuted)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Bottom CTA Section
    
    /// Bottom CTA section with Finish and Discard buttons
    /// This replaces the nav bar Finish button for better layout
    private func bottomCTASection(safeAreaBottom: CGFloat) -> some View {
        VStack(spacing: Space.md) {
            // Finish Workout - Primary CTA
            Button {
                presentSheet(.finishWorkout)
            } label: {
                Text("Finish Workout")
                    .textStyle(.bodyStrong)
                    .foregroundColor(.textInverse)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
            
            // Discard Workout - Destructive secondary (text link style)
            Button {
                showingCancelConfirmation = true
            } label: {
                Text("Discard Workout")
                    .textStyle(.secondary).fontWeight(.medium)
                    .foregroundColor(Color.destructive)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.top, Space.xl)
        .padding(.bottom, safeAreaBottom + Space.lg)
    }
    
    // MARK: - Timer
    
    /// Sync coach VM with current workout ID so conversation persists across sheet opens.
    private func syncCoachWorkoutId() {
        if let workoutId = service.workout?.id {
            coachViewModel.updateWorkout(workoutId)
        }
    }

    /// Start the elapsed time timer. Guards against double-start.
    /// Timer derives elapsed time from workout.startTime (single source of truth).
    private func startTimer() {
        guard let workout = service.workout else { return }

        // Guard against double-start
        guard timer == nil else { return }

        // Sync coach VM with current workout
        syncCoachWorkoutId()

        // Fetch last-session data for ghost values (once per workout session)
        if !hasFetchedLastSession {
            hasFetchedLastSession = true
            Task { await service.fetchLastSessionData() }
        }

        // Reset UI state
        screenMode = .normal
        elapsedTime = Date().timeIntervalSince(workout.startTime)
        
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if let workout = service.workout {
                    elapsedTime = Date().timeIntervalSince(workout.startTime)
                }
            }
        }
        // Keep firing during scroll tracking (default mode pauses during UIScrollView interaction)
        RunLoop.current.add(newTimer, forMode: .common)
        timer = newTimer
    }
    
    /// Stop the timer and reset elapsed time.
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsedTime = 0
    }
    
    /// Reset timer state for a new workout (derives from new startTime).
    private func resetTimerForNewWorkout() {
        stopTimer()
        startTimer()
    }
    
    // MARK: - Actions
    
    private func startWorkoutIfNeeded() async {
        // Existing workout - just start timer
        guard service.workout == nil else {
            startTimer()
            return
        }

        // Guard against duplicate concurrent starts
        guard !isStartingWorkout else { return }

        // Run active workout check and start-view data load in parallel
        // so the start view populates immediately if no active workout exists
        async let activeWorkoutCheck: FocusModeWorkout? = {
            do { return try await service.getActiveWorkout() }
            catch {
                print("[FocusModeWorkoutScreen] getActiveWorkout failed: \(error)")
                return nil
            }
        }()
        async let startDataPreload: Void = loadStartViewData()

        let existingWorkout = await activeWorkoutCheck
        _ = await startDataPreload

        if let existingWorkout = existingWorkout {
            // Found existing - show resume gate
            existingWorkoutId = existingWorkout.id
            showingResumeGate = true
            return
        }

        // Start from template/routine/plan if specified
        if sourceTemplateId != nil || sourceRoutineId != nil || planBlocks != nil {
            isStartingWorkout = true
            defer { isStartingWorkout = false }

            do {
                _ = try await service.startWorkout(
                    name: workoutName,
                    sourceTemplateId: sourceTemplateId,
                    sourceRoutineId: sourceRoutineId,
                    plan: planBlocks
                )
                resetTimerForNewWorkout()
            } catch {
                print("Failed to start workout: \(error)")
            }
        }
    }
    
    private func startEmptyWorkout() async {
        // Guard against duplicate concurrent starts
        guard !isStartingWorkout else { return }
        
        isStartingWorkout = true
        defer { isStartingWorkout = false }
        
        do {
            _ = try await service.startWorkout(name: "Workout")
            resetTimerForNewWorkout()
        } catch {
            print("Failed to start workout: \(error)")
        }
    }
    
    private func addExercise(_ exercise: Exercise) {
        Task {
            do {
                try await service.addExercise(exercise: exercise)
            } catch {
                print("Add exercise failed: \(error)")
                showError("Failed to add exercise")
            }
        }
    }
    
    private func logSet(exerciseId: String, setId: String, weight: Double?, reps: Int, rir: Int?) {
        // Auto-advance: find next undone set immediately (before async call mutates state)
        let exercises = service.workout?.exercises ?? []
        let nextTarget = AutoAdvance.findNextUndoneSet(
            exercises: exercises,
            afterExercise: exerciseId,
            afterSet: setId
        )

        // Apply auto-advance focus synchronously for responsive feel
        if let next = nextTarget {
            let hasGhosts = ghostValues(for: exercises[next.exerciseIndex])[next.setId]?.hasValues ?? false

            withAnimation(MotionToken.snappy) {
                if hasGhosts {
                    // Ghost values present — highlight done button (user can tap to confirm)
                    screenMode = .normal
                } else {
                    // No ghosts — enter weight editing so user can type immediately
                    screenMode = .editingSet(exerciseId: next.exerciseId, setId: next.setId, cellType: .weight)
                }
            }

            // Cross-exercise scroll
            if next.exerciseId != exerciseId {
                withAnimation(.easeInOut(duration: MotionToken.medium)) {
                    scrollProxy?.scrollTo(next.exerciseId, anchor: .center)
                }
            }
        } else {
            // All sets done — return to normal mode
            withAnimation(MotionToken.snappy) {
                screenMode = .normal
            }
        }

        Task {
            do {
                _ = try await service.logSet(
                    exerciseInstanceId: exerciseId,
                    setId: setId,
                    weight: weight,
                    reps: reps,
                    rir: rir
                )
                // Haptic fires immediately in doneCell on tap — no duplicate here
            } catch {
                print("Log set failed: \(error)")
                showError("Set sync pending - you can continue")
            }
        }
    }
    
    private func patchField(exerciseId: String, setId: String, field: String, value: Any) {
        Task {
            do {
                _ = try await service.patchField(
                    exerciseInstanceId: exerciseId,
                    setId: setId,
                    field: field,
                    value: value
                )
            } catch {
                print("Patch failed: \(error)")
                showError("Edit sync pending")
            }
        }
    }
    
    private func addSet(to exerciseId: String, weight: Double? = nil, reps: Int = 10, rir: Int? = 2) {
        Task {
            do {
                _ = try await service.addSet(exerciseInstanceId: exerciseId, weight: weight, reps: reps, rir: rir)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                print("Add set failed: \(error)")
                showError("Failed to add set")
            }
        }
    }
    
    private func removeSet(exerciseId: String, setId: String) {
        Task {
            do {
                _ = try await service.removeSet(exerciseInstanceId: exerciseId, setId: setId)
            } catch {
                print("Remove set failed: \(error)")
                showError("Failed to remove set")
            }
        }
    }
    
    private func removeExercise(exerciseId: String) {
        Task {
            do {
                try await service.removeExercise(exerciseInstanceId: exerciseId)
            } catch {
                print("Remove exercise failed: \(error)")
                showError("Failed to remove exercise")
            }
        }
    }
    
    /// Resolve ghost values for a given exercise using last-session data from the service.
    private func ghostValues(for exercise: FocusModeExercise) -> [String: GhostValues] {
        let lastSession = service.lastSessionData[exercise.exerciseId]
        return GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
    }

    private func autofillExercise(_ exerciseId: String) {
        // TODO: Get AI prescription and call autofillExercise
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    /// Show a transient error banner that auto-dismisses after 4 seconds.
    private func showError(_ message: String) {
        withAnimation(.easeOut(duration: MotionToken.fast)) { errorBanner = message }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeOut(duration: MotionToken.fast)) { if errorBanner == message { errorBanner = nil } }
        }
    }

    // MARK: - Undo Label

    private func undoLabel(for action: FocusModeWorkoutService.UndoableAction?) -> String {
        guard let action = action else { return "Removed" }
        switch action {
        case .exerciseRemoved(let exercise, _, _):
            return "\(exercise.name) removed"
        case .setRemoved:
            return "Set removed"
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    FocusModeWorkoutScreen()
}

