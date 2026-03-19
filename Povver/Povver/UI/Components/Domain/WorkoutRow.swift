import SwiftUI

// MARK: - WorkoutRow v1.2
/// Canonical workout row component for consistent listing across all surfaces.
/// Used in: Templates list, Routines list, History list, Canvas planning cards, Routine detail

public enum WorkoutRowVariant {
    /// Compact style for Canvas planning cards - minimal chrome
    case compact
    /// Standard list style for Templates, Routines, History
    case list
    /// Editable style with drag handle for reordering
    case editable
}

public struct WorkoutRow: View {
    private let title: String
    private let subtitle: String?
    private let dayLabel: String?
    private let badge: Badge?
    private let variant: WorkoutRowVariant
    private let isExpanded: Bool
    private let isSyncing: Bool
    private let action: (() -> Void)?
    
    public struct Badge {
        let text: String
        let color: Color
        
        public init(_ text: String, color: Color = .success) {
            self.text = text
            self.color = color
        }
        
        public static let active = Badge("Active", color: .success)
    }
    
    /// Creates a WorkoutRow
    /// - Parameters:
    ///   - title: Workout name (e.g., "Upper Body Push")
    ///   - subtitle: Metadata line (e.g., "5 exercises • 25 sets • ~45 min")
    ///   - dayLabel: Optional day label (e.g., "Day 1", "A", "A1")
    ///   - badge: Optional badge (e.g., "Active")
    ///   - variant: Display variant (.compact, .list, .editable)
    ///   - isExpanded: For expandable rows (compact variant)
    ///   - action: Tap action
    public init(
        title: String,
        subtitle: String? = nil,
        dayLabel: String? = nil,
        badge: Badge? = nil,
        variant: WorkoutRowVariant = .list,
        isExpanded: Bool = false,
        isSyncing: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dayLabel = dayLabel
        self.badge = badge
        self.variant = variant
        self.isExpanded = isExpanded
        self.isSyncing = isSyncing
        self.action = action
    }
    
    public var body: some View {
        if let action = action {
            Button(action: action) {
                rowContent
            }
            .buttonStyle(WorkoutRowButtonStyle(variant: variant))
        } else {
            rowContent
        }
    }
    
    private var rowContent: some View {
        HStack(spacing: Space.md) {
            // Leading: Day label or icon
            leadingView
            
            // Title + Subtitle
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text(title)
                        .textStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    
                    if let badge = badge {
                        badgeView(badge)
                    }
                }
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .textStyle(.secondary)
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: Space.sm)
            
            // Trailing: chevron or drag handle
            trailingView
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .background(backgroundView)
    }
    
    // MARK: - Leading View
    
    @ViewBuilder
    private var leadingView: some View {
        if let dayLabel = dayLabel {
            Text(dayLabel)
                .font(.system(size: dayLabelSize, weight: .semibold))
                .foregroundColor(variant == .compact ? .textSecondary : .accent)
                .padding(.horizontal, variant == .compact ? 0 : 8)
                .padding(.vertical, variant == .compact ? 0 : 4)
                .background(variant == .compact ? Color.clear : Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
        }
    }
    
    // MARK: - Badge View
    
    private func badgeView(_ badge: Badge) -> some View {
        Text(badge.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(badge.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badge.color.opacity(0.15))
            .clipShape(Capsule())
    }
    
    // MARK: - Trailing View
    
    @ViewBuilder
    private var trailingView: some View {
        if isSyncing {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
        } else {
            switch variant {
            case .compact:
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textTertiary)
            case .list:
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textTertiary)
            case .editable:
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textTertiary)
            }
        }
    }
    
    // MARK: - Variant-specific styling
    
    private var horizontalPadding: CGFloat {
        switch variant {
        case .compact: return Space.md
        case .list, .editable: return Space.md
        }
    }
    
    private var verticalPadding: CGFloat {
        switch variant {
        case .compact: return 14
        case .list, .editable: return Space.md
        }
    }
    
    private var dayLabelSize: CGFloat {
        switch variant {
        case .compact: return 13
        case .list, .editable: return 12
        }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .compact:
            if isExpanded {
                Color.surfaceElevated.opacity(0.5)
            } else {
                Color.clear
            }
        case .list:
            Color.surface
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        case .editable:
            Color.surface
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        }
    }
}

// MARK: - Button Style

private struct WorkoutRowButtonStyle: ButtonStyle {
    let variant: WorkoutRowVariant
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: MotionToken.fast), value: configuration.isPressed)
    }
}

// MARK: - Convenience Initializers

extension WorkoutRow {
    /// Create a WorkoutRow for Templates list
    public static func template(
        name: String,
        exerciseCount: Int,
        setCount: Int,
        isSyncing: Bool = false,
        action: (() -> Void)? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            title: name,
            subtitle: "\(exerciseCount) exercises • \(setCount) sets",
            variant: .list,
            isSyncing: isSyncing,
            action: action
        )
    }
    
    /// Create a WorkoutRow for Routines list
    public static func routine(
        name: String,
        workoutCount: Int,
        isActive: Bool = false,
        isSyncing: Bool = false,
        action: (() -> Void)? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            title: name,
            subtitle: "\(workoutCount) workouts",
            badge: isActive ? .active : nil,
            variant: .list,
            isSyncing: isSyncing,
            action: action
        )
    }
    
    /// Create a WorkoutRow for History list
    public static func history(
        name: String,
        time: String,
        duration: String,
        exerciseCount: Int,
        isSyncing: Bool = false,
        action: (() -> Void)? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            title: name,
            subtitle: "\(time) • \(duration) • \(exerciseCount) exercises",
            variant: .list,
            isSyncing: isSyncing,
            action: action
        )
    }
    
    /// Create a WorkoutRow for routine day (inside routine detail)
    public static func routineDay(
        day: Int,
        title: String,
        exerciseCount: Int,
        setCount: Int,
        isSyncing: Bool = false,
        action: (() -> Void)? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            title: title,
            subtitle: "\(exerciseCount) exercises • \(setCount) sets",
            dayLabel: "Day \(day)",
            variant: .list,
            isSyncing: isSyncing,
            action: action
        )
    }
    
    /// Create a WorkoutRow for Canvas planning cards (compact)
    public static func planningDay(
        day: Int,
        title: String,
        stats: String,
        isExpanded: Bool = false,
        action: (() -> Void)? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            title: title,
            subtitle: stats,
            dayLabel: "Day \(day):",
            variant: .compact,
            isExpanded: isExpanded,
            action: action
        )
    }
}

// MARK: - Preview

#if DEBUG
struct WorkoutRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.md) {
            // Template row
            WorkoutRow.template(
                name: "Upper Body Push",
                exerciseCount: 5,
                setCount: 18
            )
            
            // Routine row
            WorkoutRow.routine(
                name: "Push Pull Legs",
                workoutCount: 6,
                isActive: true
            )
            
            // History row
            WorkoutRow.history(
                name: "Morning Workout",
                time: "8:30 AM",
                duration: "52m",
                exerciseCount: 6
            )
            
            // Routine day
            WorkoutRow.routineDay(
                day: 1,
                title: "Push",
                exerciseCount: 5,
                setCount: 18
            )
            
            // Planning day (compact)
            SurfaceCard {
                VStack(spacing: 0) {
                    WorkoutRow.planningDay(
                        day: 1,
                        title: "Push",
                        stats: "~45 min • 5 exercises",
                        isExpanded: false
                    )
                    Divider()
                    WorkoutRow.planningDay(
                        day: 2,
                        title: "Pull",
                        stats: "~40 min • 5 exercises",
                        isExpanded: true
                    )
                }
            }
        }
        .padding(Space.lg)
        .background(Color.bg)
        .previewLayout(.sizeThatFits)
    }
}
#endif
