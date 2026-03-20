import SwiftUI

@available(*, deprecated, message: "Use Text(\"...\").textStyle(.style) instead")
public enum PovverTextStyle {
    case display, title1, title2, title3
    case headline, body, callout, subheadline, footnote, caption
}

@available(*, deprecated, message: "Use Text().textStyle() instead")
public struct PovverText: View {
    private let text: String
    private let style: PovverTextStyle
    private let color: Color
    private let align: TextAlignment
    private let lineLimit: Int?

    public init(_ text: String, style: PovverTextStyle = .body, color: Color = Color.textPrimary, align: TextAlignment = .leading, lineLimit: Int? = nil) {
        self.text = text
        self.style = style
        self.color = color
        self.align = align
        self.lineLimit = lineLimit
    }

    public var body: some View {
        SwiftUI.Text(text)
            .font(font(for: style))
            .foregroundColor(color)
            .multilineTextAlignment(align)
            .lineLimit(lineLimit)
    }

    private func font(for style: PovverTextStyle) -> Font {
        switch style {
        case .display: return TypographyToken.display
        case .title1: return TypographyToken.title1
        case .title2: return TypographyToken.title2
        case .title3: return TypographyToken.title3
        case .headline: return TypographyToken.headline
        case .body: return TypographyToken.body
        case .callout: return TypographyToken.callout
        case .subheadline: return TypographyToken.subheadline
        case .footnote: return TypographyToken.footnote
        case .caption: return TypographyToken.caption
        }
    }
}

#if DEBUG
struct PovverText_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                PovverText("Display", style: .display)
                PovverText("Title 1", style: .title1)
                PovverText("Title 2", style: .title2)
                PovverText("Title 3", style: .title3)
                PovverText("Headline", style: .headline)
                PovverText("Body", style: .body)
                PovverText("Callout", style: .callout)
                PovverText("Subheadline", style: .subheadline)
                PovverText("Footnote", style: .footnote)
                PovverText("Caption", style: .caption)
            }
            .padding(InsetsToken.screen)
        }
    }
}
#endif


