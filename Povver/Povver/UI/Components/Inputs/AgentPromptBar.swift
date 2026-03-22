import SwiftUI

public struct AgentPromptBar: View {
    @Binding private var text: String
    private let placeholder: String
    private let onSubmit: () -> Void
    public init(text: Binding<String>, placeholder: String = "Ask anything", onSubmit: @escaping () -> Void) {
        self._text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "plus")
                .foregroundColor(Color.textSecondary)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.sentences)

            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: Space.md) {
                        Image(systemName: "mic")
                            .foregroundColor(Color.textSecondary)
                        VoiceLevels()
                    }
                    .transition(.opacity)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.textInverse)
                        .padding(InsetsToken.all(Space.sm))
                        .background(Color.textPrimary)
                        .clipShape(Circle())
                        .onTapGesture {
                            HapticManager.primaryAction()
                            onSubmit()
                        }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .frame(width: 44, height: 32, alignment: .center)
            .animation(.easeInOut(duration: MotionToken.medium), value: text.isEmpty)
        }
        .padding(InsetsToken.symmetric(vertical: Space.md, horizontal: Space.lg))
        .background(Color.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.separatorLine, lineWidth: StrokeWidthToken.thin))
        .shadowStyle(ShadowsToken.level2)
    }
}

private struct VoiceLevels: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.textSecondary.opacity(0.6))
                    .frame(width: 2, height: 8 + 6 * abs(sin(phase + CGFloat(i))))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}

#if DEBUG
struct AgentPromptBar_Previews: PreviewProvider {
    @State static var text: String = ""
    static var previews: some View {
        VStack(spacing: Space.lg) {
            AgentPromptBar(text: $text, onSubmit: {})
            AgentPromptBar(text: .constant("hello"), onSubmit: {})
        }
        .padding(InsetsToken.screen)
    }
}
#endif


