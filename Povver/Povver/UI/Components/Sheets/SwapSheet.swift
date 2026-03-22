import SwiftUI

/// Sheet for AI swap options - uses SheetScaffold for v1.1 consistency
public struct SwapSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let onSubmit: (String, [String: String]) -> Void
    @State private var choice: String = "variant"
    @State private var details: String = ""
    
    public init(onSubmit: @escaping (String, [String: String]) -> Void) {
        self.onSubmit = onSubmit
    }
    
    public var body: some View {
        SheetScaffold(
            title: "Swap",
            doneTitle: "Apply",
            onCancel: { dismiss() },
            onDone: {
                onSubmit(choice, ["details": details])
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: Space.md) {
                Picker("What to swap", selection: $choice) {
                    Text("Muscle group").tag("muscle")
                    Text("Equipment").tag("equipment")
                    Text("Variant").tag("variant")
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.segmented)
                .onChange(of: choice) { _, _ in
                    HapticManager.selectionChanged()
                }

                TextField("Optional details", text: $details)
                    .textInputAutocapitalization(.sentences)
                    .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
                
                Spacer()
            }
            .padding(.top, Space.md)
        }
        .presentationDetents([.medium])
    }
}
