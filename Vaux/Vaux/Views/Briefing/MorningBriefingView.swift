// MorningBriefingView.swift
// Vaux
//
// Full-screen morning briefing on the editorial design system: serif
// greeting masthead, recovery hero with instrument ring, today's plan,
// and the coach-generated note.

import SwiftUI

struct MorningBriefingView: View {
    @State private var viewModel = BriefingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onStartWorkout: ((String) -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)

                if viewModel.isLoading && viewModel.briefing == nil {
                    loadingState
                } else if let b = viewModel.briefing {
                    content(b)
                } else {
                    errorState
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptic.light()
                        viewModel.markShown()
                        dismiss()
                    } label: {
                        toolbarIcon("xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptic.selection()
                        Task { await viewModel.refresh() }
                    } label: {
                        toolbarIcon("arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .task {
            if viewModel.briefing == nil {
                await viewModel.load()
            }
        }
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.fg1)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.ink2.opacity(0.9)))
            .overlay(Circle().stroke(Color.line, lineWidth: 1))
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            VauxLogo(size: 30, color: .signal)
                .shadow(color: Color.signal.opacity(0.5), radius: 14)
            HStack(spacing: 8) {
                GlowDot(color: .signal, size: 5)
                Text("COMPOSING BRIEFING")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ b: Briefing) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                greeting(b)
                    .riseIn()
                BriefingRecoveryHero(briefing: b)
                    .riseIn(delay: 0.06)
                BriefingPlanCard(briefing: b) {
                    Haptic.medium()
                    viewModel.markShown()
                    dismiss()
                    onStartWorkout?(b.mesocycle.sessionType)
                }
                .riseIn(delay: 0.12)
                BriefingNoteCard(note: b.coachNote)
                    .riseIn(delay: 0.18)
                actionRow(b)
                    .riseIn(delay: 0.24)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    // MARK: - Greeting masthead

    private func greeting(_ b: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GlowDot(color: .signal, size: 4)
                Eyebrow(text: "Morning briefing · \(prettyDate(b.date))")
            }

            Text(timeOfDayGreeting())
                .font(.serifLG)
                .foregroundStyle(Color.fg0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action row

    private func actionRow(_ b: Briefing) -> some View {
        VStack(spacing: 10) {
            Button {
                Haptic.medium()
                viewModel.markShown()
                dismiss()
                onStartWorkout?(b.mesocycle.sessionType)
            } label: {
                CTALabel(text: "Start \(b.mesocycle.sessionType) workout", icon: "play.fill")
            }
            .buttonStyle(PressScaleStyle())

            Button {
                Haptic.light()
                viewModel.markShown()
                dismiss()
                onOpenChat?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Chat with coach")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.fg0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.ink2.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.line2, lineWidth: 1)
                )
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.amber)
            Text("Couldn't load briefing")
                .font(.serifSM)
                .foregroundStyle(Color.fg0)
            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.uiSmall)
                    .foregroundStyle(Color.fg2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button {
                Haptic.light()
                Task { await viewModel.load() }
            } label: {
                Text("Retry")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.signalInk)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.signal))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func timeOfDayGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning, Sachin"
        case 12..<17: return "Good afternoon, Sachin"
        case 17..<22: return "Good evening, Sachin"
        default: return "Welcome back, Sachin"
        }
    }

    private func prettyDate(_ dateString: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return dateString }
        let out = DateFormatter()
        out.dateFormat = "EEEE · MMM d"
        return out.string(from: date)
    }
}

// MARK: - Recovery hero

struct BriefingRecoveryHero: View {
    let briefing: Briefing

    private var accent: Color {
        switch briefing.recoveryLevel {
        case .good: return .mint
        case .moderate: return .amber
        case .low: return .ember
        case .unknown: return .fg2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Eyebrow(text: "Recovery")
                Spacer()
                HStack(spacing: 6) {
                    GlowDot(color: accent, size: 5)
                    Text(briefing.recoveryLevel.label.uppercased())
                        .font(.eyebrow)
                        .kerning(1.2)
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(accent.opacity(0.08)))
                .overlay(Capsule().stroke(accent.opacity(0.22), lineWidth: 1))
            }

            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color.line, lineWidth: 6)
                        .frame(width: 86, height: 86)
                    Circle()
                        .trim(from: 0, to: Double(briefing.recoveryScore) / 100)
                        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 86, height: 86)
                        .shadow(color: accent.opacity(0.4), radius: 6)
                    Text("\(briefing.recoveryScore)")
                        .font(.system(size: 28, weight: .light, design: .serif))
                        .foregroundStyle(Color.fg0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(verdict)
                        .font(.uiSmall)
                        .foregroundStyle(Color.fg1)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("HRV \(briefing.hrvDelta) VS BASELINE")
                        .font(.eyebrowSmall)
                        .kerning(1.0)
                        .foregroundStyle(Color.fg2)
                }
                Spacer(minLength: 0)
            }

            Hairline()

            HStack(spacing: 0) {
                metricCell(label: "HRV", value: hrvValue, unit: "ms")
                Rectangle().fill(Color.line).frame(width: 1)
                metricCell(label: "Sleep", value: sleepValue, unit: "hrs")
                Rectangle().fill(Color.line).frame(width: 1)
                metricCell(label: "RHR", value: rhrValue, unit: "bpm")
            }
        }
        .heroCard(accent: accent, padding: 20, cornerRadius: 26)
    }

    private var verdict: String {
        switch briefing.recoveryLevel {
        case .good: return "Systems are go. Today is a day to push."
        case .moderate: return "Partially recovered — train, but manage intensity."
        case .low: return "Recovery is compromised. Keep it light."
        case .unknown: return "No recovery data synced yet."
        }
    }

    private var hrvValue: String {
        guard let hrv = briefing.recovery?.hrv else { return "—" }
        return "\(Int(hrv))"
    }

    private var sleepValue: String {
        guard let s = briefing.recovery?.sleepHours else { return "—" }
        let h = Int(s)
        let m = Int((s - Double(h)) * 60)
        return String(format: "%d:%02d", h, m)
    }

    private var rhrValue: String {
        guard let rhr = briefing.recovery?.restingHr else { return "—" }
        return "\(Int(rhr))"
    }

    private func metricCell(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.numMD)
                    .foregroundStyle(Color.fg0)
                Text(unit)
                    .font(.eyebrow)
                    .foregroundStyle(Color.fg2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

// MARK: - Plan card

struct BriefingPlanCard: View {
    let briefing: Briefing
    let onStart: () -> Void

    private var accent: Color { Color.forSession(briefing.mesocycle.sessionType) }

    private var sessionIcon: String {
        switch briefing.mesocycle.sessionType {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "dumbbell.fill"
        case "Legs": return "figure.strengthtraining.functional"
        case "Cardio+Abs": return "heart.circle.fill"
        case "Yoga": return "figure.mind.and.body"
        default: return "figure.strengthtraining.traditional"
        }
    }

    private var sessionFocus: String {
        switch briefing.mesocycle.sessionType {
        case "Pull": return "BACK · REAR DELTS · BICEPS"
        case "Push": return "CHEST · SHOULDERS · TRICEPS"
        case "Legs": return "QUADS · HAMS · GLUTES"
        case "Cardio+Abs": return "ZONE 2 · CORE"
        case "Yoga": return "MOBILITY · STRETCHING"
        default: return "FULL BODY"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Eyebrow(text: "Today's plan")
                Spacer()
                Text("W\(briefing.mesocycle.week) · D\(briefing.mesocycle.day)")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.ink1.opacity(0.8)))
                    .overlay(Capsule().stroke(Color.line, lineWidth: 1))
            }

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(accent.opacity(0.10))
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(accent.opacity(0.25), lineWidth: 1)
                    Image(systemName: sessionIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                        .shadow(color: accent.opacity(0.5), radius: 6)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(briefing.mesocycle.sessionType)
                        .font(.serifMD)
                        .foregroundStyle(Color.fg0)

                    Text(sessionFocus)
                        .font(.eyebrowSmall)
                        .kerning(1.2)
                        .foregroundStyle(Color.fg2)
                }

                Spacer()
            }

            // Next-up rail
            HStack(spacing: 6) {
                Text("COMING UP")
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.fg3)
                upcomingChip(offset: 1)
                upcomingChip(offset: 2)
                upcomingChip(offset: 3)
                Spacer()
            }
        }
        .darkCard(padding: 18, cornerRadius: 22)
    }

    private func upcomingChip(offset: Int) -> some View {
        let idx = (briefing.mesocycle.day - 1 + offset) % Config.cycleLength
        let type = Config.cycle[idx]
        let color = Color.forSession(type)
        return Text(type.uppercased())
            .font(.eyebrowSmall)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - Coach note card

struct BriefingNoteCard: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CoachAvatar()
                Eyebrow(text: "Coach's note")
                Spacer()
            }

            MarkdownText(content: note)
                .foregroundStyle(Color.fg0.opacity(0.92))
                .font(.system(size: 14))
                .lineSpacing(4)
        }
        .darkCard(padding: 18, cornerRadius: 22)
    }
}

#Preview {
    MorningBriefingView()
}
