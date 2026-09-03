// MessageBubble.swift
// Vaux
//
// One turn of the coach transcript. There are no bubbles: the speaker is an
// eyebrow (YOU in lime, COACH in mint) with the time on the right, and the
// turn is set as full-width running text. A coach reply that carries a plan
// renders it as a CoachPlanCard between its paragraphs.

import SwiftUI

struct TranscriptTurn: View {
    let message: ChatMessage
    /// Wired when a plan card should offer "Start session →".
    var onStartSession: (() -> Void)? = nil

    var body: some View {
        if message.isPR, let pr = message.pr {
            PRTurn(pr: pr)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                speakerLine
                if message.isUser {
                    Text(message.content)
                        .font(.scaled(15, relativeTo: .body))
                        .foregroundStyle(Color.bone)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    coachBody
                }
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "\(message.isUser ? "You" : "Coach") said: \(MarkdownText.plainText(message.content))"
            )
            .accessibilityValue(message.createdAt.map({ Self.formatTime($0) }) ?? "")
        }
    }

    private var speakerLine: some View {
        HStack(alignment: .firstTextBaseline) {
            EditorialEyebrow(
                text: message.isUser ? "You" : "Coach",
                color: message.isUser ? .signal : .mint,
                size: 10, kerning: 2.5
            )
            Spacer()
            if let time = message.createdAt.map({ Self.formatTime($0) }), !time.isEmpty {
                Text(time)
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(Color.fg3)
            }
        }
    }

    private var coachBody: some View {
        let reply = CoachReply.parse(message.content)
        return VStack(alignment: .leading, spacing: 14) {
            if !reply.before.isEmpty {
                prose(reply.before)
            }
            if !reply.plan.isEmpty {
                CoachPlanCard(
                    title: reply.planTitle ?? "Today's plan",
                    plan: reply.plan,
                    onStart: reply.plan.count > 1 ? onStartSession : nil
                )
            }
            if !reply.after.isEmpty {
                prose(reply.after)
            }
        }
    }

    private func prose(_ text: String) -> some View {
        MarkdownText(content: text)
            .font(.scaled(15, relativeTo: .body))
            .foregroundStyle(Color.fg0)
            .lineSpacing(4)
            .textSelection(.enabled)
    }

    /// Renders a server timestamp in the reader's own time zone and clock
    /// format.
    static func formatTime(_ iso: String) -> String {
        guard let date = parseTimestamp(iso) else { return "" }
        return date.formatted(.dateTime.hour().minute()).uppercased()
    }

    /// Supabase timestamps arrive with varying fractional-second precision and
    /// sometimes without a zone designator, so both strategies are tried before
    /// giving up. A returned nil just means no timestamp is drawn.
    static func parseTimestamp(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: iso) { return date }

        // No zone at all: Postgres `timestamp` columns serialise without one,
        // and the value is UTC by convention.
        let naive = DateFormatter()
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        naive.timeZone = TimeZone(identifier: "UTC")
        naive.locale = Locale(identifier: "en_US_POSIX")
        return naive.date(from: String(iso.prefix(19)))
    }
}

// MARK: - PR turn

struct PRTurn: View {
    let pr: PRInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorialEyebrow(text: "New PR", color: .signal, size: 10, kerning: 2.5)
            Text(pr.exercise.uppercased())
                .font(.display(26))
                .foregroundStyle(Color.fg0)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(setLine)
                    .font(.display(20))
                    .foregroundStyle(Color.signal)
                if let improvement = improvementLine {
                    EditorialEyebrow(text: improvement, color: Editorial.muted, size: 9.5, kerning: 1.4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.signal.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.signal.opacity(0.35), lineWidth: 1))
        .padding(.top, 20)
        .accessibilityElement(children: .combine)
    }

    private var setLine: String {
        "\(pr.weightKg.wholeOrOne) KG × \(pr.reps)"
    }

    private var improvementLine: String? {
        guard let e1rm = pr.estimated1RM else { return nil }
        let e1rmStr = String(format: "%.1f", e1rm)
        if let pct = pr.improvementPct {
            return "e1RM \(e1rmStr) kg · +\(String(format: "%.1f", pct))%"
        }
        return "e1RM \(e1rmStr) kg"
    }
}

// MARK: - Coach avatar
//
// Still used by the workout screen, summary and briefing strips.

struct CoachAvatar: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.ink3)
            Circle()
                .stroke(Color.line2, lineWidth: 1)
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.signal)
        }
        .frame(width: 30, height: 30)
    }
}
