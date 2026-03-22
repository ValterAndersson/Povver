import SwiftUI

// MARK: - Cell Selection

enum GridCellField: Equatable, Hashable {
    case weight(setId: String)
    case reps(setId: String)
    case rir(setId: String)

    var setId: String {
        switch self {
        case .weight(let id), .reps(let id), .rir(let id):
            return id
        }
    }
}

// MARK: - Edit Scope

enum EditScope: String, CaseIterable {
    case allWorking = "All Working"
    case remaining = "Remaining"
    case thisOnly = "This Only"
}

// MARK: - Set Grid View

struct SetGridView: View {
    @Binding var sets: [PlanSet]
    @Binding var selectedCell: GridCellField?
    let exerciseName: String
    let warmupCollapsed: Bool
    let isPlanningMode: Bool
    let onWarmupToggle: () -> Void
    let onAddSet: (SetType) -> Void
    let onDeleteSet: (Int) -> Void
    let onUndoDelete: (() -> Void)?
    
    @State private var editScope: EditScope = .allWorking
    @State private var setTypePickerSetId: String? = nil
    
    // Row height constant - unified with FocusModeSetGrid (52pt for gym use)
    private let rowHeight: CGFloat = 52
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Grid with GeometryReader for consistent column widths
            GeometryReader { geometry in
                let widths = columnWidths(for: geometry.size.width)
                
                VStack(spacing: 0) {
                    // Header
                    gridHeader(widths: widths)
                    
                    // Rows - use List for swipe actions
                    List {
                        ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                            VStack(spacing: 0) {
                                gridRow(for: set, at: index, widths: widths)
                                
                                if selectedCell?.setId == set.id {
                                    InlineEditingDock(
                                        selectedCell: selectedCell!,
                                        sets: $sets,
                                        editScope: $editScope,
                                        onDismiss: { withAnimation(.easeOut(duration: 0.15)) { selectedCell = nil } }
                                    )
                                    .id(selectedCell!)
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.visible)
                            .listRowBackground(rowBackground(for: set))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { onDeleteSet(index) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    HapticManager.modeToggle()
                                    duplicateSet(at: index)
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                }
                                .tint(Color.accent)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .environment(\.defaultMinListRowHeight, rowHeight)
                }
            }
            .frame(height: calculateGridHeight())
            
            // Add set button
            addSetButton
        }
        .sheet(isPresented: Binding(
            get: { setTypePickerSetId != nil },
            set: { if !$0 { setTypePickerSetId = nil } }
        )) {
            if let setId = setTypePickerSetId,
               let index = sets.firstIndex(where: { $0.id == setId }) {
                SetTypePickerSheet(
                    currentType: sets[index].type ?? .working,
                    onSelect: { newType in
                        sets[index].type = newType
                        setTypePickerSetId = nil
                    },
                    onDismiss: { setTypePickerSetId = nil }
                )
            }
        }
    }
    
    // MARK: - Column Widths
    
    private func columnWidths(for totalWidth: CGFloat) -> ColumnWidths {
        if isPlanningMode {
            // No Done column: SET 15%, WEIGHT 40%, REPS 22%, RIR 23%
            return ColumnWidths(
                set: totalWidth * 0.15,
                weight: totalWidth * 0.40,
                reps: totalWidth * 0.22,
                rir: totalWidth * 0.23,
                done: 0
            )
        } else {
            // With Done: SET 12%, WEIGHT 35%, REPS 18%, RIR 17%, DONE 18%
            return ColumnWidths(
                set: totalWidth * 0.12,
                weight: totalWidth * 0.35,
                reps: totalWidth * 0.18,
                rir: totalWidth * 0.17,
                done: totalWidth * 0.18
            )
        }
    }
    
    private struct ColumnWidths {
        let set: CGFloat
        let weight: CGFloat
        let reps: CGFloat
        let rir: CGFloat
        let done: CGFloat
    }
    
    // MARK: - Grid Header
    
    private func gridHeader(widths: ColumnWidths) -> some View {
        HStack(spacing: 0) {
            Text("SET")
                .frame(width: widths.set, alignment: .leading)
            Text("WEIGHT")
                .frame(width: widths.weight, alignment: .trailing)
            Text("REPS")
                .frame(width: widths.reps, alignment: .trailing)
            Text("RIR")
                .frame(width: widths.rir, alignment: .center)
            if !isPlanningMode {
                Text("✓")
                    .frame(width: widths.done, alignment: .center)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color.textSecondary)
        .frame(height: 28)
        .padding(.horizontal, Space.md)
        .background(Color.surfaceElevated.opacity(0.4))
    }
    
    // MARK: - Grid Row
    
    private func gridRow(for set: PlanSet, at index: Int, widths: ColumnWidths) -> some View {
        let isWarmup = set.isWarmup
        
        return HStack(spacing: 0) {
            // SET column
            Button { setTypePickerSetId = set.id } label: {
                HStack(spacing: 4) {
                    Text(displayNumber(for: index))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundColor(isWarmup ? Color.textSecondary : Color.textPrimary)
                    
                    if let badge = setTypeBadge(for: set) {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.textInverse)
                            .frame(width: 16, height: 16)
                            .background(set.type == .failureSet ? Color.destructive : Color.warning)
                            .clipShape(Circle())
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: widths.set, alignment: .leading)
            
            // WEIGHT column
            GridCell(
                value: set.weight.map { formatWeight($0) } ?? "—",
                isSelected: selectedCell == .weight(setId: set.id),
                isSecondary: isWarmup,
                alignment: .trailing,
                onTap: { selectedCell = .weight(setId: set.id) }
            )
            .frame(width: widths.weight)
            
            // REPS column
            GridCell(
                value: "\(set.reps)",
                isSelected: selectedCell == .reps(setId: set.id),
                isSecondary: isWarmup,
                alignment: .trailing,
                onTap: { selectedCell = .reps(setId: set.id) }
            )
            .frame(width: widths.reps)
            
            // RIR column
            GridCell(
                value: isWarmup ? "—" : (set.rir.map { "\($0)" } ?? "—"),
                isSelected: selectedCell == .rir(setId: set.id),
                isSecondary: isWarmup || set.rir == nil,
                alignment: .center,
                onTap: { if !isWarmup { selectedCell = .rir(setId: set.id) } }
            )
            .frame(width: widths.rir)
            
            // DONE column — direct toggle, no editor panel
            if !isPlanningMode {
                Button {
                    sets[index].isCompleted = !(sets[index].isCompleted ?? false)
                    HapticManager.selectionTick()
                } label: {
                    Image(systemName: set.isCompleted == true ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(set.isCompleted == true ? Color.success : Color.textSecondary.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: widths.done, alignment: .center)
            }
        }
        .frame(height: rowHeight)
        .padding(.horizontal, Space.md)
    }
    
    // MARK: - Helpers
    
    private func calculateGridHeight() -> CGFloat {
        let headerHeight: CGFloat = 28
        let hasSelectedCell = sets.contains { selectedCell?.setId == $0.id }
        let editorHeight: CGFloat = hasSelectedCell ? 100 : 0
        return headerHeight + (CGFloat(sets.count) * rowHeight) + editorHeight
    }
    
    private func displayNumber(for index: Int) -> String {
        let set = sets[index]
        if set.isWarmup {
            let warmupIndex = sets.prefix(index + 1).filter { $0.isWarmup }.count
            return "W\(warmupIndex)"
        } else {
            let workingIndex = sets.prefix(index + 1).filter { !$0.isWarmup }.count
            return "\(workingIndex)"
        }
    }
    
    private func setTypeBadge(for set: PlanSet) -> String? {
        guard let setType = set.type else { return nil }
        switch setType {
        case .warmup, .working: return nil
        case .failureSet: return "F"
        case .dropSet: return "D"
        }
    }
    
    private var weightUnit: WeightUnit { UserService.shared.weightUnit }

    private func formatWeight(_ w: Double) -> String {
        let displayed = WeightFormatter.display(w, unit: weightUnit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))\(weightUnit.label)"
        }
        return String(format: "%.1f\(weightUnit.label)", rounded)
    }
    
    private func duplicateSet(at index: Int) {
        guard index < sets.count else { return }
        let original = sets[index]
        let newSet = PlanSet(
            id: UUID().uuidString,
            type: original.type,
            reps: original.reps,
            weight: original.weight,
            rir: original.rir,
            isLinkedToBase: original.isLinkedToBase,
            isCompleted: nil,
            actualReps: nil,
            actualWeight: nil,
            actualRir: nil
        )
        sets.insert(newSet, at: index + 1)
    }
    
    private func rowBackground(for set: PlanSet) -> Color {
        if selectedCell?.setId == set.id {
            return Color.accentMuted
        } else if set.isWarmup {
            return Color.surfaceElevated.opacity(0.3)
        }
        return Color.surface
    }
    
    // MARK: - Add Set Button
    
    private var addSetButton: some View {
        Button { onAddSet(.working) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                Text("Add Set").font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(Color.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Grid Cell

private struct GridCell: View {
    let value: String
    let isSelected: Bool
    let isSecondary: Bool
    var alignment: Alignment = .center
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            Text(value)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: alignment)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accent.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accent : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var textColor: Color {
        if isSelected { return Color.accent }
        if isSecondary || value == "—" { return Color.textSecondary }
        return Color.textPrimary
    }
}

// MARK: - Inline Editing Dock

private struct InlineEditingDock: View {
    let selectedCell: GridCellField
    @Binding var sets: [PlanSet]
    @Binding var editScope: EditScope
    let onDismiss: () -> Void

    // State for direct text input
    @State private var isEditingText = false
    @State private var textInputValue = ""
    @FocusState private var textFieldFocused: Bool

    private var weightUnit: WeightUnit { UserService.shared.weightUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !isWarmupSet { scopeSelector }
            HStack(alignment: .center, spacing: Space.md) {
                valueEditor
                Spacer()
                // Done button - matches FocusModeSetGrid style
                Button(action: onDismiss) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                        Text("Done")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.textInverse)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Color.surfaceElevated.opacity(0.8))
        .onAppear {
            // Auto-focus text field for weight/reps when dock opens
            switch selectedCell {
            case .weight:
                // Show weight in user's preferred unit for editing
                let displayed = currentValue > 0 ? WeightFormatter.display(currentValue, unit: weightUnit) : 0
                textInputValue = displayed > 0 ? formatWeightForInput(displayed) : ""
                isEditingText = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    textFieldFocused = true
                }
            case .reps:
                textInputValue = "\(Int(currentValue))"
                isEditingText = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    textFieldFocused = true
                }
            case .rir:
                break
            }
        }
        .onDisappear {
            // Auto-save: commit any pending text input when switching cells
            if isEditingText { commitTextInput() }
        }
    }
    
    private var currentSetIndex: Int? { sets.firstIndex { $0.id == selectedCell.setId } }
    private var currentSet: PlanSet? { currentSetIndex.flatMap { sets[safe: $0] } }
    private var isWarmupSet: Bool { currentSet?.isWarmup ?? false }
    
    private var currentValue: Double {
        guard let set = currentSet else { return 0 }
        switch selectedCell {
        case .weight: return set.weight ?? 0
        case .reps: return Double(set.reps)
        case .rir: return Double(set.rir ?? 2)
        }
    }
    
    private var scopeSelector: some View {
        HStack(spacing: Space.xs) {
            Text("Apply to:").font(.system(size: 12)).foregroundColor(Color.textSecondary)
            ForEach(EditScope.allCases, id: \.rawValue) { scope in
                Button {
                    editScope = scope
                    HapticManager.selectionChanged()
                } label: {
                    Text(scopeLabel(scope))
                        .font(.system(size: 11, weight: editScope == scope ? .semibold : .regular))
                        .foregroundColor(editScope == scope ? .textInverse : Color.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(editScope == scope ? Color.accent : Color.surfaceElevated)
                        .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
    }
    
    private func scopeLabel(_ scope: EditScope) -> String {
        guard let idx = currentSetIndex else { return scope.rawValue }
        switch scope {
        case .allWorking: return "All (\(sets.filter { !$0.isWarmup && $0.type == .working }.count))"
        case .remaining: return "Remain (\(sets.indices.filter { !sets[$0].isWarmup && sets[$0].type == .working && $0 >= idx }.count))"
        case .thisOnly: return "This"
        }
    }
    
    @ViewBuilder
    private var valueEditor: some View {
        switch selectedCell {
        case .weight: weightEditor
        case .reps: repsEditor
        case .rir: rirEditor
        }
    }
    
    private var weightEditor: some View {
        HStack(spacing: Space.md) {
            let increment = WeightFormatter.plateIncrement(unit: weightUnit)
            stepButton(systemName: "minus", disabled: currentValue <= 0) {
                if isEditingText { isEditingText = false; textFieldFocused = false; textInputValue = "" }
                let decremented = WeightFormatter.toKg(WeightFormatter.display(currentValue, unit: weightUnit) - increment, from: weightUnit)
                applyChange(decremented)
            }

            // Tappable value display / text field
            if isEditingText {
                VStack(spacing: 0) {
                    TextField("", text: $textInputValue)
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .focused($textFieldFocused)
                        .frame(width: 80)
                        .onSubmit { commitTextInput() }
                        .onChange(of: textFieldFocused) { _, newFocused in
                            if !newFocused { commitTextInput() }
                        }
                    Text(weightUnit.label).font(.system(size: 11)).foregroundColor(Color.textSecondary)
                }
                .frame(width: 90)
            } else {
                Button {
                    let displayed = currentValue > 0 ? WeightFormatter.display(currentValue, unit: weightUnit) : 0
                    textInputValue = displayed > 0 ? formatWeightForInput(displayed) : ""
                    isEditingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        textFieldFocused = true
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text(currentValue > 0 ? formatWeightForDisplay(currentValue) : "—")
                            .font(.system(size: 24, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                        Text(weightUnit.label).font(.system(size: 11)).foregroundColor(Color.textSecondary)
                    }
                    .frame(width: 80)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.surfaceElevated.opacity(0.5))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            stepButton(systemName: "plus", disabled: false) {
                if isEditingText { isEditingText = false; textFieldFocused = false; textInputValue = "" }
                let incremented = WeightFormatter.toKg(WeightFormatter.display(currentValue, unit: weightUnit) + increment, from: weightUnit)
                applyChange(incremented)
            }
        }
    }
    
    private var repsEditor: some View {
        HStack(spacing: Space.md) {
            stepButton(systemName: "minus", disabled: currentValue <= 1) {
                if isEditingText { isEditingText = false; textFieldFocused = false; textInputValue = "" }
                applyChange(currentValue - 1)
            }

            // Tappable value display / text field
            if isEditingText {
                VStack(spacing: 0) {
                    TextField("", text: $textInputValue)
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .focused($textFieldFocused)
                        .frame(width: 70)
                        .onSubmit { commitTextInput() }
                        .onChange(of: textFieldFocused) { _, newFocused in
                            if !newFocused { commitTextInput() }
                        }
                    Text("reps").font(.system(size: 11)).foregroundColor(Color.textSecondary)
                }
                .frame(width: 80)
            } else {
                Button {
                    textInputValue = "\(Int(currentValue))"
                    isEditingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        textFieldFocused = true
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text("\(Int(currentValue))")
                            .font(.system(size: 24, weight: .bold).monospacedDigit())
                            .foregroundColor(Color.textPrimary)
                        Text("reps").font(.system(size: 11)).foregroundColor(Color.textSecondary)
                    }
                    .frame(width: 70)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.surfaceElevated.opacity(0.5))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            stepButton(systemName: "plus", disabled: currentValue >= 30) {
                if isEditingText { isEditingText = false; textFieldFocused = false; textInputValue = "" }
                applyChange(currentValue + 1)
            }
        }
    }
    
    private func commitTextInput() {
        isEditingText = false
        textFieldFocused = false
        
        let trimmed = textInputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        switch selectedCell {
        case .weight:
            // Parse weight (allow decimal) — user input is in their preferred unit
            if let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
                let kg = WeightFormatter.toKg(value, from: weightUnit)
                let rounded = (kg * 4).rounded() / 4  // Round to nearest 0.25kg
                applyChange(max(0, rounded))
            }
        case .reps:
            // Parse reps (integer only)
            if let value = Int(trimmed) {
                applyChange(Double(min(30, max(1, value))))
            }
        default:
            break
        }
        
        textInputValue = ""
    }
    
    private var rirEditor: some View {
        HStack(spacing: Space.sm) {
            ForEach(0...5, id: \.self) { rir in
                Button { applyChange(Double(rir)) } label: {
                    Text("\(rir)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Int(currentValue) == rir ? .textInverse : Color.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Int(currentValue) == rir ? rirColor(rir) : Color.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func stepButton(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(disabled ? Color.textSecondary.opacity(0.3) : Color.accent)
                .frame(width: 44, height: 44)
                .background(Color.surfaceElevated)
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
    
    /// Format weight value (in kg) for display in user's unit (no suffix)
    private func formatWeightForDisplay(_ kg: Double) -> String {
        let displayed = WeightFormatter.display(kg, unit: weightUnit)
        let rounded = WeightFormatter.roundForDisplay(displayed)
        return rounded.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    /// Format weight value for input text field (no suffix)
    private func formatWeightForInput(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private func applyChange(_ newValue: Double) {
        guard let idx = currentSetIndex else { return }
        HapticManager.selectionTick()

        // Warmup sets always use thisOnly — scope selector is hidden for them
        let effectiveScope = isWarmupSet ? .thisOnly : editScope

        let indices: [Int]
        switch effectiveScope {
        case .allWorking: indices = sets.indices.filter { !sets[$0].isWarmup && sets[$0].type == .working }
        case .remaining: indices = sets.indices.filter { !sets[$0].isWarmup && sets[$0].type == .working && $0 >= idx }
        case .thisOnly: indices = [idx]
        }
        
        for i in indices {
            switch selectedCell {
            case .weight: sets[i].weight = newValue > 0 ? newValue : nil
            case .reps: sets[i].reps = max(1, Int(newValue))
            case .rir: if !sets[i].isWarmup { sets[i].rir = Int(newValue) }
            }
            if editScope == .thisOnly { sets[i].isLinkedToBase = false }
        }
    }
    
    private func rirColor(_ rir: Int) -> Color {
        switch rir {
        case 0: return Color.destructive
        case 1: return Color.warning
        case 2: return Color.accent
        default: return Color.textSecondary
        }
    }
}

// MARK: - Set Type Picker Sheet

private struct SetTypePickerSheet: View {
    let currentType: SetType
    let onSelect: (SetType) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Set Type")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.textSecondary)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.sm)
                
                VStack(spacing: 0) {
                    setTypeOption(type: .warmup, title: "Warm-up", icon: "flame", color: Color.textSecondary)
                    Divider().padding(.leading, 56)
                    setTypeOption(type: .working, title: "Working Set", icon: "dumbbell", color: Color.accent)
                    Divider().padding(.leading, 56)
                    setTypeOption(type: .failureSet, title: "Failure", icon: "flame.fill", color: Color.destructive)
                    Divider().padding(.leading, 56)
                    setTypeOption(type: .dropSet, title: "Drop Set", icon: "arrow.down.circle", color: Color.warning)
                }
                .background(Color.surface)
                Spacer()
            }
            .background(Color.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    private func setTypeOption(type: SetType, title: String, icon: String, color: Color) -> some View {
        Button { onSelect(type) } label: {
            HStack(spacing: Space.md) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(color).frame(width: 32)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(Color.textPrimary)
                Spacer()
                if currentType == type {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundColor(Color.accent)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, 14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
