import Foundation
import ImageIO
import SwaTex
import SwaTexRender
import SwiftUI

struct MessageBody: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = message.photo,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Фото")
            }
            if !message.content.isEmpty { FormattedReply(text: message.content, markdown: message.role == .assistant) }
            if let ending = message.ending {
                Text(ending == .stopped ? "Остановлено" : "Ответ прервался")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FormattedReply: View {
    let text: String
    var markdown = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var mathSize: CGFloat = 15

    private enum Row {
        case text(Text)
        case formula(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                switch entry.element {
                case .text(let text): text
                case .formula(let latex): DisplayFormula(latex: latex, size: mathSize)
                }
            }
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        var line: Text?
        func append(_ fragment: Text) {
            line = line.map { Text("\($0)\(fragment)") } ?? fragment
        }
        func flush() {
            if let line { result.append(.text(line)) }
            line = nil
        }
        for part in MathText.parts(text) {
            switch part {
            case .prose(let string): append(prose(string))
            case .formula(let latex, let display):
                if !display, let inline = inlineFormula(latex) {
                    append(inline)
                } else {
                    flush()
                    result.append(.formula(latex))
                }
            }
        }
        flush()
        return result
    }

    private func prose(_ string: String) -> Text {
        if markdown, let styled = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(styled)
        } else {
            Text(verbatim: string)
        }
    }

    private func inlineFormula(_ latex: String) -> Text? {
        #if os(watchOS)
        let maxWidth: CGFloat = 106
        #else
        let maxWidth: CGFloat = 205
        #endif
        let dark = colorScheme == .dark
        let color = SwaTex.Color(r: dark ? 1 : 0, g: dark ? 1 : 0, b: dark ? 1 : 0, a: 1)
        let options = RenderOptions(fontSize: mathSize, padding: 0)
        guard let list = FormulaRendering.layout(latex, style: .text, color: color) else { return nil }
        let metrics = DisplayListRenderer.metrics(for: list, options: options)
        guard metrics.width <= maxWidth, metrics.height <= mathSize * 2.8 else { return nil }
        let key = "\(dark)/\(displayScale)/\(mathSize)/\(latex)" as NSString
        let bitmap: CGImage
        if let cached = FormulaRendering.images.object(forKey: key) {
            bitmap = cached
        } else {
            guard let rendered = SwaTexRender.ImageRenderer.image(for: list, options: options, displayScale: displayScale) else { return nil }
            bitmap = rendered
            FormulaRendering.images.setObject(rendered, forKey: key, cost: rendered.bytesPerRow * rendered.height)
        }
        return Text(Image(bitmap, scale: displayScale, label: Text(verbatim: latex)))
            .baselineOffset(metrics.baseline - metrics.height)
    }
}

private struct DisplayFormula: View {
    let latex: String
    let size: CGFloat

    var body: some View {
        if FormulaRendering.layout(latex, style: .display, color: .black) != nil {
            ViewThatFits(in: .horizontal) {
                drawing.fixedSize()
                ScrollView(.horizontal) { drawing.fixedSize() }
                    .scrollIndicators(.visible)
            }
            .padding(.vertical, 3)
        } else {
            Text(verbatim: latex).font(.caption.monospaced())
        }
    }

    private var drawing: some View {
        MathView(latex)
            .font(size: size)
            .mathColor(SwiftUI.Color.primary)
    }
}

private enum FormulaRendering {
    static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func layout(_ latex: String, style: MathStyle, color: SwaTex.Color) -> DisplayList? {
        guard latex.utf8.count <= 8192 else { return nil }
        return try? SwaTexEngine.displayList(for: latex, style: style, color: color, cache: .shared)
    }
}
