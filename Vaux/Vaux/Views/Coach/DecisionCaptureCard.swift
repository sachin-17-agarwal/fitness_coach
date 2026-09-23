// DecisionCaptureCard.swift
// Vaux
//
// One proposal the coach made in chat, in plain words, with the two
// answers — under the reply where the agreement happened (stage 2 of
// docs/DECISION_CAPTURE.md). Record applies it through the same path a chat
// `Decision:` line takes; Not now leaves it in the log as declined. The
// Home tab shows the same card for anything still open the next morning.

import SwiftUI

struct DecisionCaptureCard: View {
    let capture: DecisionCapture
    let isAnswering: Bool
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(capture.eyebrow)
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.iris)
            Text(capture.text)
                .font(.system(size: 14))
                .foregroundStyle(Color.fg1)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                button("RECORD", loud: true) { onAnswer(true) }
                button("NOT NOW", loud: false) { onAnswer(false) }
                Spacer()
            }
            .disabled(isAnswering)
            .opacity(isAnswering ? 0.5 : 1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink2))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.iris.opacity(0.35), lineWidth: 1))
    }

    private func button(_ label: String, loud: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.medium()
            action()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(loud ? Color.signalInk : Color.fg0)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(loud ? Color.signal : Color.ink3))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(loud ? Color.clear : Color.line2, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .accessibilityLabel(label.capitalized)
    }
}

/// A recordable line inside a coach bubble — `Decision:`, `Proposed:`,
/// `Emphasis-next:`, `Substitute:`, `Order:` — set as a line of record
/// rather than prose, so the grammar reads as what it is. The actions live
/// on the card below the reply, not here.
struct DecisionLine: View {
    let line: String

    private var parts: (eyebrow: String, body: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":") {
            let head = String(trimmed[..<colon]).uppercased()
            let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (head, rest)
        }
        return ("DECISION", trimmed)
    }

    /// True for a line in the recordable grammar's heads.
    static func isRecordable(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        return ["decision:", "proposed:", "emphasis-next:", "substitute:", "order:"].contains { lower.hasPrefix($0) }
    }

    var body: some View {
        let p = parts
        VStack(alignment: .leading, spacing: 4) {
            Text(p.eyebrow)
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.iris)
            Text(p.body)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.fg1)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ink2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.iris.opacity(0.25), lineWidth: 1))
    }
}
