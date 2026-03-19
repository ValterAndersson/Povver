import SwiftUI

public struct PovverSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let formatter: (Double) -> String

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, formatter: @escaping (Double) -> String = { String(Int($0)) }) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.formatter = formatter
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).textStyle(.secondary).foregroundStyle(Color.textSecondary)
                Spacer()
                Text(formatter(value)).textStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.accent)
        }
    }
}

#if DEBUG
struct PovverSlider_Previews: PreviewProvider {
    static var previews: some View {
        StatefulPreviewWrapper(8.0) { binding in
            PovverSlider("RIR", value: binding, in: 0...5, step: 1) { String(Int($0)) }
                .padding(InsetsToken.screen)
        }
    }
}
#endif


