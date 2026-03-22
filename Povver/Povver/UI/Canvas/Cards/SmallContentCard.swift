import SwiftUI

public struct SmallContentCard: View {
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
                contentArea
            }
        }
    }

    @ViewBuilder private var contentArea: some View {
        if let error { InlineError(error) }
        else if isLoading { SkeletonBlock(height: 16) }
        else if isEmpty { Text("No content").textStyle(.caption).foregroundStyle(Color.textSecondary) }
        else {
            switch model.data {
            case .text(let text): Text(text).textStyle(.body)
            default: EmptyView().eraseToAnyView()
            }
        }
    }
}

fileprivate extension View {
    func eraseToAnyView() -> AnyView { AnyView(self) }
}


