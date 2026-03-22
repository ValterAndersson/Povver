/**
 * FocusModeComponents.swift
 *
 * Reusable UI components for Focus Mode workout execution.
 * These components are designed for the premium execution surface.
 */

import SwiftUI

// MARK: - Exercise Density

/// Contextual density levels for exercise sections.
/// Controls how much detail each exercise card shows based on its completion state.
enum ExerciseDensity: Equatable {
    case active      // Full set grid, large touch targets, ~60% of screen
    case completed   // Compressed: name + set count + emerald left-edge bar. Tappable to expand.
    case upcoming    // Minimal: name + set count, subdued opacity
}

// MARK: - Screen Mode State Machine

/// Cell types for editing in the set grid
enum FocusModeEditCellType: Equatable {
    case weight
    case reps
    case rir
}

enum FocusModeScreenMode: Equatable {
    case normal
    case editingSet(exerciseId: String, setId: String, cellType: FocusModeEditCellType)
    case reordering
    
    var isReordering: Bool {
        if case .reordering = self { return true }
        return false
    }
    
    var isEditing: Bool {
        if case .editingSet = self { return true }
        return false
    }
    
    /// Get the cell type if editing, nil otherwise
    var editingCellType: FocusModeEditCellType? {
        if case .editingSet(_, _, let cellType) = self { return cellType }
        return nil
    }
}

// MARK: - Active Sheet Enum

enum FocusModeActiveSheet: Identifiable, Equatable {
    case coach
    case exerciseSearch
    case startTimeEditor
    case finishWorkout
    case setTypePicker(exerciseId: String, setId: String)
    case moreActions(exerciseId: String)
    case exerciseDetail(exerciseId: String?, exerciseName: String)
    case exercisePerformance(exerciseId: String, exerciseName: String)
    case noteEditorWorkout
    case noteEditorExercise(exerciseInstanceId: String)
    case exerciseSwap(exercise: FocusModeExercise)

    var id: String {
        switch self {
        case .coach: return "coach"
        case .exerciseSearch: return "exerciseSearch"
        case .startTimeEditor: return "startTimeEditor"
        case .finishWorkout: return "finishWorkout"
        case .setTypePicker(let exId, let setId): return "setTypePicker-\(exId)-\(setId)"
        case .moreActions(let exId): return "moreActions-\(exId)"
        case .exerciseDetail(let exId, _): return "exerciseDetail-\(exId ?? "nil")"
        case .exercisePerformance(let exId, _): return "exercisePerformance-\(exId)"
        case .noteEditorWorkout: return "noteEditorWorkout"
        case .noteEditorExercise(let exId): return "noteEditorExercise-\(exId)"
        case .exerciseSwap(let ex): return "exerciseSwap-\(ex.instanceId)"
        }
    }
}

// MARK: - Finish Workout Sheet

/// Summary sheet for completing or discarding a workout
/// Opened from nav Finish button - provides two-step confirmation flow
struct FinishWorkoutSheet: View {
    let elapsedTime: TimeInterval
    let completedSets: Int
    let totalSets: Int
    let exerciseCount: Int
    var workoutNotes: String? = nil
    var showSaveToTemplate: Bool = false
    let onComplete: () -> Void
    let onDiscard: () -> Void
    let onDismiss: () -> Void
    var onSaveToTemplate: (() -> Void)? = nil

    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showDiscardConfirmation = false
    @State private var saveToTemplate: Bool = true
    
    /// Complete is disabled when there are no exercises
    private var canComplete: Bool {
        exerciseCount > 0
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Summary stats - compact card
                VStack(spacing: Space.sm) {
                    // Duration - featured stat
                    VStack(spacing: 4) {
                        Text(formatDuration(elapsedTime))
                            .font(.system(size: 44, weight: .light).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                        Text("Duration")
                            .font(.system(size: 13))
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.md)
                    
                    Divider()
                        .padding(.horizontal, Space.lg)
                    
                    // Secondary stats row
                    HStack(spacing: Space.xl) {
                        statColumn(value: "\(completedSets)/\(totalSets)", label: "Sets")
                        
                        Rectangle()
                            .fill(Color.separatorLine)
                            .frame(width: 1, height: 36)
                        
                        statColumn(value: "\(exerciseCount)", label: "Exercises")
                    }
                    .padding(.vertical, Space.sm)
                }
                .padding(.top, Space.md)

                // Workout note preview (read-only, single-line truncated)
                if let notes = workoutNotes {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "note.text")
                            .font(.system(size: 12))
                            .foregroundColor(Color.textTertiary)
                        Text(notes)
                            .font(.system(size: 13))
                            .foregroundColor(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                }

                // Save to template toggle
                if showSaveToTemplate {
                    Toggle(isOn: $saveToTemplate) {
                        HStack(spacing: Space.sm) {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 14))
                                .foregroundColor(Color.textSecondary)
                            Text("Update template with today's changes")
                                .font(.system(size: 14))
                                .foregroundColor(Color.textPrimary)
                        }
                    }
                    .tint(Color.accent)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(Color.destructive)
                        .padding(.horizontal, Space.lg)
                        .padding(.top, Space.sm)
                }

                Spacer(minLength: Space.md)

                // Action buttons - tighter grouping
                VStack(spacing: Space.sm) {
                    // Complete - Primary CTA
                    Button {
                        isLoading = true
                        if saveToTemplate && showSaveToTemplate {
                            onSaveToTemplate?()
                        }
                        onComplete()
                    } label: {
                        HStack(spacing: Space.sm) {
                            if isLoading {
                                ProgressView()
                                    .tint(.textInverse)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                            }
                            Text("Complete Workout")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(.textInverse)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(canComplete ? Color.accent : Color.accent.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isLoading || !canComplete)
                    
                    // Discard - Full width destructive button (more prominent)
                    Button {
                        showDiscardConfirmation = true
                    } label: {
                        HStack(spacing: Space.sm) {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                            Text("Discard Workout")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(Color.destructive)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.destructive.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isLoading)
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bg)
            .navigationTitle("Finish Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .disabled(isLoading)
                }
            }
            .confirmationDialog("Discard Workout?", isPresented: $showDiscardConfirmation) {
                Button("Discard", role: .destructive) {
                    onDiscard()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your progress will not be saved.")
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isLoading)
    }
    
    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.textPrimary)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
        }
    }
    
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

// MARK: - Hero Visibility PreferenceKey (Legacy)

/// PreferenceKey to track hero scroll state with measured values
struct HeroScrollStatePreferenceKey: PreferenceKey {
    struct Value: Equatable {
        let minY: CGFloat
        let heroHeight: CGFloat
        
        static var defaultValue: Value { Value(minY: 0, heroHeight: 280) }
    }
    
    static var defaultValue: Value = .defaultValue
    
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value = nextValue()
    }
}

/// View modifier to report hero scroll state with measured height
/// Place this at the bottom of the hero card to measure its height
struct HeroScrollStateReader: View {
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("workoutScroll"))
            Color.clear
                .preference(
                    key: HeroScrollStatePreferenceKey.self,
                    value: HeroScrollStatePreferenceKey.Value(
                        minY: frame.minY,
                        heroHeight: frame.height
                    )
                )
        }
        .frame(height: 0)
    }
}

/// Legacy compatibility - maps to new system
struct HeroVisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = true
    
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

/// Legacy compatibility view
struct HeroVisibilityReader: View {
    let heroHeight: CGFloat
    let threshold: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named("workoutScroll")).minY
            let isVisible = minY > -heroHeight + threshold
            
            Color.clear
                .preference(key: HeroVisibilityPreferenceKey.self, value: isVisible)
        }
        .frame(height: 0)
    }
}

// MARK: - Nav Compact Timer

/// Compact timer for nav bar center - ALWAYS tappable, fixed width to prevent layout shift
/// 
/// Key design rules:
/// - Always tappable (no hit testing gate based on collapse state)
/// - Opacity controlled externally (0.65 when hero visible, 1.0 when collapsed)
/// - Stable minWidth of 72pt for mm:ss format (prevents jitter on 09:59 → 10:00)
/// - Uses .foregroundStyle(.primary) to ensure it never looks disabled
/// - 44pt minimum tap target for accessibility
struct NavCompactTimer: View {
    let elapsedTime: TimeInterval
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            Text(formatDuration(elapsedTime))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)  // Never looks disabled
                .frame(minWidth: 72, alignment: .center)  // Stable width for mm:ss → h:mm:ss
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 6)
                .background(Color.surfaceElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .frame(minWidth: 88, minHeight: 44)  // 44pt hit target, accommodates h:mm:ss
        .contentShape(Rectangle())
        .accessibilityLabel("Workout duration: \(formatAccessibleDuration(elapsedTime))")
        .accessibilityHint("Tap to adjust start time")
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func formatAccessibleDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        
        if hours > 0 {
            return "\(hours) hours, \(minutes) minutes, \(seconds) seconds"
        }
        return "\(minutes) minutes, \(seconds) seconds"
    }
}

// MARK: - Coach Icon Button (Icon-Only for Nav Bar)

/// Icon-only Coach button for nav bar - saves space
struct CoachIconButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Color.accent)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Coach")
    }
}

// MARK: - Timer Pill

/// Timer pill that adapts to available space using ViewThatFits.
/// Priority: Full timer + progress > Timer only > Nothing (never happens)
struct TimerPill: View {
    let elapsedTime: TimeInterval
    let completedSets: Int
    let totalSets: Int
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Full version: timer + progress
            timerPillContent(showProgress: true)
            
            // Compact version: timer only
            timerPillContent(showProgress: false)
        }
    }
    
    @ViewBuilder
    private func timerPillContent(showProgress: Bool) -> some View {
        HStack(spacing: Space.xs) {
            Text(formatDuration(elapsedTime))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundColor(Color.textPrimary)
            
            if showProgress && totalSets > 0 {
                Text("·")
                    .foregroundColor(Color.textTertiary)
                
                Text("\(completedSets)/\(totalSets)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.textSecondary)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Color.surfaceElevated)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)  // Each variant is fixed, but ViewThatFits picks which one
    }
    
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

// MARK: - Coach Button (AI Copilot)

struct CoachButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                Text("Coach")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.textInverse)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(Color.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Reorder Toggle Button

/// Reorder toggle - icon-only in header to save space
struct ReorderToggleButton: View {
    let isReordering: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isReordering ? Color.accent : Color.textSecondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(isReordering ? "Done reordering" : "Reorder exercises")
    }
}

// MARK: - Workout Hero

/// Hero section at top of workout content - shows workout identity + large timer
/// Scrolls away, triggering compact timer in nav bar
struct WorkoutHero: View {
    let workoutName: String
    let workoutNotes: String?
    let startTime: Date
    let elapsedTime: TimeInterval
    let completedSets: Int
    let totalSets: Int
    let hasExercises: Bool

    let onNameTap: () -> Void
    let onTimerTap: () -> Void
    let onCoachTap: () -> Void
    let onReorderTap: () -> Void
    let onMenuAction: (HeroMenuAction) -> Void

    enum HeroMenuAction {
        case editName
        case editStartTime
        case addNote
        case reorder
        case discard
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Title row with menu - ellipsis pinned top-right
            HStack(alignment: .top, spacing: Space.sm) {
                // Title block with constraints
                VStack(alignment: .leading, spacing: 4) {
                    // Workout name (tappable to edit) - lineLimit(2) + truncation
                    Button(action: onNameTap) {
                        Text(workoutName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Date/time subtitle - lineLimit(1)
                    Text(formatStartTime(startTime))
                        .font(.system(size: 14))
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Ellipsis menu - pinned, never affected by title wrap
                Menu {
                    Button { onMenuAction(.editName) } label: {
                        Label("Edit Name", systemImage: "pencil")
                    }
                    
                    Button { onMenuAction(.editStartTime) } label: {
                        Label("Edit Start Time", systemImage: "clock")
                    }

                    Button { onMenuAction(.addNote) } label: {
                        Label(workoutNotes != nil ? "Edit Note" : "Add Note", systemImage: "note.text")
                    }

                    if hasExercises {
                        Button { onMenuAction(.reorder) } label: {
                            Label("Reorder Exercises", systemImage: "arrow.up.arrow.down")
                        }
                    }

                    Divider()
                    
                    Button(role: .destructive) { onMenuAction(.discard) } label: {
                        Label("Discard Workout", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundColor(Color.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .fixedSize()  // Ellipsis never compresses
            }
            
            // Large timer (tappable to edit start time) - guaranteed minimum space
            Button(action: onTimerTap) {
                Text(formatDuration(elapsedTime))
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                    .foregroundColor(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(PlainButtonStyle())
            .frame(minHeight: 72)  // Guaranteed vertical space for timer
            .contentShape(Rectangle())
            
            // Progress microcopy
            if totalSets > 0 {
                Text("\(completedSets)/\(totalSets) sets completed")
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundColor(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Workout note preview (single-line truncated)
            if let notes = workoutNotes {
                Button { onMenuAction(.addNote) } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "note.text")
                            .font(.system(size: 12))
                            .foregroundColor(Color.textTertiary)
                        Text(notes)
                            .font(.system(size: 13))
                            .foregroundColor(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Action strip: Coach + Reorder pills
            HStack(spacing: Space.sm) {
                // Coach pill (primary)
                CoachButton(action: onCoachTap)
                
                // Reorder pill (if exercises exist)
                if hasExercises {
                    Button(action: onReorderTap) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 12, weight: .medium))
                            Text("Reorder")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(Color.textSecondary)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                        .background(Color.surfaceElevated)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Space.sm)
        }
        .padding(Space.lg)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
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

// MARK: - Empty State Card

/// Instructional card shown when workout has no exercises
struct EmptyStateCard: View {
    let onAddExercise: () -> Void
    var onFinishWorkout: (() -> Void)? = nil
    var onDiscardWorkout: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: Space.lg) {
            // Icon
            Image(systemName: "dumbbell")
                .font(.system(size: 36))
                .foregroundColor(Color.accent.opacity(0.6))
            
            // Title
            Text("Start by adding an exercise")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            
            // Bullet list instructions
            VStack(alignment: .leading, spacing: Space.sm) {
                instructionRow(icon: "plus.circle", text: "Add an exercise from the library")
                instructionRow(icon: "sparkles", text: "Or tap Coach for suggestions")
                instructionRow(icon: "hand.tap", text: "Tap weight/reps to edit values")
                instructionRow(icon: "checkmark.circle", text: "Tap ✓ to mark a set done")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.lg)
            
            // Primary CTA
            Button(action: onAddExercise) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                    Text("Add Exercise")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.textInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, Space.md)
            .padding(.top, Space.sm)
        }
        .padding(.vertical, Space.xl)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
    
    private func instructionRow(icon: String, text: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.accent)
                .frame(width: 20)
            
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
        }
    }
}

// MARK: - Reorder Mode Banner

struct ReorderModeBanner: View {
    var onDone: (() -> Void)? = nil
    
    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.accent)
            
            Text("Reorder exercises")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.textPrimary)
            
            Spacer()
            
            // Done button to exit reorder mode
            if let onDone = onDone {
                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.accent)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Color.accent.opacity(0.08))
    }
}

// MARK: - Action Rail

enum ActionPriority: Int, Comparable {
    case coach = 0      // P0: Auto-fill, Recalibrate, Adjust next
    case utility = 1    // P1: Last time, +2.5kg
    case advanced = 2   // P2: Edit warm-ups, Convert to dropset
    
    static func < (lhs: ActionPriority, rhs: ActionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ActionItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let priority: ActionPriority
    let isPrimary: Bool
    let action: () -> Void
}

struct ActionRail: View {
    let actions: [ActionItem]
    let isActive: Bool
    let onMoreTap: () -> Void
    
    private var visibleActions: [ActionItem] {
        let sorted = actions.sorted { $0.priority < $1.priority }
        if isActive {
            return Array(sorted.prefix(5))
        } else {
            return Array(sorted.prefix(2))
        }
    }
    
    private var hasMore: Bool {
        actions.count > (isActive ? 5 : 2)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Actions")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.textTertiary)
                .padding(.leading, Space.md)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(visibleActions) { action in
                        ActionPill(
                            icon: action.icon,
                            label: action.label,
                            isPrimary: action.isPrimary,
                            action: action.action
                        )
                    }
                    
                    if hasMore {
                        ActionPill(
                            icon: "ellipsis",
                            label: "More",
                            isPrimary: false,
                            action: onMoreTap
                        )
                    }
                }
                .padding(.horizontal, Space.md)
            }
        }
        .padding(.bottom, Space.sm)
    }
}

struct ActionPill: View {
    let icon: String
    let label: String
    let isPrimary: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isPrimary ? .textInverse : Color.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isPrimary ? Color.accent : Color.accent.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                isPrimary ? nil : Capsule().stroke(Color.accent.opacity(0.2), lineWidth: StrokeWidthToken.hairline)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Bottom CTA Section

struct WorkoutBottomCTA: View {
    let onFinish: () -> Void
    let onDiscard: () -> Void
    let safeAreaBottom: CGFloat
    
    var body: some View {
        VStack(spacing: Space.sm) {
            // Finish Workout - Primary CTA
            Button(action: onFinish) {
                Text("Finish Workout")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.textInverse)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .buttonStyle(PlainButtonStyle())
            
            // Discard Workout - Destructive secondary
            Button(action: onDiscard) {
                Text("Discard Workout")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color.destructive)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.lg)
        .padding(.bottom, safeAreaBottom + LayoutToken.bottomCTAExtraPadding)
    }
}

// MARK: - Exercise Card Container (v1.1 Premium Visual System)
/// Exercise section container with 3-tier visual hierarchy:
/// - Tier 2 (Active): surfaceElevated background + level1 shadow + emerald left-edge
/// - Tier 1 (Completed): surface background + emerald left-edge (earned color)
/// - Tier 0 (Upcoming): transparent background (no visual weight)

struct ExerciseCardContainer<Content: View>: View {
    let isActive: Bool
    let isCompleted: Bool
    let content: () -> Content

    var body: some View {
        content()
            .background(isActive ? Color.surfaceElevated : (isCompleted ? Color.surface : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
            .shadowStyle(isActive ? ShadowsToken.level1 : ShadowStyle(color: .clear, x: 0, y: 0, blur: 0))
            .overlay(alignment: .leading) {
                // Emerald left-edge: active exercise AND completed exercises (earned color)
                if isActive || isCompleted {
                    RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon)
                        .fill(Color.accent)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                        .padding(.leading, 2)
                }
            }
    }
}

// MARK: - Dotted Warmup Divider

struct WarmupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.textTertiary)
            .frame(height: 1.5)
            .padding(.vertical, Space.sm)
    }
}

// MARK: - Compact Completion Circle

struct CompletionCircle: View {
    let isDone: Bool
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(
                        isDone ? Color.success.opacity(0.3) : Color.textSecondary.opacity(0.2),
                        lineWidth: isDone ? 2 : 1.5
                    )
                    .frame(width: 20, height: 20)

                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.success)
                }
            }
            .scaleEffect(pulseScale)
            .frame(width: 44, height: 44) // 44pt hit target
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onChange(of: isDone) { _, newValue in
            if newValue {
                withAnimation(.spring(response: 0.12, dampingFraction: 0.5)) {
                    pulseScale = 1.15
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.12, dampingFraction: 0.8)) {
                        pulseScale = 1.0
                    }
                }
            }
        }
    }
}

// MARK: - Segmented Scope Control

struct ScopeSegmentedControl: View {
    @Binding var selectedScope: FocusModeEditScope
    let thisCount: Int
    let remainingCount: Int
    let allCount: Int
    
    var body: some View {
        HStack(spacing: 0) {
            scopeButton(.thisOnly, label: "This", count: nil)
            scopeButton(.remaining, label: "Remaining", count: remainingCount)
            scopeButton(.allWorking, label: "All", count: allCount)
        }
        .background(Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
    }
    
    private func scopeButton(_ scope: FocusModeEditScope, label: String, count: Int?) -> some View {
        let isSelected = selectedScope == scope
        
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedScope = scope
            }
            HapticManager.selectionChanged()
        } label: {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if let count = count {
                    Text("(\(count))")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                }
            }
            .foregroundColor(isSelected ? .textInverse : Color.textSecondary)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon - 2))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Reorder Row (Collapsed)

/// Compact exercise row for reorder mode.
/// Shows drag handle prominently with visual lift (shadow + scale).
struct ExerciseReorderRow: View {
    let exercise: FocusModeExercise
    
    /// Track if this row is being dragged (for visual feedback)
    @State private var isDragging = false
    
    var body: some View {
        HStack(spacing: Space.md) {
            // Drag handle - prominent and interactive
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.accent)
                .frame(width: 28, height: 28)
                .background(Color.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.textPrimary)
                    .lineLimit(1)
                
                Text("\(exercise.completedSetsCount)/\(exercise.totalWorkingSetsCount) sets")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(Color.textSecondary)
            }
            
            Spacer()
            
            if exercise.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color.success)
                    .font(.system(size: 18))
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard)
                .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
        // Elevated appearance to signal "draggable"
        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Swipe To Delete Row

/// Custom swipe-to-delete wrapper for use in VStack/LazyVStack
/// Since .swipeActions only works in List, this provides similar functionality
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    /// Tracks live drag offset; auto-resets to 0 when gesture ends/cancelled
    /// (prevents stuck state when ScrollView steals the gesture)
    @GestureState private var dragOffset: CGFloat = 0
    /// Persists the revealed/closed state between gestures
    @State private var baseOffset: CGFloat = 0

    private var isRevealed: Bool { baseOffset != 0 }

    private let deleteButtonWidth: CGFloat = 80
    private let deleteThreshold: CGFloat = 60
    private let fullSwipeThreshold: CGFloat = 150

    /// Visible offset = persisted base + live drag (drag auto-resets on cancel)
    private var visibleOffset: CGFloat { baseOffset + dragOffset }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete button (revealed behind content)
            HStack {
                Spacer()
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textInverse)
                        .frame(width: deleteButtonWidth, height: 52)
                        .background(Color.destructive)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Main content with gesture
            content()
                .background(Color.surface)
                .offset(x: visibleOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .updating($dragOffset) { value, state, _ in
                            let translation = value.translation
                            // Horizontal-only guard: ignore vertical scrolls
                            guard abs(translation.width) > abs(translation.height) else { return }

                            if baseOffset == 0 {
                                // Closed state: only allow left swipe
                                if translation.width < 0 {
                                    if abs(translation.width) > deleteButtonWidth {
                                        let overDrag = abs(translation.width) - deleteButtonWidth
                                        state = -deleteButtonWidth - (overDrag * 0.3)
                                    } else {
                                        state = translation.width
                                    }
                                }
                            } else {
                                // Revealed state: swipe right to close, cap so total doesn't exceed 0
                                state = min(deleteButtonWidth, max(0, translation.width))
                            }
                        }
                        .onEnded { value in
                            let translation = value.translation
                            // Ignore primarily vertical gestures
                            guard abs(translation.width) > abs(translation.height) else { return }

                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if baseOffset == 0 {
                                    // From closed state
                                    if translation.width < -fullSwipeThreshold {
                                        // Full swipe triggers delete
                                        baseOffset = -UIScreen.main.bounds.width
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            onDelete()
                                        }
                                    } else if translation.width < -deleteThreshold {
                                        // Partial swipe reveals button
                                        baseOffset = -deleteButtonWidth
                                    } else {
                                        baseOffset = 0
                                    }
                                } else {
                                    // From revealed state
                                    if translation.width > deleteThreshold {
                                        // Swipe right to close
                                        baseOffset = 0
                                    } else {
                                        // Stay revealed
                                        baseOffset = -deleteButtonWidth
                                    }
                                }
                            }
                        }
                )
                .onTapGesture {
                    if isRevealed {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            baseOffset = 0
                        }
                    }
                }
        }
        .clipped()
    }
}

// MARK: - Note Editor Sheet

/// Shared sheet component for editing workout or exercise notes.
/// TextEditor with 500-char limit, Save/Cancel buttons.
/// Empty text saves as nil (clears note).
struct NoteEditorSheet: View {
    let title: String
    let existingNote: String?
    let onSave: (String?) -> Void
    let onCancel: () -> Void

    @State private var noteText: String = ""
    private let maxLength = 500

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $noteText)
                    .font(.system(size: 16))
                    .foregroundColor(Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Space.md)
                    .padding(.top, Space.sm)
                    .onChange(of: noteText) { _, newValue in
                        if newValue.count > maxLength {
                            noteText = String(newValue.prefix(maxLength))
                        }
                    }

                // Character count
                HStack {
                    Spacer()
                    Text("\(noteText.count)/\(maxLength)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(noteText.count >= maxLength ? Color.destructive : Color.textTertiary)
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
            }
            .background(Color.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            noteText = existingNote ?? ""
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Space.lg) {
        TimerPill(elapsedTime: 3661, completedSets: 6, totalSets: 18)
        
        HStack(spacing: Space.md) {
            CoachButton { }
            ReorderToggleButton(isReordering: false) { }
            ReorderToggleButton(isReordering: true) { }
        }
        
        ReorderModeBanner()
        
        WarmupDivider()
            .padding(.horizontal)
        
        HStack {
            CompletionCircle(isDone: false) { }
            CompletionCircle(isDone: true) { }
        }
        
        Spacer()
    }
    .padding()
    .background(Color.bg)
}
