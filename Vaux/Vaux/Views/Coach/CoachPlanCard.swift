// CoachPlanCard.swift
// Vaux
//
// A coach reply that contains a plan renders the plan as ledger rows — one
// per exercise, Anton name, set structure beneath, prescription on the right —
// instead of flattening it into markdown. The rows use the same vocabulary as
// the History tabs, so the coach's structure becomes the page's structure.

import SwiftUI

/// Splits a coach message into the prose around a plan and the plan itself.
struct CoachReply {
    let before: String
    let planTitle: String?
    let plan: [ExercisePrescription]
    let after: String

    /// Lines that belong to an exercise block once one has started.
    private static let blockPrefixes = [
        "warm", "working", "work:", "top set", "primary", "main",
        "back-off", "backoff", "back off", "drop", "light",
        "form", "cue", "tempo", "rest", "revised", "revision",
    ]

    static func parse(_ content: String) -> CoachReply {
        let plan = PrescriptionParser.parse(content)
        guard !plan.isEmpty else {
            return CoachReply(before: content, planTitle: nil, plan: [], after: "")
        }

        let lines = content.components(separatedBy: "\n")
        let namePattern = #"^[ \t]*\*{1,2}[^*\n]+\*{1,2}"#
        func isName(_ line: String) -> Bool {
            line.range(of: namePattern, options: .regularExpression) != nil
        }
        func isBlockLine(_ line: String) -> Bool {
            let lower = PrescriptionParser.canonicalisePhaseLabel(
                line.trimmingCharacters(in: .whitespaces).lowercased()
            )
            if lower.isEmpty { return true }
            if isName(line) { return true }
            if blockPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
            // "3 sets: 90kg x12 RPE7" — the loose form the parser also accepts.
            return lower.range(of: #"^\d+\s*(sets?|x)\b"#, options: .regularExpression) != nil
        }

        guard let start = lines.firstIndex(where: isName) else {
            return CoachReply(before: content, planTitle: nil, plan: plan, after: "")
        }
        var end = start
        var cursor = start
        while cursor < lines.count, isBlockLine(lines[cursor]) {
            if !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { end = cursor }
            cursor += 1
        }

        var beforeLines = Array(lines[..<start])
        var title: String?
        // "Full plan — Pull (16 working sets):" directly above the blocks is
        // the card's title, not a paragraph of its own.
        if let lastIndex = beforeLines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let candidate = beforeLines[lastIndex].trimmingCharacters(in: .whitespaces)
            if candidate.hasSuffix(":"), candidate.count < 90 {
                var t = String(candidate.dropLast())
                t = t.replacingOccurrences(of: "*", with: "")
                if let paren = t.firstIndex(of: "(") { t = String(t[..<paren]) }
                title = t.trimmingCharacters(in: .whitespaces)
                beforeLines.remove(at: lastIndex)
            }
        }

        let afterLines = end + 1 < lines.count ? Array(lines[(end + 1)...]) : []
        return CoachReply(
            before: beforeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            planTitle: title,
            plan: plan,
            after: afterLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct CoachPlanCard: View {
    let title: String
    let plan: [ExercisePrescription]
    var onStart: (() -> Void)? = nil

    @State private var expanded = false
    private let collapsedCount = 3

    private var visible: [ExercisePrescription] {
        expanded ? plan : Array(plan.prefix(collapsedCount))
    }
    private var hiddenCount: Int { max(0, plan.count - collapsedCount) }
    private var workingSetCount: Int {
        plan.reduce(0) { $0 + $1.workingSets.count + $1.backoffSets.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                EditorialEyebrow(text: title, size: 10, kerning: 2.5)
                Spacer()
                EditorialEyebrow(
                    text: "\(workingSetCount) working set\(workingSetCount == 1 ? "" : "s")",
                    color: Editorial.muted, size: 9, kerning: 1.4
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, rx in
                    PlanRow(index: index + 1, prescription: rx, ruled: index > 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            HStack {
                if hiddenCount > 0 {
                    Button {
                        Haptic.selection()
                        withAnimation(Motion.smooth) { expanded.toggle() }
                    } label: {
                        EditorialEyebrow(
                            text: expanded ? "Show less" : "+ \(hiddenCount) more",
                            color: Editorial.muted, size: 9.5, kerning: 1.8
                        )
                        .frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let onStart {
                    Button {
                        Haptic.medium()
                        onStart()
                    } label: {
                        EditorialEyebrow(text: "Start session →", color: .signal, size: 10, kerning: 2.2)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start this session")
                }
            }
            .frame(height: 40)
            .padding(.horizontal, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ink2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.line, lineWidth: 1))
    }
}

private struct PlanRow: View {
    let index: Int
    let prescription: ExercisePrescription
    let ruled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(index)")
                .font(.display(13))
                .foregroundStyle(Color.fg3)
                .frame(width: 12, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(prescription.exerciseName.uppercased())
                    .font(.display(18))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                EditorialEyebrow(text: structureLine, color: Editorial.muted, size: 9, kerning: 1.4)
            }

            Spacer(minLength: 10)

            Text(prescriptionLine)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.fg1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: 46)
        .overlay(alignment: .top) {
            if ruled { Rectangle().fill(Color.line).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    private var structureLine: String {
        var parts: [String] = []
        if !prescription.warmupSets.isEmpty { parts.append("\(prescription.warmupSets.count) warm-up") }
        if !prescription.workingSets.isEmpty { parts.append("\(prescription.workingSets.count) working") }
        if !prescription.backoffSets.isEmpty { parts.append("\(prescription.backoffSets.count) back-off") }
        return parts.joined(separator: " · ")
    }

    private var prescriptionLine: String {
        guard let top = prescription.workingSets.first ?? prescription.backoffSets.first else {
            if let w = prescription.warmupSets.first {
                return "\(ExerciseCatalog.setWeightLabel(w.weight, exercise: prescription.exerciseName)) × \(w.reps)"
            }
            return ""
        }
        var reps = "\(top.reps)"
        if let high = top.repsHigh, high > top.reps { reps = "\(top.reps)–\(high)" }
        var line = "\(ExerciseCatalog.setWeightLabel(top.weight, exercise: prescription.exerciseName)) × \(reps)"
        if let rpe = top.rpe {
            line += " @\(rpe.wholeOrOne)"
        }
        return line
    }
}
