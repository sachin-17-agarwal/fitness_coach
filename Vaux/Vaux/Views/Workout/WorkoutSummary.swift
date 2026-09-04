// WorkoutSummary.swift
// Vaux
//
// Post-workout summary in the scheme: the session named in the display face
// with a mint tick, the three facts as a stat row, heart rate as a ruled
// section, the top lift and any records as ledger rows, the coach's recap as
// a pull quote, and DONE.

import SwiftUI

struct WorkoutSummaryView: View {
    let summary: WorkoutSummary
    /// "Legs" — named in the header. Empty falls back to "Session".
    var sessionType: String = ""
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.ink0.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statRow
                        .padding(.top, 26)

                    if summary.avgHR != nil || summary.maxHR != nil || summary.minHR != nil {
                        heartSection
                    }
                    if let top = summary.topExercise, !top.isEmpty {
                        topLiftSection(top)
                    }
                    if summary.prs.contains(where: \.isPR) {
                        recordsSection
                    }
                    recapSection

                    Spacer(minLength: 32)

                    Button {
                        Haptic.light()
                        onDismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                            Text("DONE")
                                .font(.display(24))
                                .kerning(0.6)
                        }
                        .foregroundStyle(Color.signalInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.signal))
                    }
                    .buttonStyle(PressScaleStyle())
                    .padding(.horizontal, Editorial.gutter)
                    .padding(.bottom, 24)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialEyebrow(text: "Session complete · \(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", color: Editorial.muted, size: 9.5, kerning: 2)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text((sessionType.isEmpty ? "Session" : sessionType).uppercased())
                    .font(.display(64))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.mint)
            }
            EditorialEyebrow(text: "Great work · recovery starts now", color: .mint, size: 10, kerning: 2.5)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 36)
    }

    // MARK: - Stat row

    private var statRow: some View {
        HStack(alignment: .top, spacing: 0) {
            statCell(label: "Tonnage", value: Editorial.tonnage(summary.tonnage), sub: "This session", first: true)
            statCell(label: "Sets", value: "\(summary.totalSets)", sub: summary.totalSets == 1 ? "Working set" : "Working sets", first: false)
            statCell(label: "Time", value: formatDuration(summary.duration), sub: "Start to end", first: false)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter)
        }
    }

    private func statCell(label: String, value: String, sub: String, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialEyebrow(text: label, color: Editorial.muted, size: 9, kerning: 1.8)
            Text(value)
                .font(.display(28))
                .foregroundStyle(Color.fg0)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            EditorialEyebrow(text: sub, color: Editorial.muted, size: 8.5, kerning: 1.2)
        }
        .padding(.leading, first ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if !first { Rectangle().fill(Color.line).frame(width: 1) }
        }
    }

    // MARK: - Heart

    private var heartSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Heart", right: "BPM · Whole session")
            HStack(alignment: .top, spacing: 0) {
                statCell(label: "Low", value: summary.minHR.map { "\($0)" } ?? "—", sub: "Between sets", first: true)
                statCell(label: "Average", value: summary.avgHR.map { "\($0)" } ?? "—", sub: "Over the session", first: false)
                statCell(label: "Peak", value: summary.maxHR.map { "\($0)" } ?? "—", sub: "Hardest set", first: false)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 14)
        }
    }

    // MARK: - Top lift and records

    private func topLiftSection(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Top lift")
            HStack(alignment: .firstTextBaseline) {
                Text(name.uppercased())
                    .font(.display(24))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                if let w = summary.topExerciseWeight, w > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(w.wholeOrOne)
                            .font(.display(24))
                            .foregroundStyle(Color.fg0)
                        EditorialEyebrow(text: "kg", color: Editorial.muted, size: 9, kerning: 1.2)
                    }
                }
            }
            .frame(height: 48)
            .padding(.horizontal, Editorial.gutter)
        }
    }

    private var recordsSection: some View {
        let records = summary.prs.filter(\.isPR)
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Personal records", right: "\(records.count) all-time best\(records.count == 1 ? "" : "s")")
            ForEach(Array(records.enumerated()), id: \.element.exercise) { index, pr in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(pr.exercise.uppercased())
                        .font(.display(22))
                        .foregroundStyle(Color.fg0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(pr.estimated1RM.wholeOrOne)
                                .font(.display(22))
                                .foregroundStyle(Color.signal)
                            EditorialEyebrow(text: "kg e1RM", color: Editorial.muted, size: 8.5, kerning: 1.2)
                        }
                        if pr.previous1RM > 0 {
                            EditorialEyebrow(text: "was \(pr.previous1RM.wholeOrOne)", color: Editorial.muted, size: 8.5, kerning: 1.2)
                        }
                    }
                }
                .frame(minHeight: 54)
                .padding(.horizontal, Editorial.gutter)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter) }
                }
            }
        }
    }

    // MARK: - Coach recap

    /// nil → still writing; "" → nothing to say (hidden); text → the quote.
    @ViewBuilder
    private var recapSection: some View {
        if summary.coachRecap == nil || !(summary.coachRecap ?? "").isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Coach recap")
                HStack(alignment: .top, spacing: 14) {
                    Text("“")
                        .font(.display(52))
                        .foregroundStyle(Color.signal)
                        .frame(height: 30, alignment: .top)
                        .offset(y: -4)
                    if let recap = summary.coachRecap, !recap.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            MarkdownText(content: recap)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .foregroundStyle(Color.bone)
                            EditorialEyebrow(text: "Coach", color: Editorial.muted, size: 9.5, kerning: 1.8)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            CoachTypingDots()
                                .padding(.top, 6)
                            EditorialEyebrow(text: "Coach · writing", color: Editorial.muted, size: 9.5, kerning: 1.8)
                        }
                    }
                }
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 14)
            }
        }
    }

    // MARK: - Building blocks

    private func sectionHeader(_ title: String, right: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            EditorialEyebrow(text: title)
            Spacer()
            if !right.isEmpty {
                EditorialEyebrow(text: right, color: Editorial.muted, size: 9.5, kerning: 1.5)
            }
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter)
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
