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
                Color.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        hero

                        HStack(spacing: 10) {
                            statCard(value: summary.tonnage.weightString, label: "Tonnage", color: .accentPurple, icon: "scalemass.fill")
                            statCard(value: "\(summary.totalSets)", label: "Sets", color: .recoveryGreen, icon: "number")
                            statCard(value: formatDuration(summary.duration), label: "Duration", color: .accentAmber, icon: "timer")
                        }

                        if summary.avgHR != nil || summary.maxHR != nil {
                            heartRateSection
                        }

                        recapSection

                        if summary.prs.contains(where: \.isPR) {
                            prsSection
                        }

                        Spacer(minLength: 20)

                        Button(action: {
                            Haptic.light()
                            onDismiss()
                        }) {
                            Text("Done")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Gradients.recovery)
                                )
                        }
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
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Gradients.recovery)
                    .frame(width: 84, height: 84)
                    .blur(radius: 26)
                    .opacity(0.6)
                ZStack {
                    Circle()
                        .fill(Gradients.recovery)
                        .frame(width: 70, height: 70)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                }
            }

            Text("Session complete")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Great work. Recovery starts now.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textSecondary)
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.recoveryRed)
                Text("Heart rate")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
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
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(0.8)
                .foregroundStyle(Color.textTertiary)
            Text(value.map { "\($0)" } ?? "—")
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surface)
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
                    Text("Coach recap")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                }

                if let recap = summary.coachRecap, !recap.isEmpty {
                    Text(recap)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7).tint(Color.accentTeal)
                        Text("Writing your recap…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentAmber)
                Text("Personal records")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            ForEach(summary.prs.filter(\.isPR), id: \.exercise) { pr in
                HStack {
                    Text(pr.exercise)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(pr.estimated1RM.weightString)
                        .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.recoveryGreen)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.surface)
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
