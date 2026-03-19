import SwiftUI

struct RecommendationCardView: View {
    let recommendation: AgentRecommendation
    let isProcessing: Bool
    /// When true and recommendation was auto-applied by agent, shows emerald accent bar
    /// and muted change preview to visually distinguish auto-pilot notices.
    var autoPilotEnabled: Bool = false
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?

    /// Whether this card should show the auto-pilot visual treatment
    private var isAutoPilotNotice: Bool {
        autoPilotEnabled && recommendation.state == "applied" && recommendation.appliedBy == "agent"
    }

    private var weightUnit: WeightUnit { UserService.shared.weightUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Header: trigger pill + timestamp
            HStack(alignment: .center) {
                HStack(spacing: Space.xs) {
                    Image(systemName: triggerIcon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(triggerLabel)
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.3)
                }
                .foregroundColor(Color.accent)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .background(Color.accentMuted)
                .clipShape(Capsule())

                Spacer()

                Text(relativeTime)
                    .font(.system(size: 12))
                    .foregroundColor(Color.textTertiary)
            }

            // Summary
            Text(recommendation.recommendation.summary)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Rationale
            if let rationale = recommendation.recommendation.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.system(size: 13))
                    .foregroundColor(Color.textSecondary)
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Changes preview — show up to 3 changes
            if !recommendation.recommendation.changes.isEmpty {
                changesPreview
                    .opacity(isAutoPilotNotice ? 0.55 : 1.0)
            }

            // Actions or status
            if recommendation.state == "pending_review" {
                actionButtons
            } else {
                statusIndicator
            }
        }
        .padding(Space.lg)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous))
        .overlay(alignment: .leading) {
            if isAutoPilotNotice {
                UnevenRoundedRectangle(
                    topLeadingRadius: CornerRadiusToken.radiusCard,
                    bottomLeadingRadius: CornerRadiusToken.radiusCard
                )
                .fill(Color.accent)
                .frame(width: 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadiusToken.radiusCard, style: .continuous)
                .strokeBorder(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    // MARK: - Changes Preview

    private var changesPreview: some View {
        let displayChanges = Array(recommendation.recommendation.changes.prefix(3))
        return VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(displayChanges.enumerated()), id: \.offset) { _, change in
                changeRow(change)
            }
            if recommendation.recommendation.changes.count > 3 {
                Text("+ \(recommendation.recommendation.changes.count - 3) more")
                    .font(.system(size: 11))
                    .foregroundColor(Color.textTertiary)
                    .padding(.leading, Space.xs)
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bg)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon, style: .continuous))
    }

    private func changeRow(_ change: RecommendationChange) -> some View {
        HStack(spacing: Space.xs) {
            // "from" value (struck-through, muted)
            let from = formatChangeValue(change, isFrom: true)
            let to = formatChangeValue(change, isFrom: false)

            if !from.isEmpty {
                Text(from)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.textTertiary)
                    .strikethrough(true, color: Color.textTertiary.opacity(0.5))
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color.accent)

            Text(to)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.textPrimary)

            // Unit suffix
            Text(changeUnit(change))
                .font(.system(size: 11))
                .foregroundColor(Color.textTertiary)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: Space.sm) {
            // Decline — neutral secondary, not destructive
            Button(action: { onReject?() }) {
                Text("Decline")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.bg)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
                            .strokeBorder(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
                    )
            }
            .disabled(isProcessing)
            .opacity(isProcessing ? 0.5 : 1.0)

            // Accept — brand primary
            Button(action: { onAccept?() }) {
                HStack(spacing: Space.xs) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(Color.textInverse)
                    }
                    Text(acceptButtonText)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(Color.textInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
            }
            .disabled(isProcessing)
        }
        .padding(.top, Space.xs)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        if recommendation.state == "applied" {
            HStack(spacing: Space.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.accent)

                Text(recommendation.appliedBy == "agent" ? "Auto-applied" : "Applied")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.accent)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(Color.accentMuted)
            .clipShape(Capsule())
        } else if recommendation.state == "acknowledged" {
            HStack(spacing: Space.xs) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(Color.textTertiary)

                Text("Noted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    /// "Got it" for exercise/routine scoped recs, "Accept" for template-scoped
    private var acceptButtonText: String {
        let scope = recommendation.scope
        if scope == "exercise" || scope == "routine" {
            return "Got it"
        }
        return "Accept"
    }

    private var triggerIcon: String {
        switch recommendation.trigger {
        case "post_workout": return "flame.fill"
        case "weekly_review": return "chart.bar.fill"
        default: return "sparkles"
        }
    }

    private var triggerLabel: String {
        switch recommendation.trigger {
        case "post_workout": return "Post-workout"
        case "weekly_review": return "Weekly review"
        default: return recommendation.trigger.capitalized
        }
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(recommendation.createdAt)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    // MARK: - Change Formatting

    /// Returns the formatted value for a change row (from or to side)
    private func formatChangeValue(_ change: RecommendationChange, isFrom: Bool) -> String {
        let value = isFrom ? change.from : change.to
        if isNull(value) { return "" }

        let path = change.path

        if path.contains("weight_kg") {
            return formatWeight(value)
        }
        if path.contains("target_reps") || path.hasSuffix(".reps") {
            return formatNumeric(value)
        }
        if path.contains("target_rir") || path.hasSuffix(".rir") {
            return formatNumeric(value)
        }
        return formatGeneric(value)
    }

    /// Returns the unit suffix for a change (e.g., "kg", "reps", "RIR")
    private func changeUnit(_ change: RecommendationChange) -> String {
        let path = change.path
        if path.contains("weight_kg") { return weightUnit.label }
        if path.contains("target_reps") || path.hasSuffix(".reps") { return "reps" }
        if path.contains("target_rir") || path.hasSuffix(".rir") { return "RIR" }
        return ""
    }

    /// Path-aware change description — fallback for any context that needs a single-line string
    private func changeDescription(_ change: RecommendationChange) -> String {
        let path = change.path
        let from = change.from
        let to = change.to

        if path.contains("weight_kg") {
            return "\(formatWeight(from)) \u{2192} \(formatWeight(to))"
        }
        if path.contains("target_reps") || path.hasSuffix(".reps") {
            let toStr = formatNumeric(to)
            if isNull(from) { return "\u{2192} \(toStr) reps" }
            return "\(formatNumeric(from)) \u{2192} \(toStr) reps"
        }
        if path.contains("target_rir") || path.hasSuffix(".rir") {
            let toStr = formatNumeric(to)
            if isNull(from) { return "RIR \u{2192} \(toStr)" }
            return "RIR \(formatNumeric(from)) \u{2192} \(toStr)"
        }
        return "\(formatGeneric(from)) \u{2192} \(formatGeneric(to))"
    }

    private func isNull(_ value: AnyCodable) -> Bool {
        return value.value is NSNull
    }

    private func formatWeight(_ value: AnyCodable) -> String {
        switch value.value {
        case let n as Int:
            let displayed = WeightFormatter.display(Double(n), unit: weightUnit)
            let rounded = WeightFormatter.roundForDisplay(displayed)
            return rounded.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        case let n as Double:
            let displayed = WeightFormatter.display(n, unit: weightUnit)
            let rounded = WeightFormatter.roundForDisplay(displayed)
            return rounded.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        default: return "\u{2014}"
        }
    }

    private func formatNumeric(_ value: AnyCodable) -> String {
        switch value.value {
        case let n as Int: return "\(n)"
        case let n as Double: return String(format: n.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", n)
        case let s as String: return s
        default: return "\u{2014}"
        }
    }

    private func formatGeneric(_ value: AnyCodable) -> String {
        switch value.value {
        case let n as Int: return "\(n)"
        case let n as Double: return String(format: "%.1f", n)
        case let s as String: return s
        default: return "\u{2014}"
        }
    }
}
