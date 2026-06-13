// WorkoutSummary.swift
// Vaux
//
// Post-workout summary sheet — tonnage, sets, duration, and PRs.

import SwiftUI

struct WorkoutSummaryView: View {
    let summary: WorkoutSummary
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        hero
                            .riseIn()

                        HStack(spacing: 10) {
                            statCard(value: summary.tonnage.weightString, label: "Tonnage", color: .iris, icon: "scalemass.fill")
                            statCard(value: "\(summary.totalSets)", label: "Sets", color: .mint, icon: "number")
                            statCard(value: formatDuration(summary.duration), label: "Duration", color: .amber, icon: "timer")
                        }
                        .riseIn(delay: 0.08)

                        if summary.avgHR != nil || summary.maxHR != nil {
                            heartRateSection
                                .riseIn(delay: 0.16)
                        }

                        recapSection
                            .riseIn(delay: 0.22)

                        if summary.prs.contains(where: \.isPR) {
                            prsSection
                                .riseIn(delay: 0.28)
                        }

                        Spacer(minLength: 20)

                        Button(action: {
                            Haptic.light()
                            onDismiss()
                        }) {
                            CTALabel(text: "Done", icon: "checkmark")
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            IconBadge(systemName: "checkmark", accent: .signal, size: 76)

            Text("Session complete")
                .font(.serifMD)
                .foregroundStyle(Color.fg0)

            Text("GREAT WORK · RECOVERY STARTS NOW")
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.fg2)
        }
        .padding(.top, 8)
    }

    private func statCard(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(value)
                .font(.numMD)
                .foregroundStyle(Color.fg0)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ember)
                Eyebrow(text: "Heart rate")
            }

            HStack(spacing: 10) {
                hrCell(label: "Min", value: summary.minHR)
                hrCell(label: "Avg", value: summary.avgHR)
                hrCell(label: "Max", value: summary.maxHR)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 0, cornerRadius: 18)
    }

    private func hrCell(label: String, value: Int?) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)
            Text(value.map { "\($0)" } ?? "—")
                .font(.numSM)
                .foregroundStyle(Color.fg0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ink1)
        )
    }

    @ViewBuilder
    private var recapSection: some View {
        // Three states:
        //   coachRecap == nil       → still loading, show spinner.
        //   coachRecap == ""        → explicitly no recap (e.g. zero
        //                              working sets), hide the section.
        //   coachRecap == "<text>"  → render the coach note.
        if summary.coachRecap == nil || !(summary.coachRecap ?? "").isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CoachAvatar()
                    Eyebrow(text: "Coach recap")
                    Spacer()
                }

                if let recap = summary.coachRecap, !recap.isEmpty {
                    Text(recap)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.fg0.opacity(0.9))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7).tint(Color.signal)
                        Text("Writing your recap…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.fg1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .darkCard(padding: 0, cornerRadius: 18)
        }
    }

    private var prsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.signal)
                Eyebrow(text: "Personal records")
            }

            ForEach(summary.prs.filter(\.isPR), id: \.exercise) { pr in
                HStack {
                    Text(pr.exercise)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.fg0)
                    Spacer()
                    Text(pr.estimated1RM.weightString)
                        .font(.numSM)
                        .foregroundStyle(Color.signal)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ink1)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 0, cornerRadius: 18)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
