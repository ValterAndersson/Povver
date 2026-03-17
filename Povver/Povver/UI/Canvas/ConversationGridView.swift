import SwiftUI

public struct ConversationGridView: View {
    private let cards: [CanvasCardModel]
    private let onAccept: (String) -> Void
    private let onReject: (String) -> Void
    // 12-track conceptual grid via Grid + .gridCellColumns spanning 4/6/12
    public init(cards: [CanvasCardModel], columns: Int = 12, onAccept: @escaping (String) -> Void = { _ in }, onReject: @escaping (String) -> Void = { _ in }) {
        self.cards = cards
        self.onAccept = onAccept
        self.onReject = onReject
    }
    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.lg) {
            ForEach(cards) { card in
                EquatableCardHost(card: card, allCards: cards, onAccept: { onAccept(card.id) }, onReject: { onReject(card.id) })
                    .newItemHighlight()
                    .gridCellColumns(card.width.columns)
            }
        }
        .frame(maxWidth: LayoutToken.contentMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.lg)
    }

    @ViewBuilder private func cardView(_ card: CanvasCardModel) -> some View {
        switch card.data {
        case .text: SmallContentCard(model: card)
        case .visualization(let spec): VisualizationCard(spec: spec, cardId: card.id, actions: card.actions)
        case .visualizationLegacy: VisualCard(model: card)
        case .chat: ChatCard(model: card)
        case .suggestion:
            SuggestionCard(model: card, onAccept: { onAccept(card.id) }, onReject: { onReject(card.id) })
        case .sessionPlan: SessionPlanCard(model: card)
        case .programDay(_, let exercises):
            let options = exercises.map { ex in
                ListOption(title: ex.name, subtitle: "\(ex.setCount) sets", iconSystemName: "dumbbell")
            }
            ListCardWithExpandableOptions(model: card, options: options)
        case .agentStream: AgentStreamCard(model: card)
        case .list(let options):
            ListCardWithExpandableOptions(model: card, options: options)
        case .inlineInfo(let text):
            SmallContentCard(model: CanvasCardModel(type: .summary, title: "Info", data: .text(text)))
        case .groupHeader:
            ProposalGroupHeader(model: card, onAction: { action in
                // Surface through environment handler with card context
                let handler = Environment(\.cardActionHandler).wrappedValue
                handler(action, card)
            })
        case .clarifyQuestions:
            ClarifyQuestionsCard(model: card)
        case .routineOverview:
            RoutineOverviewCard(model: card)
        case .agentMessage:
            AgentMessageCard(model: card)
        case .routineSummary(let data):
            RoutineSummaryCard(model: card, data: data)
        case .analysisSummary(let data):
            AnalysisSummaryCard(model: card, data: data)
        }
    }
}

// MARK: - Equatable host to avoid unnecessary redraws
private struct EquatableCardHost: View, Equatable {
    let card: CanvasCardModel
    let allCards: [CanvasCardModel]
    let onAccept: () -> Void
    let onReject: () -> Void
    
    static func == (lhs: EquatableCardHost, rhs: EquatableCardHost) -> Bool { 
        lhs.card == rhs.card && lhs.allCards.count == rhs.allCards.count
    }
    
    var body: some View {
        cardContent
            .environment(\.canvasCards, allCards)
    }
    
    @ViewBuilder
    private var cardContent: some View {
        switch card.data {
        case .text: SmallContentCard(model: card)
        case .visualization(let spec): VisualizationCard(spec: spec, cardId: card.id, actions: card.actions)
        case .visualizationLegacy: VisualCard(model: card)
        case .chat: ChatCard(model: card)
        case .suggestion:
            SuggestionCard(model: card, onAccept: onAccept, onReject: onReject)
        case .sessionPlan: SessionPlanCard(model: card)
        case .programDay(_, let exercises):
            let options = exercises.map { ex in
                ListOption(title: ex.name, subtitle: "\(ex.setCount) sets", iconSystemName: "dumbbell")
            }
            ListCardWithExpandableOptions(model: card, options: options)
        case .agentStream: AgentStreamCard(model: card)
        case .list(let options):
            ListCardWithExpandableOptions(model: card, options: options)
        case .inlineInfo(let text):
            SmallContentCard(model: CanvasCardModel(type: .summary, title: "Info", data: .text(text)))
        case .groupHeader:
            ProposalGroupHeader(model: card, onAction: { action in
                let handler = Environment(\.cardActionHandler).wrappedValue
                handler(action, card)
            })
        case .clarifyQuestions:
            ClarifyQuestionsCard(model: card)
        case .routineOverview:
            RoutineOverviewCard(model: card)
        case .agentMessage:
            AgentMessageCard(model: card)
        case .routineSummary(let data):
            RoutineSummaryCard(model: card, data: data)
        case .analysisSummary(let data):
            AnalysisSummaryCard(model: card, data: data)
        }
    }
}

#if DEBUG
struct ConversationGridView_Previews: PreviewProvider {
    static var previews: some View {
        let lineChartSpec = VisualizationSpec(
            chartType: .line,
            title: "Squat e1RM Trend",
            subtitle: "6 months",
            data: ChartData(
                series: [
                    ChartSeries(name: "Squat", color: .primary, points: [
                        ChartDataPoint(x: 1, y: 120),
                        ChartDataPoint(x: 2, y: 125),
                        ChartDataPoint(x: 3, y: 128),
                        ChartDataPoint(x: 4, y: 130),
                    ])
                ]
            )
        )
        
        let demo: [CanvasCardModel] = [
            CanvasCardModel(type: .summary, title: "Today", data: .text("Upper body focus")),
            CanvasCardModel(type: .visualization, title: "Squat 6m", data: .visualization(spec: lineChartSpec)),
            CanvasCardModel(type: .session_plan, data: .sessionPlan(exercises: [
                PlanExercise(name: "Bench Press", sets: [
                    PlanSet(type: .working, reps: 8, weight: 60, rir: 2),
                    PlanSet(type: .working, reps: 8, weight: 60, rir: 2),
                    PlanSet(type: .working, reps: 8, weight: 60, rir: 1),
                    PlanSet(type: .working, reps: 8, weight: 60, rir: 1)
                ]),
                PlanExercise(name: "Row", sets: [
                    PlanSet(type: .working, reps: 8, weight: 40, rir: 2),
                    PlanSet(type: .working, reps: 8, weight: 40, rir: 2),
                    PlanSet(type: .working, reps: 8, weight: 40, rir: 1),
                    PlanSet(type: .working, reps: 8, weight: 40, rir: 1)
                ])
            ])),
            CanvasCardModel(type: .coach_proposal, title: "Increase load +2.5kg", data: .suggestion(title: "Adjust Load", rationale: "RIR ≤ 1 last set"))
        ]
        ScrollView { ConversationGridView(cards: demo, columns: 2).padding(InsetsToken.screen) }
    }
}
#endif
