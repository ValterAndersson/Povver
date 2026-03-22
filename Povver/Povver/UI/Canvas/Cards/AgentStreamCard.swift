import SwiftUI

public struct AgentStreamCard: View {
    private let model: CanvasCardModel
    @State private var visibleStepCount: Int = 1
    public init(model: CanvasCardModel) { self.model = model }
    @Environment(\.cardActionHandler) private var handleAction
    public var body: some View {
        CardContainer(status: model.status) {
            VStack(alignment: .leading, spacing: Space.sm) {
                CardHeader(title: model.title ?? "Assistant", subtitle: model.subtitle, lane: model.lane, status: model.status, timestamp: Date(), menuActions: model.menuItems, onAction: { action in handleAction(action, model) })
                if case .agentStream(let steps) = model.data {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(steps.prefix(visibleStepCount).enumerated()), id: \.element.id) { _, step in
                            row(for: step)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .onAppear { animateSteps(steps) }
                }
            }
                if !model.actions.isEmpty { CardActionBar(actions: model.actions, onAction: { action in handleAction(action, model) }) }
        }
    }

    @ViewBuilder private func row(for step: AgentStreamStep) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon(for: step.kind))
                .foregroundColor(color(for: step.kind))
            VStack(alignment: .leading, spacing: Space.xs) {
                switch step.kind {
                case .thinking:
                    Text("Thinking…")
                        .textStyle(.secondary)
                        .foregroundStyle(Color.textSecondary)
                    ProgressView().progressViewStyle(.circular)
                case .info:
                    Text(step.text ?? "")
                        .textStyle(.body)
                case .lookup:
                    Text(step.text ?? "")
                        .textStyle(.secondary)
                        .foregroundStyle(Color.textSecondary)
                case .result:
                    Text(step.text ?? "")
                        .textStyle(.body)
                }
            }
            Spacer()
        }
    }

    private func icon(for kind: AgentStreamStep.Kind) -> String {
        switch kind { case .thinking: return "brain.head.profile"; case .info: return "info.circle"; case .lookup: return "magnifyingglass"; case .result: return "checkmark.circle" }
    }
    private func color(for kind: AgentStreamStep.Kind) -> Color {
        switch kind { case .thinking: return Color.accent; case .info: return Color.textSecondary; case .lookup: return Color.accent; case .result: return Color.success }
    }

    private func animateSteps(_ steps: [AgentStreamStep]) {
        var delay: Double = 0
        for (idx, step) in steps.enumerated() {
            delay += (Double(step.durationMs ?? 800) / 1000.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: MotionToken.medium)) { visibleStepCount = idx + 1 }
            }
        }
    }
}

#if DEBUG
struct AgentStreamCard_Previews: PreviewProvider {
    static var previews: some View {
        let steps: [AgentStreamStep] = [
            AgentStreamStep(kind: .thinking),
            AgentStreamStep(kind: .info, text: "Thought for 4 sec", durationMs: 1000),
            AgentStreamStep(kind: .info, text: "Let me understand your background and goals…", durationMs: 1200),
            AgentStreamStep(kind: .lookup, text: "Looking up profile", durationMs: 800),
            AgentStreamStep(kind: .result, text: "Found profile", durationMs: 800),
            AgentStreamStep(kind: .thinking)
        ]
        let model = CanvasCardModel(type: .analysis_task, title: "Planning Program", data: .agentStream(steps: steps))
        return ScrollView { AgentStreamCard(model: model).padding(InsetsToken.screen) }
    }
}
#endif


