import SwiftUI

public struct ClarifyQuestionsCard: View {
    private let model: CanvasCardModel
    @State private var answers: [String: String] = [:]
    @State private var selectedOptions: Set<String> = []
    public init(model: CanvasCardModel) { self.model = model }
    @Environment(\.cardActionHandler) private var handleAction

    public var body: some View {
        CardContainer(status: model.status) {
            VStack(alignment: .leading, spacing: Space.md) {
                CardHeader(title: model.title ?? "A few questions", subtitle: model.subtitle, lane: model.lane, status: model.status, timestamp: Date(), menuActions: model.menuItems, onAction: { action in handleAction(action, model) })
                if case .clarifyQuestions(let qs) = model.data {
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForEach(qs) { q in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                PovverText(q.text, style: .subheadline)
                                    .foregroundColor(Color.textPrimary)
                                
                                if q.type == .text {
                                    // Text input with submit/skip
                                    TextField("Type your answer...", text: Binding(
                                        get: { answers[q.id] ?? "" },
                                        set: { answers[q.id] = $0 }
                                    ))
                                    .textInputAutocapitalization(.sentences)
                                    .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
                                    .background(Color.surfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl, style: .continuous))
                                    
                                } else if let opts = q.options {
                                    // List selection - clicking submits immediately for single_choice
                                    VStack(spacing: Space.xs) {
                                        ForEach(opts, id: \.self) { opt in
                                            Button(action: {
                                                if q.type == .multi_choice {
                                                    // Toggle selection for multi-choice
                                                    if selectedOptions.contains(opt) {
                                                        selectedOptions.remove(opt)
                                                    } else {
                                                        selectedOptions.insert(opt)
                                                    }
                                                    answers[q.id] = Array(selectedOptions).joined(separator: ",")
                                                } else {
                                                    // Single choice - auto submit
                                                    answers[q.id] = opt
                                                    submitAnswer()
                                                }
                                            }) {
                                                HStack {
                                                    PovverText(opt, style: .body)
                                                        .foregroundColor(isOptionSelected(opt, questionId: q.id) ? Color.textInverse : Color.textPrimary)
                                                    Spacer()
                                                    if isOptionSelected(opt, questionId: q.id) {
                                                        Image(systemName: q.type == .multi_choice ? "checkmark.square.fill" : "checkmark")
                                                            .foregroundColor(Color.textInverse)
                                                    }
                                                }
                                                .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
                                                .background(isOptionSelected(opt, questionId: q.id) ? Color.accent : Color.surfaceElevated)
                                                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                } else if q.type == .yes_no {
                                    // Yes/No buttons - clicking either submits immediately
                                    HStack(spacing: Space.md) {
                                        Button(action: {
                                            answers[q.id] = "yes"
                                            submitAnswer()
                                        }) {
                                            HStack {
                                                Image(systemName: "checkmark")
                                                PovverText("Yes", style: .body)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
                                            .background(Color.green)
                                            .foregroundColor(.textInverse)
                                            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        Button(action: {
                                            answers[q.id] = "no"
                                            submitAnswer()
                                        }) {
                                            HStack {
                                                Image(systemName: "xmark")
                                                PovverText("No", style: .body)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.md))
                                            .background(Color.red)
                                            .foregroundColor(.textInverse)
                                            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Show action buttons only for text questions or multi-choice
                if shouldShowActionButtons() {
                    HStack(spacing: Space.md) {
                        if hasTextQuestion() {
                            Button(action: skipQuestion) {
                                HStack {
                                    Image(systemName: "arrow.right")
                                    PovverText("Skip", style: .body)
                                }
                                .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.lg))
                                .background(Color.surfaceElevated)
                                .foregroundColor(Color.textSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        Button(action: submitAnswer) {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                PovverText("Submit", style: .body)
                            }
                            .padding(InsetsToken.symmetric(vertical: Space.sm, horizontal: Space.lg))
                            .background(Color.accent)
                            .foregroundColor(.textInverse)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }
    
    private func isOptionSelected(_ option: String, questionId: String) -> Bool {
        if selectedOptions.contains(option) {
            return true
        }
        return answers[questionId] == option
    }
    
    private func shouldShowActionButtons() -> Bool {
        guard case .clarifyQuestions(let qs) = model.data else { return false }
        // Show buttons for text input or multi-choice questions
        return qs.contains { $0.type == .text || $0.type == .multi_choice }
    }
    
    private func hasTextQuestion() -> Bool {
        guard case .clarifyQuestions(let qs) = model.data else { return false }
        return qs.contains { $0.type == .text }
    }
    
    private func submitAnswer() {
        guard case .clarifyQuestions(let qs) = model.data else { return }
        let payloadValue: String
        if qs.count == 1, let first = qs.first {
            let value = answers[first.id] ?? ""
            payloadValue = value
        } else if let answersData = try? JSONSerialization.data(withJSONObject: answers, options: []),
                  let answersJson = String(data: answersData, encoding: .utf8) {
            payloadValue = answersJson
        } else {
            payloadValue = answers.description
        }
        let submitAction = CardAction(
            kind: "submit",
            label: "Submit",
            style: .primary,
            payload: ["answers": payloadValue]
        )
        handleAction(submitAction, model)
    }
    
    private func skipQuestion() {
        // Send skip signal to agent
        let skipAction = CardAction(
            kind: "skip",
            label: "Skip",
            style: .secondary,
            payload: ["answers": "User skipped the question"]
        )
        handleAction(skipAction, model)
    }
}
