import Foundation
import ImageIO
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

    var body: some View {
        let rendered = MathText.readable(text)
        if markdown, let styled = try? AttributedString(markdown: rendered, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(styled)
        } else {
            Text(rendered)
        }
    }
}
