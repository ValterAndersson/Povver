import SwiftUI

/// Sheet for editing set targets - uses SheetScaffold for v1.1 consistency
public struct EditSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sets: Int
    @State private var reps: Int
    @State private var weightKg: Double  // Internal state: always kg
    private let onSubmit: (Int, Int, Double) -> Void

    // Weight unit (live preference — this sheet is used from Canvas, not Focus Mode)
    private var weightUnit: WeightUnit { UserService.shared.weightUnit }

    public init(initialSets: Int = 3, initialReps: Int = 10, initialWeight: Double = 0, onSubmit: @escaping (Int, Int, Double) -> Void) {
        self._sets = State(initialValue: initialSets)
        self._reps = State(initialValue: initialReps)
        self._weightKg = State(initialValue: initialWeight)  // initialWeight is in kg
        self.onSubmit = onSubmit
    }

    public var body: some View {
        SheetScaffold(
            title: "Edit Target",
            doneTitle: "Apply",
            onCancel: { dismiss() },
            onDone: {
                onSubmit(sets, reps, weightKg)  // Always submit kg
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    Text("Sets").textStyle(.secondary).foregroundStyle(Color.textSecondary)
                    Stepper(value: $sets, in: 1...10) { Text(String(sets)).textStyle(.bodyStrong) }
                }
                HStack {
                    Text("Reps").textStyle(.secondary).foregroundStyle(Color.textSecondary)
                    Stepper(value: $reps, in: 1...30) { Text(String(reps)).textStyle(.bodyStrong) }
                }
                HStack {
                    Text("Weight").textStyle(.secondary).foregroundStyle(Color.textSecondary)
                    Slider(
                        value: Binding(
                            get: { WeightFormatter.display(weightKg, unit: weightUnit) },
                            set: { newDisplayValue in
                                weightKg = WeightFormatter.toKg(newDisplayValue, from: weightUnit)
                            }
                        ),
                        in: 0...(weightUnit == .lbs ? 660 : 300),  // 300kg ≈ 660lbs
                        step: WeightFormatter.plateIncrement(unit: weightUnit)
                    ).tint(Color.accent)
                    Text(WeightFormatter.format(weightKg, unit: weightUnit)).textStyle(.bodyStrong)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }

                Spacer()
            }
            .padding(.top, Space.md)
        }
        .presentationDetents([.medium])
    }
}
