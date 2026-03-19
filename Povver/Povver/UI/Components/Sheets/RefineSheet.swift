import SwiftUI

/// Sheet for refining AI output - uses SheetScaffold for v1.1 consistency
public struct RefineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var text: String
    private let onSubmit: (String) -> Void
    private let chips: [String]
    
    public init(text: Binding<String>, chips: [String] = ["Shorter", "More detail", "Simpler"], onSubmit: @escaping (String) -> Void) {
        self._text = text
        self.chips = chips
        self.onSubmit = onSubmit
    }
    
    public var body: some View {
        SheetScaffold(
            title: "Refine",
            doneTitle: "Submit",
            onCancel: { dismiss() },
            onDone: {
                onSubmit(text)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    ForEach(chips, id: \.self) { c in
                        Chip(c, isSelected: text == c) {
                            text = c
                        }
                    }
                }
                
                TextField("Add context", text: $text)
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
