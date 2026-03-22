import SwiftUI

// MARK: - Set Table Mode

/// Display mode for SetTable - controls layout, affordances, and interactions.
/// Mode is owned by SetTable, not by the cell models.
enum SetTableMode: Equatable {
    case readOnly      // History: most compact, no interactions
    case planning      // Canvas/planning: compact, optional edit tap
    case execution     // Active workout: larger rows, done toggle, active highlight
}

// MARK: - Set Table

/// Unified set grid component used across History, Planning, and Execution.
/// Renders [SetCellModel] with mode-specific layout and interactions.
struct SetTable: View {
    let sets: [SetCellModel]
    let mode: SetTableMode
    
    /// Weight unit label to display in header (reads user's preference)
    var weightUnit: String = UserService.shared.weightUnit.label
    
    // Optional callbacks (nil = not available in this mode)
    var onToggleDone: ((SetCellModel.ID) -> Void)?
    var onEditRequested: ((SetCellModel.ID, EditField) -> Void)?
    var onDeleteRequested: ((SetCellModel.ID) -> Void)?
    
    enum EditField: Equatable {
        case weight
        case reps
        case rir
    }
    
    // MARK: - Mode-specific Layout Constants
    
    private var rowHeight: CGFloat {
        switch mode {
        case .readOnly: return 40
        case .planning: return 44
        case .execution: return 52
        }
    }
    
    private var showDoneColumn: Bool {
        switch mode {
        case .readOnly: return true  // Show completion status
        case .planning: return false
        case .execution: return true
        }
    }
    
    private var showEditAffordance: Bool {
        switch mode {
        case .readOnly: return false
        case .planning: return onEditRequested != nil
        case .execution: return onEditRequested != nil
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            headerRow
            
            Divider()
                .background(Color.surfaceElevated)
            
            ForEach(sets) { set in
                setRow(set)
                
                if set.id != sets.last?.id {
                    Divider()
                        .background(Color.surface)
                        .padding(.horizontal, Space.sm)
                }
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))
    }
    
    // MARK: - Header Row
    
    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("SET")
                .frame(width: 44, alignment: .center)
            
            Text(weightUnit.uppercased())
                .frame(maxWidth: .infinity, alignment: .center)
            
            Text("REPS")
                .frame(width: 60, alignment: .center)
            
            Text("RIR")
                .frame(width: 44, alignment: .center)
            
            if showDoneColumn {
                Image(systemName: "checkmark")
                    .frame(width: 36, alignment: .center)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color.textTertiary)
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.sm)
    }
    
    // MARK: - Set Row
    
    private func setRow(_ set: SetCellModel) -> some View {
        HStack(spacing: 0) {
            // SET column with type indicator
            setIndexCell(set)
            
            // WEIGHT column
            valueCell(
                value: set.weight ?? "—",
                isSecondary: set.setTypeIndicator == .warmup,
                field: .weight,
                setId: set.id
            )
            .frame(maxWidth: .infinity)
            
            // REPS column
            valueCell(
                value: set.reps ?? "—",
                isSecondary: set.setTypeIndicator == .warmup,
                field: .reps,
                setId: set.id
            )
            .frame(width: 60)
            
            // RIR column
            valueCell(
                value: set.rir ?? "—",
                isSecondary: set.rir == nil || set.setTypeIndicator == .warmup,
                field: .rir,
                setId: set.id
            )
            .frame(width: 44)
            
            // DONE column
            if showDoneColumn {
                doneCell(set)
            }
        }
        .frame(height: rowHeight)
        .padding(.horizontal, Space.sm)
        .background(rowBackground(for: set))
    }
    
    // MARK: - Set Index Cell
    
    private func setIndexCell(_ set: SetCellModel) -> some View {
        ZStack {
            if let indicator = set.setTypeIndicator {
                // Special set type badge
                Text(indicator.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.textInverse)
                    .frame(width: 24, height: 24)
                    .background(indicator.color)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                // Normal set number
                Text(set.indexLabel)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.textSecondary)
            }
        }
        .frame(width: 44, alignment: .center)
    }
    
    // MARK: - Value Cell
    
    private func valueCell(
        value: String,
        isSecondary: Bool,
        field: EditField,
        setId: SetCellModel.ID
    ) -> some View {
        let isEditable = showEditAffordance && field != .rir || (field == .rir && !isSecondary)
        
        return Group {
            if isEditable, let onEdit = onEditRequested {
                Button {
                    onEdit(setId, field)
                } label: {
                    valueCellContent(value: value, isSecondary: isSecondary)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                valueCellContent(value: value, isSecondary: isSecondary)
            }
        }
    }
    
    private func valueCellContent(value: String, isSecondary: Bool) -> some View {
        Text(value)
            .font(.system(size: 16, weight: .medium).monospacedDigit())
            .foregroundColor(valueColor(value: value, isSecondary: isSecondary))
    }
    
    private func valueColor(value: String, isSecondary: Bool) -> Color {
        if value == "—" {
            return Color.textTertiary
        }
        return isSecondary ? Color.textSecondary : Color.textPrimary
    }
    
    // MARK: - Done Cell
    
    private func doneCell(_ set: SetCellModel) -> some View {
        Group {
            if mode == .execution, let onDone = onToggleDone {
                // Interactive done toggle in execution mode
                Button {
                    onDone(set.id)
                } label: {
                    doneIcon(isCompleted: set.isCompleted)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // Static display in read-only mode
                doneIcon(isCompleted: set.isCompleted)
            }
        }
        .frame(width: 36, alignment: .center)
    }
    
    private func doneIcon(isCompleted: Bool) -> some View {
        Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: mode == .execution ? 20 : 16))
            .foregroundColor(isCompleted ? Color.success : Color.textTertiary)
    }
    
    // MARK: - Row Background
    
    private func rowBackground(for set: SetCellModel) -> Color {
        if mode == .execution && set.isActive {
            return Color.accentMuted
        }
        if set.setTypeIndicator == .warmup {
            return Color.surfaceElevated.opacity(0.3)
        }
        return Color.clear
    }
}

// MARK: - Preview

#if DEBUG
struct SetTable_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Space.lg) {
            // Read-only mode (History)
            VStack(alignment: .leading) {
                Text("Read-only (History)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                
                SetTable(
                    sets: sampleSets,
                    mode: .readOnly
                )
            }
            
            // Planning mode
            VStack(alignment: .leading) {
                Text("Planning")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                
                SetTable(
                    sets: sampleSets,
                    mode: .planning,
                    onEditRequested: { id, field in
                        print("Edit \(field) for \(id)")
                    }
                )
            }
            
            // Execution mode
            VStack(alignment: .leading) {
                Text("Execution")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                
                SetTable(
                    sets: sampleExecutionSets,
                    mode: .execution,
                    onToggleDone: { id in
                        print("Toggle done for \(id)")
                    }
                )
            }
        }
        .padding()
        .background(Color.bg)
    }
    
    static var sampleSets: [SetCellModel] {
        [
            SetCellModel(id: "1", indexLabel: "W1", weight: "40", reps: "10", rir: nil, e1rm: nil, setTypeIndicator: .warmup, isActive: false, isCompleted: true),
            SetCellModel(id: "2", indexLabel: "1", weight: "80", reps: "8", rir: "2", e1rm: "101", setTypeIndicator: nil, isActive: false, isCompleted: true),
            SetCellModel(id: "3", indexLabel: "2", weight: "80", reps: "8", rir: "1", e1rm: "101", setTypeIndicator: nil, isActive: false, isCompleted: true),
            SetCellModel(id: "4", indexLabel: "3", weight: "80", reps: "6", rir: "0", e1rm: "96", setTypeIndicator: .failure, isActive: false, isCompleted: true)
        ]
    }
    
    static var sampleExecutionSets: [SetCellModel] {
        [
            SetCellModel(id: "1", indexLabel: "W1", weight: "40", reps: "10", rir: nil, e1rm: nil, setTypeIndicator: .warmup, isActive: false, isCompleted: true),
            SetCellModel(id: "2", indexLabel: "1", weight: "80", reps: "8", rir: "2", e1rm: "101", setTypeIndicator: nil, isActive: false, isCompleted: true),
            SetCellModel(id: "3", indexLabel: "2", weight: "80", reps: "8", rir: "2", e1rm: "101", setTypeIndicator: nil, isActive: true, isCompleted: false),
            SetCellModel(id: "4", indexLabel: "3", weight: "80", reps: "8", rir: "2", e1rm: "101", setTypeIndicator: nil, isActive: false, isCompleted: false)
        ]
    }
}
#endif
