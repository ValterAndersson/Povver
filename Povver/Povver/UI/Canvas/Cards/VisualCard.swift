import SwiftUI

public struct VisualCard: View {
    private let model: CanvasCardModel
    private let isLoading: Bool
    private let isEmpty: Bool
    private let error: String?
    public init(model: CanvasCardModel, isLoading: Bool = false, isEmpty: Bool = false, error: String? = nil) {
        self.model = model
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.error = error
    }
    public var body: some View {
        CardContainer(status: model.status) {
            VStack(alignment: .leading, spacing: Space.sm) {
                CardHeader(title: model.title, subtitle: model.subtitle, lane: model.lane, status: model.status, timestamp: Date())
                chartArea
            }
        }
    }

    @ViewBuilder private var chartArea: some View {
        if let error { InlineError(error) }
        else if isLoading { skeleton }
        else if isEmpty { emptyState }
        else { baselineChart }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SkeletonBlock(height: 160, corner: CornerRadiusToken.radiusControl)
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous)
            .stroke(Color.separatorLine, lineWidth: StrokeWidthToken.hairline)
            .background(Color.surface)
            .frame(minHeight: 160)
            .overlay(
                Text("No data yet").textStyle(.secondary).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
    }

    private var baselineChart: some View {
        // Placeholder chart area with baseline theming
        Rectangle()
            .fill(Color.surface)
            .frame(minHeight: 160)
            .overlay(
                VStack(spacing: Space.xs) {
                    Divider().background(Color.separatorLine)
                    Spacer()
                    Divider().background(Color.separatorLine)
                    Spacer()
                    Divider().background(Color.separatorLine)
                }
                .padding(InsetsToken.all(Space.md))
            )
            .overlay(
                Text("[Visualization]").textStyle(.secondary).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
    }
}


