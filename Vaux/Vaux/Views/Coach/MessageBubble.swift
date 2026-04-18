import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(renderMarkdown(message.content))
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(message.isUser ? Color.recoveryGreen.opacity(0.8) : Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let time = message.createdAt {
                    Text(formatTime(time))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            if !message.isUser { Spacer(minLength: 60) }
        }
    }

    private func renderMarkdown(_ text: String) -> AttributedString {
        var result = text
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private func formatTime(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        guard parts.count > 1 else { return "" }
        return String(parts[1].prefix(5))
    }
}
