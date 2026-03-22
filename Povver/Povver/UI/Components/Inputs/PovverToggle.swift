import SwiftUI

public struct PovverToggle: View {
    private let title: String
    @Binding private var isOn: Bool
    private let subtitle: String?

    public init(_ title: String, isOn: Binding<Bool>, subtitle: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.subtitle = subtitle
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).textStyle(.body)
                if let subtitle { Text(subtitle).textStyle(.caption).foregroundStyle(Color.textSecondary) }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.accent))
        .padding(.vertical, Space.xs)
        .onChange(of: isOn) { _, _ in
            HapticManager.selectionChanged()
        }
    }
}

#if DEBUG
struct PovverToggle_Previews: PreviewProvider {
    static var previews: some View {
        StatefulPreviewWrapper(true) { binding in
            VStack(alignment: .leading, spacing: Space.md) {
                PovverToggle("Enable analytics", isOn: binding)
                PovverToggle("Enable sensors", isOn: binding, subtitle: "Use Apple Watch for HR")
            }
            .padding(InsetsToken.screen)
        }
    }
}
#endif


