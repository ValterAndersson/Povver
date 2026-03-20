import SwiftUI

/// Compact trend indicator: "+2.5 kg" in emerald or neutral.
struct TrendDelta: View {
    let value: Double
    let unit: String
    let format: String // e.g., "%.1f"

    var body: some View {
        let isPositive = value > 0
        let sign = isPositive ? "+" : ""
        let color: Color = isPositive ? .accent : .textTertiary

        Text("\(sign)\(String(format: format, value)) \(unit)")
            .textStyle(.micro)
            .fontWeight(.medium)
            .foregroundColor(color)
            .monospacedDigit()
    }
}

/// PR badge — small emerald capsule.
struct PRBadge: View {
    var body: some View {
        Text("PR")
            // 10pt is below the smallest token (micro = 12pt) — intentionally off-token for badge scale
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.textInverse)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accent)
            .clipShape(Capsule())
    }
}
