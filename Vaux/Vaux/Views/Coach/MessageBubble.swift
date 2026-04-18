// MessageBubble.swift
// Vaux

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser {
                Spacer(minLength: 48)
                userBubble
            } else {
                CoachAvatar()
                coachBubble
                Spacer(minLength: 32)
            }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.system(size: 15))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Gradients.recovery)
                )

            if let time = message.createdAt {
                Text(formatTime(time))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.trailing, 4)
            }
        }
    }

    private var coachBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownText(content: message.content)
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.95))
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.cardBorder, lineWidth: 0.5)
                )

            if let time = message.createdAt {
                Text(formatTime(time))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private func formatTime(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        guard parts.count > 1 else { return "" }
        return String(parts[1].prefix(5))
    }
}
