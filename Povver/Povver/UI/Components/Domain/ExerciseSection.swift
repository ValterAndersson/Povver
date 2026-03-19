import SwiftUI

// MARK: - Exercise Section

/// Unified exercise block container used across all modes.
/// Provides consistent header/container anatomy while accepting
/// any content (SetTable, SetGridView, FocusModeSetGrid) as injected content.
///
/// Anatomy rules (consistent across modes):
/// - Container: SurfaceCard with hairline border
/// - Header: [indexLabel?] | title + subtitle | [trailing menu?]
/// - Active indicator: 3pt leading accent bar (execution mode only, when isActive)
/// - Content: injected via ViewBuilder
///
/// Density rules by mode:
/// - .execution: header padding 16, content padding 16, largest
/// - .planning: header padding 14, content padding 12, medium
/// - .readOnly: header padding 12, content padding 12, most compact
struct ExerciseSection<Content: View>: View {
    let model: ExerciseSectionModel
    let content: Content
    var onMenuAction: ((ExerciseMenuItem) -> Void)?
    
    init(
        model: ExerciseSectionModel,
        onMenuAction: ((ExerciseMenuItem) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        self.onMenuAction = onMenuAction
        self.content = content()
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Main container
            VStack(alignment: .leading, spacing: 0) {
                // Header
                header
                
                // Content
                content
                    .padding(.horizontal, contentHorizontalPadding)
                    .padding(.bottom, contentBottomPadding)
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl)
                    .stroke(Color.separatorLine, lineWidth: 0.5)
            )
            
            // Active indicator (execution mode only)
            if model.mode == .execution && model.isActive {
                activeIndicator
            }
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: Space.sm) {
            // Optional index label (primarily for read-only mode)
            if let indexLabel = model.indexLabel {
                Text(indexLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                    .frame(minWidth: 24)
            }
            
            // Title + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: headerTitleSize, weight: .semibold))
                    .foregroundColor(Color.textPrimary)
                    .lineLimit(1)
                
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Trailing menu (if has menu items)
            if !model.menuItems.isEmpty {
                trailingMenu
            }
        }
        .padding(.horizontal, headerHorizontalPadding)
        .padding(.vertical, headerVerticalPadding)
    }
    
    // MARK: - Trailing Menu
    
    private var trailingMenu: some View {
        Menu {
            ForEach(model.menuItems, id: \.self) { item in
                Button(role: item.isDestructive ? .destructive : nil) {
                    onMenuAction?(item)
                } label: {
                    Label(item.label, systemImage: item.icon)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color.textSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
    }
    
    // MARK: - Active Indicator
    
    private var activeIndicator: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accent)
            .frame(width: 3)
            .padding(.vertical, 8)
    }
    
    // MARK: - Mode-Specific Styling
    
    private var headerTitleSize: CGFloat {
        switch model.mode {
        case .execution: return 17
        case .planning: return 16
        case .readOnly: return 15
        }
    }
    
    private var headerHorizontalPadding: CGFloat {
        switch model.mode {
        case .execution: return Space.lg
        case .planning: return Space.md
        case .readOnly: return Space.md
        }
    }
    
    private var headerVerticalPadding: CGFloat {
        switch model.mode {
        case .execution: return Space.md
        case .planning: return Space.sm + 2
        case .readOnly: return Space.sm
        }
    }
    
    private var contentHorizontalPadding: CGFloat {
        switch model.mode {
        case .execution: return 0  // SetGrid handles its own padding
        case .planning: return 0   // SetGridView handles its own padding
        case .readOnly: return 0   // SetTable handles its own padding
        }
    }
    
    private var contentBottomPadding: CGFloat {
        switch model.mode {
        case .execution: return Space.sm
        case .planning: return Space.sm
        case .readOnly: return Space.sm
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ExerciseSection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                // Read-only (History)
                ExerciseSection(
                    model: .readOnly(
                        id: "1",
                        title: "Bench Press",
                        indexLabel: "1",
                        subtitle: "Barbell"
                    )
                ) {
                    Text("SetTable content here")
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                        .background(Color.surfaceElevated)
                }
                
                // Planning
                ExerciseSection(
                    model: .planning(
                        id: "2",
                        title: "Romanian Deadlift",
                        subtitle: "Dumbbells · Hamstrings"
                    ),
                    onMenuAction: { print("Action: \($0)") }
                ) {
                    Text("SetGridView content here")
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .background(Color.surfaceElevated)
                }
                
                // Execution (active)
                ExerciseSection(
                    model: .execution(
                        id: "3",
                        title: "Lateral Raise",
                        subtitle: "Dumbbells",
                        isActive: true
                    )
                ) {
                    Text("FocusModeSetGrid content here")
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .background(Color.surfaceElevated)
                }
                
                // Execution (not active)
                ExerciseSection(
                    model: .execution(
                        id: "4",
                        title: "Cable Crossover",
                        isActive: false
                    )
                ) {
                    Text("FocusModeSetGrid content here")
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                        .background(Color.surfaceElevated)
                }
            }
            .padding()
        }
        .background(Color.bg)
    }
}
#endif
