// RestTimer.swift
// Vaux
//
// The rest screen as a poster, not a cockpit. One accent color doing one job
// (signal lime = the clock and the act of going), enormous flat numerals,
// hierarchy by type size and hairlines — no cards, no carousel, no glow.
//
// What earned its place and what didn't:
// - The countdown IS the screen. Time is the only honest proxy anyone has for
//   between-set muscle recovery (phosphocreatine resynthesis is invisible to
//   every consumer signal), so the clock stops apologizing for itself.
// - The receipt line under the bar is RestCalibration's finding — this lift's
//   rest requirement measured from the athlete's own logged outcomes. It only
//   renders when the evidence clears the bar; no calibration, no claim.
// - Heart rate is a one-line telltale (current bpm + drop from the post-set
//   peak). The old zone bar answered a cardio question during a strength
//   rest and is gone; zones still make sense mid-cardio, not here.
// - The coach keeps its seat: the note panel and the composer survive
//   unchanged in behavior — rest is the one stretch of a session with time
//   to read, and a question asked here travels the same path as the inline
//   chat below the set list.
// - Time-up flips the whole screen to a lime GO poster, readable from across
//   the gym with the phone flat on a bench. The view holds on GO until the
//   athlete starts the set or buys 30 more seconds; the heart-rate recovery
//   record is still written at the moment the rest actually ended.

import SwiftUI

struct E1RMPoint: Identifiable {
    var date: String
    var value: Double
    var id: String { date }
}

/// A snapshot of the session the timer can render without reaching back into
/// the view model.
struct RestStats {
    var exerciseName: String
    var tonnage: Double
    var setsDone: Int
    var duration: TimeInterval
    var heartRate: HeartRateMonitor?
    var todaySets: [WorkoutSet]
    var lastSets: [WorkoutSet]
    var lastLoaded: Bool
    var strengthHistory: [E1RMPoint]
    var todayE1RM: Double?
}

struct RestTimer: View {
    let totalSeconds: Int
    @Binding var endDate: Date?
    @Binding var isActive: Bool
    let onSkip: () -> Void
    /// Fired when the countdown runs out on screen, as distinct from onSkip.
    /// Both end the rest; only this one means it was actually served, and the
    /// heart-rate recovery recorded for it is only comparable if the rest ran.
    let onFinished: () -> Void
    /// Extending has to go through the view model so the bar's total grows
    /// with the deadline; mutating `endDate` alone left the bar pinned full.
    var onExtend: (Int) -> Void = { _ in }
    /// The set this rest leads into, shown so the countdown doesn't hide
    /// the target it is counting down to.
    var nextSet: String?
    /// The coach's latest feedback. Rest is the only point in a session
    /// with time to actually read it.
    var coachNote: String?
    var isCoachThinking: Bool = false
    /// Composer state, bound to the same view-model fields the inline chat
    /// below the set list uses. Sharing them means a question asked during
    /// rest travels the identical path — and the reply lands in `coachNote`
    /// right above the composer.
    var chatText: Binding<String> = .constant("")
    var onSend: () -> Void = {}
    var stats: RestStats? = nil
    /// Session type for the header eyebrow ("SET 3 OF 3 · PULL").
    var sessionType: String = ""
    /// This lift's measured rest requirement, when the log supports one.
    var calibration: RestCalibration? = nil

    @State private var goState = false
    @State private var showChat = false
    @FocusState private var chatFocused: Bool

    var body: some View {
        Group {
            if goState {
                goView
            } else {
                restingView
            }
        }
        .onAppear {
            // The timer takes the screen over from the set logger, whose
            // weight field may still hold first responder. Resigning
            // app-wide clears whatever is actually focused.
            dismissKeyboard()
        }
        .task(id: endDate) {
            guard let endDate else { return }
            let delay = endDate.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            Haptic.warning()
            // The rest is over NOW, whatever the athlete does next — record
            // the recovery and settle the system surfaces at this moment, so
            // holding on the GO poster can't skew the HRR window or leave a
            // stale notification pending.
            RestNotifier.shared.cancel()
            RestActivityController.shared.complete()
            onFinished()
            withAnimation(Motion.smooth) { goState = true }
        }
    }

    // MARK: - Resting

    private var restingView: some View {
        ZStack {
            Color.ink0.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(
                            left: "REST",
                            right: headerDetail,
                            tint: Color.fg2, detailTint: Color.fg3
                        )

                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            let remaining = remaining(at: context.date)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(timeText(remaining))
                                    .font(.display(chatFocused ? 96 : 190))
                                    .foregroundStyle(Color.signal)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.3)
                                    .padding(.top, chatFocused ? 4 : 10)
                                    .accessibilityLabel("\(spokenRemaining(remaining)) remaining")
                                    .animation(Motion.smooth, value: chatFocused)

                                progressBar(remaining: remaining)
                                    .padding(.top, 14)
                            }
                        }

                        receiptLines
                            .padding(.top, 10)

                        if !chatFocused {
                            hairline.padding(.top, 24)
                            upNextBlock.padding(.top, 20)
                            hairline.padding(.top, 22)
                        }

                        coachPanel
                            .padding(.top, chatFocused ? 12 : 16)

                        Spacer(minLength: 18)

                        if !chatFocused {
                            telltaleRow.padding(.bottom, 10)
                            controlsRow.padding(.bottom, 10)
                        }

                        chatBar
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .animation(Motion.smooth, value: chatFocused)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var headerDetail: String {
        let position = parsedNext.position.uppercased()
        let type = sessionType.uppercased()
        switch (position.isEmpty, type.isEmpty) {
        case (false, false): return "\(position) · \(type)"
        case (false, true): return position
        case (true, false): return type
        case (true, true): return ""
        }
    }

    private func header(left: String, right: String, tint: Color, detailTint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(left)
                .font(.system(size: 11, weight: .semibold))
                .kerning(3)
                .foregroundStyle(tint)
            Spacer()
            Text(right)
                .font(.system(size: 11, weight: .medium))
                .kerning(2)
                .foregroundStyle(detailTint)
        }
    }

    private func progressBar(remaining: Double) -> some View {
        let fraction = totalSeconds > 0
            ? max(0, min(1, remaining / Double(totalSeconds)))
            : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.ink3)
                Rectangle()
                    .fill(Color.signal)
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 1), value: fraction)
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder
    private var receiptLines: some View {
        let total = timeText(Double(totalSeconds))
        VStack(alignment: .leading, spacing: 4) {
            Text(calibration == nil ? "OF \(total)" : "OF \(total) — CALIBRATED TO YOU")
                .font(.system(size: 11, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.fg2)
            if let calibration {
                Text(calibration.receiptLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .kerning(1.2)
                    .foregroundStyle(Color.fg3)
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.line).frame(height: 1)
    }

    // MARK: - Up next

    private var parsedNext: (position: String, exercise: String, load: String, loadIsNumbers: Bool) {
        guard let text = nextSet else { return ("", "", "", false) }
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let exercise = parts.first ?? text
        let detail = parts.count > 1 ? parts[1] : ""
        let split = detail.components(separatedBy: " · ")
        let position = split.count > 1 ? split[0] : ""
        let load = split.count > 1 ? split.dropFirst().joined(separator: " · ") : detail
        // A load line always arrives as "position · numbers"; without the
        // separator the detail is prose (the handoff message while the coach
        // writes the next block) and must not get the display treatment.
        return (position, exercise, load, split.count > 1)
    }

    @ViewBuilder
    private var upNextBlock: some View {
        let next = parsedNext
        if !next.exercise.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(next.position.isEmpty ? "UP NEXT" : "UP NEXT · \(next.position.uppercased())")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(Color.fg2)

                Text(next.exercise.uppercased())
                    .font(.display(42))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)

                if !next.load.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(next.load.uppercased())
                            .font(next.loadIsNumbers ? .display(22) : .system(size: 13))
                            .foregroundStyle(next.loadIsNumbers ? Color.fg0 : Color.fg2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let last = lastTimeLine {
                            Text(last)
                                .font(.system(size: 12, weight: .medium))
                                .kerning(1)
                                .foregroundStyle(Color.fg3)
                        }
                    }
                }
            }
        }
    }

    /// "LAST TIME 40 × 15" from the previous session's top working set —
    /// the number being chased, inline where the target is read.
    private var lastTimeLine: String? {
        guard let stats else { return nil }
        let working = stats.lastSets.filter { $0.isWarmup != true }
        guard let top = working.max(by: {
            ($0.actualWeightKg ?? 0) < ($1.actualWeightKg ?? 0)
        }), let reps = top.actualReps else { return nil }
        let weight = top.actualWeightKg ?? 0
        let load = weight > 0 ? shortWeight(weight) : "BW"
        return "LAST TIME \(load) × \(reps)"
    }

    // MARK: - Coach

    /// Rest is the only stretch of a session with time to read. Capped and
    /// scrollable so a long note can't push the controls off screen.
    @ViewBuilder
    private var coachPanel: some View {
        if isCoachThinking {
            HStack(spacing: 8) {
                ProgressView().tint(Color.fg2).scaleEffect(0.7)
                Text("Coach is writing…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg2)
            }
        } else if let coachNote,
                  !coachNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("COACH")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(Color.fg2)

                ScrollView(showsIndicators: false) {
                    Text(coachNote)
                        .font(.system(size: 15.5))
                        .foregroundStyle(Color.fg1)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Tighter while composing so a long reply can't push the
                // field it is being answered in off the top of the screen.
                .frame(maxHeight: chatFocused ? 96 : 168)
            }
        }
    }

    // MARK: - Telltale + controls

    private var telltaleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(heartLine)
                .font(.system(size: 11, weight: .medium))
                .kerning(1.5)
                .foregroundStyle(Color.fg3)
            Spacer()
            if let stats {
                Text("\(shortTonnage(stats.tonnage)) · \(stats.setsDone) SETS · \(shortDuration(stats.duration))")
                    .font(.system(size: 11, weight: .medium))
                    .kerning(1.5)
                    .foregroundStyle(Color.fg3)
            }
        }
    }

    /// "HEART 117 ▾42": the live reading plus the measured drop from the
    /// post-set peak. Numbers only — no verdict words, because heart rate
    /// cannot testify about muscle recovery and shouldn't pretend to.
    private var heartLine: String {
        guard let monitor = stats?.heartRate,
              let bpm = monitor.currentBPM,
              !monitor.hasStalled() else { return "HEART —" }
        if let drop = monitor.dropFromPeak(inLast: 300), drop > 0 {
            return "HEART \(bpm) ▾\(drop)"
        }
        return "HEART \(bpm)"
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.light()
                onExtend(15)
            } label: {
                Text("+15")
                    .font(.display(19))
                    .foregroundStyle(Color.fg0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink3))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Add 15 seconds")

            Button {
                Haptic.light()
                onSkip()
            } label: {
                Text("SKIP REST")
                    .font(.display(19))
                    .kerning(2)
                    .foregroundStyle(Color.ink0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.fg0))
            }
            .buttonStyle(PressScaleStyle())
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }
    }

    // MARK: - Chat

    @ViewBuilder
    private var chatBar: some View {
        if showChat {
            HStack(spacing: 10) {
                TextField("Ask the coach…", text: chatText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($chatFocused)
                    .lineLimit(1...3)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.fg0)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.ink2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(chatFocused ? Color.signal.opacity(0.35) : Color.line,
                                    lineWidth: 1)
                    )

                Button {
                    Haptic.light()
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Color.signalInk : Color.fg2)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Color.signal : Color.ink3))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message to coach")
            }
        } else {
            Button {
                Haptic.light()
                showChat = true
                chatFocused = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.signal)
                    Text("Ask coach")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.fg2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ink2.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var canSend: Bool {
        !chatText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCoachThinking
    }

    /// Drops the keyboard but keeps the composer open — the reply arrives in
    /// the note panel directly above, and a follow-up is usually one tap away.
    private func send() {
        guard canSend else { return }
        onSend()
        chatFocused = false
    }

    // MARK: - GO

    private var goView: some View {
        ZStack {
            Color.signal.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header(
                    left: "REST OVER",
                    right: parsedNext.position.uppercased(),
                    tint: Color.ink0,
                    detailTint: Color.ink0.opacity(0.55)
                )

                Text("GO")
                    .font(.display(300))
                    .foregroundStyle(Color.ink0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.top, 8)
                    .accessibilityLabel("Rest over. Start your set.")

                Rectangle().fill(Color.ink0).frame(height: 6)
                    .padding(.top, 14)

                Spacer(minLength: 12)

                let next = parsedNext
                if !next.exercise.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(next.position.isEmpty ? "UP NEXT" : next.position.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(3)
                            .foregroundStyle(Color.ink0.opacity(0.55))
                        Text(next.exercise.uppercased())
                            .font(.display(46))
                            .foregroundStyle(Color.ink0)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        if next.loadIsNumbers {
                            Text(next.load.uppercased())
                                .font(.display(24))
                                .foregroundStyle(Color.ink0)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }

                Text(goDetailLine)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(Color.ink0.opacity(0.6))
                    .padding(.top, 16)

                HStack(spacing: 10) {
                    Button {
                        Haptic.light()
                        // The original deadline is in the past; re-anchor it
                        // to now so the extension buys a real 30 seconds
                        // instead of an already-expired one.
                        endDate = Date()
                        onExtend(30)
                        withAnimation(Motion.smooth) { goState = false }
                    } label: {
                        Text("+30")
                            .font(.display(19))
                            .foregroundStyle(Color.ink0)
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.ink0, lineWidth: 2)
                            )
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Rest 30 more seconds")

                    Button {
                        Haptic.light()
                        isActive = false
                    } label: {
                        Text("START SET")
                            .font(.display(19))
                            .kerning(2)
                            .foregroundStyle(Color.signal)
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink0))
                    }
                    .buttonStyle(PressScaleStyle())
                    .layoutPriority(1)
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
    }

    private var goDetailLine: String {
        var parts = ["RESTED \(timeText(Double(totalSeconds)))"]
        if let monitor = stats?.heartRate, let bpm = monitor.currentBPM,
           !monitor.hasStalled() {
            parts.append("HEART \(bpm)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func remaining(at date: Date) -> Double {
        guard let endDate else { return Double(totalSeconds) }
        return max(0, endDate.timeIntervalSince(date))
    }

    private func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func spokenRemaining(_ remaining: Double) -> String {
        let total = max(0, Int(remaining.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        switch (minutes, seconds) {
        case (0, let s):
            return "\(s) second\(s == 1 ? "" : "s")"
        case (let m, 0):
            return "\(m) minute\(m == 1 ? "" : "s")"
        case (let m, let s):
            return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")"
        }
    }

    private func shortWeight(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private func shortTonnage(_ value: Double) -> String {
        value >= 1000
            ? String(format: "%.1fT", value / 1000)
            : "\(Int(value))KG"
    }

    private func shortDuration(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}
