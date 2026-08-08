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
            // Side of the screen and bubble colour are what distinguish the
            // two speakers visually; spoken aloud they were indistinguishable,
            // so the sender is named. One element per message also means a
            // single swipe reads the whole thing rather than stopping at the
            // timestamp, which moves to the value where it stays out of the way.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(message.isUser ? "You" : "Coach") said: \(MarkdownText.plainText(message.content))"
            )
            .accessibilityValue(message.createdAt.map(formatTime) ?? "")
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.content)
                .font(.scaled(15, relativeTo: .body))
                .textSelection(.enabled)
                .foregroundStyle(Color.signalInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.signal)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
                .shadow(color: Color.signal.opacity(0.20), radius: 10, x: 0, y: 4)

            if let time = message.createdAt {
                Text(formatTime(time))
                    // fg2, not fg3: a timestamp is information to read, and
                    // fg3 is the rung reserved for marks that only support a
                    // reading. At 10pt it needs the contrast.
                    .font(.scaled(10, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(Color.fg2)
                    .padding(.trailing, 6)
            }
        }
    }

    private var coachBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            MarkdownText(content: message.content)
                .font(.scaled(15, relativeTo: .body))
                // Programming advice is the kind of thing you want to paste
                // into a note or a message; without this it could only be
                // re-read, never taken out of the app.
                .textSelection(.enabled)
                .foregroundStyle(Color.fg0.opacity(0.92))
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.ink3.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.line],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )

            if let time = message.createdAt {
                Text(formatTime(time))
                    // fg2, not fg3: a timestamp is information to read, and
                    // fg3 is the rung reserved for marks that only support a
                    // reading. At 10pt it needs the contrast.
                    .font(.scaled(10, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(Color.fg2)
                    .padding(.leading, 6)
            }
        }
    }

    /// Renders a server timestamp in the reader's own time zone and clock
    /// format.
    ///
    /// This previously sliced the first five characters out of the ISO string's
    /// time component, which is the wall clock at UTC — so every message was
    /// stamped with the offset of wherever the database happened to be, and
    /// always in 24-hour form regardless of locale. Parsing to a `Date` and
    /// letting `Date.FormatStyle` render it fixes both: the zone becomes the
    /// device's, and 14:32 shows as "2:32 PM" for anyone whose region uses it.
    private func formatTime(_ iso: String) -> String {
        guard let date = Self.parseTimestamp(iso) else { return "" }
        return date.formatted(.dateTime.hour().minute())
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
        // and the value is UTC by convention. Assuming UTC keeps the reading
        // correct instead of silently shifting it by the device's offset.
        let naive = DateFormatter()
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        naive.timeZone = TimeZone(identifier: "UTC")
        naive.locale = Locale(identifier: "en_US_POSIX")
        return naive.date(from: String(iso.prefix(19)))
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
                        .font(.eyebrow)
                        .kerning(1.4)
                }
                .foregroundStyle(Color.signal)

                Text(pr.exercise)
                    .font(.serifSM)
                    .foregroundStyle(Color.fg0)
                    .multilineTextAlignment(.center)

                Text(setLine)
                    .font(.numSM)
                    .foregroundStyle(Color.signal.opacity(0.95))

                if let improvement = improvementLine {
                    Text(improvement)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.fg1)
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
