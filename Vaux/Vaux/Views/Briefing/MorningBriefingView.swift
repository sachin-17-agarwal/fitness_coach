// MorningBriefingView.swift
// Vaux
//
// Full-screen morning briefing. Shows a greeting, a recovery hero card,
// today's session plan, and a coach-generated note.

import SwiftUI

struct MorningBriefingView: View {
    @State private var viewModel = BriefingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onStartWorkout: ((String) -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.background.ignoresSafeArea()
                ambientBackground

                if viewModel.isLoading && viewModel.briefing == nil {
                    ProgressView()
                        .tint(.recoveryGreen)
                        .scaleEffect(1.2)
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
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.textSecondary)
                            .padding(8)
                            .background(Circle().fill(Color.surface))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptic.selection()
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.textSecondary)
                            .padding(8)
                            .background(Circle().fill(Color.surface))
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

    // MARK: - Ambient background (subtle gradient glow)

    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.accentPurple.opacity(0.18))
                    .frame(width: 320, height: 320)
                    .blur(radius: 80)
                    .offset(x: -geo.size.width * 0.4, y: -geo.size.height * 0.3)

                Circle()
                    .fill(Color.accentTeal.opacity(0.14))
                    .frame(width: 360, height: 360)
                    .blur(radius: 100)
                    .offset(x: geo.size.width * 0.4, y: -geo.size.height * 0.1)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ b: Briefing) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                greeting(b)
                BriefingRecoveryHero(briefing: b)
                BriefingPlanCard(briefing: b) {
                    Haptic.medium()
                    viewModel.markShown()
                    dismiss()
                    onStartWorkout?(b.mesocycle.sessionType)
                }
                BriefingNoteCard(note: b.coachNote)
                actionRow(b)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    // MARK: - Greeting

    private func greeting(_ b: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(timeOfDayGreeting())
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.textSecondary)

            Text("Morning briefing")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Text(prettyDate(b.date))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textTertiary)
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
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Start \(b.mesocycle.sessionType) workout")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Gradients.recovery)
                )
                .shadow(color: Color.recoveryGreen.opacity(0.35), radius: 18, x: 0, y: 10)
            }

            Button {
                Haptic.light()
                viewModel.markShown()
                dismiss()
                onOpenChat?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Chat with coach")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.cardBorder, lineWidth: 1)
                )
            }
        }
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.recoveryYellow)
            Text("Couldn't load briefing")
                .font(.headline)
                .foregroundStyle(.white)
            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button("Retry") {
                Task { await viewModel.load() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.recoveryGreen))
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func timeOfDayGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Welcome back"
        }
    }

    private func prettyDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateString }
        let months = ["", "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        guard month >= 1, month <= 12 else { return dateString }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let date = f.date(from: dateString) {
            let wd = DateFormatter()
            wd.dateFormat = "EEEE"
            return "\(wd.string(from: date)), \(months[month]) \(day)"
        }
        return "\(months[month]) \(day)"
    }
}

// MARK: - Recovery hero

struct BriefingRecoveryHero: View {
    let briefing: Briefing

    private var accent: Color {
        switch briefing.recoveryLevel {
        case .good: return .recoveryGreen
        case .moderate: return .recoveryYellow
        case .low: return .recoveryRed
        case .unknown: return .textSecondary
        }
    }

    private var gradient: LinearGradient {
        Gradients.forRecovery(briefing.recoveryScore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECOVERY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .kerning(1.2)
                        .foregroundStyle(Color.textSecondary)
                    Text(briefing.recoveryLevel.label)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(accent.opacity(0.18), lineWidth: 6)
                        .frame(width: 78, height: 78)
                    Circle()
                        .trim(from: 0, to: Double(briefing.recoveryScore) / 100)
                        .stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 78, height: 78)
                    Text("\(briefing.recoveryScore)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 10) {
                metricPill(icon: "waveform.path.ecg", label: "HRV", value: hrvValue, delta: briefing.hrvDelta)
                metricPill(icon: "moon.fill", label: "Sleep", value: sleepValue, delta: nil)
                metricPill(icon: "heart.fill", label: "RHR", value: rhrValue, delta: nil)
            }
        }
        .heroCard(accent: accent)
    }

    private var hrvValue: String {
        guard let hrv = briefing.recovery?.hrv else { return "—" }
        return "\(Int(hrv))"
    }

    private var sleepValue: String {
        guard let s = briefing.recovery?.sleepHours else { return "—" }
        return String(format: "%.1fh", s)
    }

    private var rhrValue: String {
        guard let rhr = briefing.recovery?.restingHr else { return "—" }
        return "\(Int(rhr))"
    }

    private func metricPill(icon: String, label: String, value: String, delta: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .kerning(0.5)
            }
            .foregroundStyle(Color.textSecondary)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if let delta {
                Text(delta)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
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
        case "Pull": return "Back, rear delts, biceps"
        case "Push": return "Chest, shoulders, triceps"
        case "Legs": return "Quads, hamstrings, glutes"
        case "Cardio+Abs": return "Zone 2 cardio + core"
        case "Yoga": return "Mobility, stretching, recovery"
        default: return "Full body"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TODAY'S PLAN")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text("Week \(briefing.mesocycle.week) · Day \(briefing.mesocycle.day)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
            }

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Gradients.forSession(briefing.mesocycle.sessionType))
                        .frame(width: 64, height: 64)

                    Image(systemName: sessionIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: accent.opacity(0.4), radius: 14, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(briefing.mesocycle.sessionType)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(sessionFocus)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()
            }

            // Next-up pill rail
            HStack(spacing: 6) {
                Text("COMING UP")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(Color.textTertiary)
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
        return Text(type)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Coach note card

struct BriefingNoteCard: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Gradients.cool)
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text("Coach's note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }

            MarkdownText(content: note)
                .foregroundStyle(Color.white.opacity(0.92))
                .font(.system(size: 15, design: .rounded))
                .lineSpacing(4)
        }
        .darkCard(padding: 18, cornerRadius: 22)
    }
}

#Preview {
    MorningBriefingView()
}
