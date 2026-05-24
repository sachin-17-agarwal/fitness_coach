// MessageBubble.swift
// Vaux

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.isPR, let pr = message.pr {
            PRBubble(pr: pr)
        } else {
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
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.content)
                .font(.system(size: 15))
                .foregroundStyle(Color.fg0)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.line2, lineWidth: 0.5)
                )

            if let time = message.createdAt {
                Text(formatTime(time))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.fg3)
                    .padding(.trailing, 6)
            }
        }
    }

    private var coachBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            MarkdownText(content: message.content)
                .font(.system(size: 15))
                .foregroundStyle(Color.fg0.opacity(0.92))
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.ink2)
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.iris.opacity(0.04), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.iris.opacity(0.2), Color.line],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )

            if let time = message.createdAt {
                Text(formatTime(time))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.fg3)
                    .padding(.leading, 6)
            }
        }
    }

    private func formatTime(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        guard parts.count > 1 else { return "" }
        return String(parts[1].prefix(5))
    }
}

// MARK: - PR celebration bubble

struct PRBubble: View {
    let pr: PRInfo

    var body: some View {
        HStack {
            Spacer(minLength: 16)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("NEW PR")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .kerning(1.4)
                }
                .foregroundStyle(Color.signal)

                Text(pr.exercise)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(setLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.signal.opacity(0.95))

                if let improvement = improvementLine {
                    Text(improvement)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.signal.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.signal.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: Color.signal.opacity(0.25), radius: 16, x: 0, y: 6)

            Spacer(minLength: 16)
        }
    }

    private var setLine: String {
        let weight = pr.weightKg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", pr.weightKg)
            : String(format: "%.1f", pr.weightKg)
        return "\(weight) kg × \(pr.reps)"
    }

    private var improvementLine: String? {
        guard let e1rm = pr.estimated1RM else { return nil }
        let e1rmStr = String(format: "%.1f", e1rm)
        if let pct = pr.improvementPct {
            return "e1RM \(e1rmStr) kg  •  +\(String(format: "%.1f", pct))%"
        }
        return "e1RM \(e1rmStr) kg"
    }
}
