// RestTimer.swift
// Vaux
//
// Full-screen rest countdown ring with skip + add-15s controls.
//
// The countdown is driven by an absolute `endDate`, not a per-second
// integer tick. A `TimelineView(.animation)` re-renders the ring and
// readout from the real elapsed time every frame, so the sweep is smooth
// and the displayed seconds stay locked to wall-clock — even if the run
// loop is briefly busy. Completion fires once from a single `.task` that
// sleeps until the deadline.

import SwiftUI
import Charts

/// One session's best estimated 1RM for an exercise — a point on the
/// strength sparkline. Identified by date so re-renders don't re-diff
/// the whole chart.
struct E1RMPoint: Identifiable {
    var date: String
    var value: Double
    var id: String { date }
}

/// Snapshot of the numbers worth glancing at mid-rest, assembled by
/// WorkoutModeView from the view model. A struct rather than the view model
/// itself so RestTimer stays a dumb view with explicit inputs.
struct RestStats {
    var exerciseName: String
    var tonnage: Double
    var setsDone: Int
    var duration: TimeInterval
    /// The monitor itself rather than a captured Int, for two reasons: it is
    /// @Observable so the session card's BPM stays live, and the recovery
    /// card's sampling task holds the class reference across view re-renders
    /// — a copied value would freeze at whatever it was when the task began.
    var heartRate: HeartRateMonitor?
    /// Sets logged against the current exercise this session.
    var todaySets: [WorkoutSet]
    /// The previous session's sets for the same exercise.
    var lastSets: [WorkoutSet]
    /// Distinguishes "no history" (first time doing this exercise — worth
    /// saying) from "still fetching" (worth a spinner, not a claim).
    var lastLoaded: Bool
    /// Best e1RM per past session for this exercise, oldest first.
    var strengthHistory: [E1RMPoint]
    /// Best e1RM among today's working sets, appended to the sparkline as
    /// its live final point.
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
    /// Extending has to go through the view model so the ring's total grows
    /// with the deadline; mutating `endDate` alone left the ring pinned full.
    var onExtend: (Int) -> Void = { _ in }
    /// The set this rest leads into, shown so the countdown doesn't hide
    /// the target it is counting down to.
    var nextSet: String?
    /// The coach's latest feedback. Rest is the only point in a session
    /// with time to actually read it, and it was previously hidden behind
    /// the full-screen timer.
    var coachNote: String?
    var isCoachThinking: Bool = false
    /// Composer state, bound to the same view-model fields the inline chat
    /// below the set list uses. Sharing them means a question asked during
    /// rest travels the identical path — and the reply lands in `coachNote`
    /// right above the composer.
    var chatText: Binding<String> = .constant("")
    var onSend: () -> Void = {}
    /// Rest is dead time; these cards fill it with the numbers that inform
    /// the next set — last session's performance on this exercise above all.
    var stats: RestStats? = nil

    @State private var pulse: Bool = false
    /// Stable anchor for the heart-rate card's one-second schedule. Deriving
    /// it from `.now` inside the body would re-anchor the schedule on every
    /// re-render instead of leaving it running.
    @State private var tickEpoch = Date()
    @State private var showChat: Bool = false
    @FocusState private var chatFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ring gives up most of its size while composing — with the keyboard
    /// up there isn't room for both, and the thing being looked at is the
    /// coach's reply, not the countdown.
    private var ringScale: CGFloat { chatFocused ? 0.55 : 1.0 }

    var body: some View {
        ZStack {
            Color.ink0.opacity(0.88)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            // GeometryReader + minHeight keeps the old centred layout when
            // everything fits, and only starts scrolling once the keyboard
            // shrinks the container past the content. A bare ScrollView would
            // top-align the ring even with the keyboard down.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        HStack(spacing: 8) {
                            GlowDot(color: .mint, size: 5)
                            Text("REST")
                                .font(.eyebrow)
                                .kerning(2.5)
                                .foregroundStyle(Color.fg2)
                        }

                        // 20 Hz rather than `.animation`'s every-frame redraw.
                        // The sweep covers a 220pt ring over minutes, so at
                        // this rate it still advances sub-pixel per tick and
                        // reads as continuous — while doing a third of the work
                        // of a 60 Hz display and a sixth of a 120 Hz one, for
                        // the whole of every rest period.
                        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                            let remaining = remaining(at: context.date)
                            ringView(remaining: remaining)
                        }
                        .frame(width: 220, height: 220)
                        .scaleEffect(pulse && !reduceMotion ? 1.02 : 1.0)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                            value: pulse
                        )
                        // Scale visually but also give back the layout height,
                        // so the composer and note rise into the freed space
                        // instead of being pushed under the keyboard.
                        .scaleEffect(ringScale)
                        .frame(height: 220 * ringScale)

                        if let nextSet, !chatFocused { upNext(nextSet) }

                        if !chatFocused { controls }

                        if let stats, !chatFocused { statStrip(stats) }

                        coachNotePanel

                        chatBar
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .animation(Motion.smooth, value: chatFocused)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear {
            pulse = true
            // The timer takes the screen over from the set logger, whose
            // weight field may still hold first responder. Its "Done" button
            // only clears that view's own @FocusState, which by then has
            // already been reset — so the button did nothing and the keyboard
            // sat there over the countdown. Resigning app-wide clears whatever
            // is actually focused, regardless of which view owns it.
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
            isActive = false
            // Reaching this line means the app was alive to run the timer out
            // on screen, so the scheduled fallback has nothing left to tell
            // anyone. Clearing it also removes the banner iOS delivered at the
            // same instant while the app was frontmost.
            RestNotifier.shared.cancel()
            // `complete` rather than `cancel`: the island holds "Go" for a few
            // seconds on the way out. When the app was suspended instead this
            // line never runs, and the widget falls back to its staleDate to
            // show the same thing.
            RestActivityController.shared.complete()
            onFinished()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Ring

    private func ringView(remaining: Double) -> some View {
        let color = ringColor(remaining)
        return ZStack {
            // Watch-dial tick marks — majors every 5 ticks
            ForEach(0..<60, id: \.self) { i in
                let isMajor = i % 5 == 0
                Rectangle()
                    .fill(Color.white.opacity(isMajor ? 0.22 : 0.08))
                    .frame(width: 1.5, height: isMajor ? 9 : 5)
                    .offset(y: -88)
                    .rotationEffect(.degrees(Double(i) * 6))
            }

            Circle()
                .stroke(color.opacity(0.18), lineWidth: 10)

            Circle()
                .trim(from: 0, to: progress(remaining))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 14, x: 0, y: 0)

            VStack(spacing: 4) {
                Text(timeString(remaining))
                    .font(.scaled(56, weight: .light, design: .serif, relativeTo: .largeTitle, cap: 76).monospacedDigit())
                    .foregroundStyle(Color.fg0)
                Text(statusText(remaining))
                    .font(.eyebrowSmall)
                    .kerning(1.4)
                    .foregroundStyle(color)
            }
        }
        // Announced as a countdown rather than as two loose strings, and
        // marked as updating so VoiceOver re-reads it as time runs down
        // instead of leaving a stale figure on the last focus.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rest remaining")
        .accessibilityValue(spokenRemaining(remaining))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// "1 minute 30 seconds", rather than the display's "1:30" — which
    /// VoiceOver reads as a ratio.
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

    // MARK: - Up next

    /// Borderless on purpose. The previous version was a full-width bordered
    /// box that carried the same visual weight as the ring and fought it for
    /// attention; here the type hierarchy does the work — a quiet eyebrow for
    /// position, the exercise in the app's serif, and the numbers he actually
    /// acts on rendered large in mono.
    private func upNext(_ text: String) -> some View {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let exercise = parts.first ?? text
        // "Working set 2 of 3 · BW × 10 @ RPE 7" -> position, then the load.
        let detail = parts.count > 1 ? parts[1] : ""
        let split = detail.components(separatedBy: " · ")
        let position = split.count > 1 ? split[0] : ""
        let load = split.count > 1 ? split.dropFirst().joined(separator: " · ") : detail

        return VStack(spacing: 6) {
            Text(position.isEmpty ? "UP NEXT" : "UP NEXT · \(position.uppercased())")
                .font(.eyebrowSmall)
                .kerning(1.6)
                .foregroundStyle(Color.fg2)

            Text(exercise)
                .font(.serifSM)
                .foregroundStyle(Color.fg0)
                .multilineTextAlignment(.center)

            if !load.isEmpty {
                // A load line always arrives as "position · numbers". Without
                // the separator the detail is prose (the handoff message while
                // the coach writes the next block), which must not be rendered
                // in the big mono treatment reserved for weights.
                let isLoad = split.count > 1
                Text(load)
                    .font(isLoad ? .numMD : .system(size: 13))
                    .foregroundStyle(isLoad ? Color.mint : Color.fg2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Coach note

    /// Rest is the only stretch of a session with time to read. Capped and
    /// scrollable so a long note can't push the controls off screen.
    @ViewBuilder
    private var coachNotePanel: some View {
        if isCoachThinking {
            HStack(spacing: 8) {
                ProgressView().tint(Color.fg2).scaleEffect(0.7)
                Text("Coach is writing…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg2)
            }
            .padding(.top, 2)
        } else if let coachNote, !coachNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("COACH")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)

                ScrollView(showsIndicators: false) {
                    Text(coachNote)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.fg0.opacity(0.92))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Tighter while composing so a long reply can't push the
                // field it's being answered in off the top of the screen.
                .frame(maxHeight: chatFocused ? 96 : 150)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.ink2.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.line, lineWidth: 1)
            )
            .padding(.horizontal, 22)
        }
    }

    // MARK: - Stat cards

    /// Sideways-scrolling cards, one insight each, snapping a card at a time.
    /// The 0.78 width leaves a peek of the next card so the scrollability is
    /// visible without a page-dot row.
    private func statStrip(_ stats: RestStats) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if !stats.exerciseName.isEmpty {
                    lastTimeCard(stats)
                    strengthCard(stats)
                    todayCard(stats)
                }
                recoveryCard(stats)
                sessionCard(stats)
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 22, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }

    private func statCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.eyebrowSmall)
                .kerning(1.4)
                .foregroundStyle(Color.fg2)
                .lineLimit(1)
                .allowsTightening(true)

            content()

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(height: 148, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ink2.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
        .containerRelativeFrame(.horizontal) { length, _ in length * 0.78 }
    }

    /// What this exercise looked like last session — the number the athlete
    /// is actually trying to beat, previously only available by leaving the
    /// timer and digging through History mid-rest.
    private func lastTimeCard(_ stats: RestStats) -> some View {
        statCard("LAST TIME · \(stats.exerciseName.uppercased())") {
            let rows = workingOnly(stats.lastSets)
            if !stats.lastLoaded {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.fg2).scaleEffect(0.7)
                    Text("Checking history…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.fg2)
                }
            } else if rows.isEmpty {
                Text("First session — today sets the baseline.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                setRows(rows, exercise: stats.exerciseName)
                if let delta = deltaLine(stats) {
                    Text(delta)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mint)
                        .lineLimit(1)
                        .allowsTightening(true)
                }
            }
        }
    }

    private func todayCard(_ stats: RestStats) -> some View {
        let rows = workingOnly(stats.todaySets)
        return statCard("TODAY · \(stats.exerciseName.uppercased())") {
            if rows.isEmpty {
                Text("Working sets land here as you log them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                setRows(rows, exercise: stats.exerciseName)
            }
        }
    }

    // MARK: - Strength sparkline

    /// Estimated 1RM per session for the current lift, with today appended
    /// live as the final point. Change-over-time, one series — so a line, no
    /// legend (the title names it), and only the endpoint labelled rather
    /// than a number on every point.
    private func strengthCard(_ stats: RestStats) -> some View {
        let points = sparklinePoints(stats)
        return statCard("STRENGTH · \(stats.exerciseName.uppercased())") {
            if points.count < 2 {
                Text("Two sessions needed before a trend means anything.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Trend sits on the headline row, not under the plot. It
                    // used to follow the chart, where the area fill rose
                    // behind it and the text became unreadable against it.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(points.last?.value ?? 0))kg")
                            .font(.numMD)
                            .foregroundStyle(Color.fg0)
                            .monospacedDigit()
                        Text("est. 1RM")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fg2)
                    }

                    if let trend = trendLine(points) {
                        Text(trend)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.mint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    sparkline(points)
                        .frame(height: 44)
                        // Keeps the stroke off the card's rounded edge; a line
                        // running flush to the corner read as a rendering bug.
                        .padding(.top, 2)
                }
            }
        }
    }

    /// History plus today's best, so the athlete watches the point they are
    /// currently creating land on the curve.
    private func sparklinePoints(_ stats: RestStats) -> [E1RMPoint] {
        var points = stats.strengthHistory
        if let today = stats.todayE1RM, today > 0 {
            points.append(E1RMPoint(date: "today", value: today))
        }
        return points
    }

    private func sparkline(_ points: [E1RMPoint]) -> some View {
        // Indexed rather than date-scaled: sessions are what matter here, and
        // an unevenly spaced x-axis would make a missed week read as a slump.
        let indexed = Array(points.enumerated())
        let values = points.map(\.value)
        let lo = (values.min() ?? 0)
        let hi = (values.max() ?? 1)
        // Pad the domain so a flat series doesn't collapse to a zero-height
        // band and a rising one doesn't touch the card edges.
        let pad = max((hi - lo) * 0.18, 1.5)

        return Chart {
            ForEach(indexed, id: \.offset) { i, point in
                AreaMark(
                    x: .value("Session", i),
                    y: .value("e1RM", point.value)
                )
                // Mint, not signal. `signal` is #CFFF3E — at any fill opacity
                // over the dark card it renders as a solid olive slab rather
                // than a recessive wash, and the plot is only ~44pt tall so
                // the gradient has almost no distance to fade over. Mint is
                // also the ring colour on this screen, so the card reads as
                // part of it. Opacity is halved for the same reason: the fill
                // is context for the line, not a second mark competing with it.
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.mint.opacity(0.16), Color.mint.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Session", i),
                    y: .value("e1RM", point.value)
                )
                .foregroundStyle(Color.mint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
            }

            // Endpoint only — a marker on every session would clutter a
            // 52pt-tall plot, and the last point is the one being acted on.
            if let last = indexed.last {
                PointMark(
                    x: .value("Session", last.offset),
                    y: .value("e1RM", last.element.value)
                )
                .foregroundStyle(Color.mint)
                .symbolSize(54)

                PointMark(
                    x: .value("Session", last.offset),
                    y: .value("e1RM", last.element.value)
                )
                .foregroundStyle(Color.ink2)
                .symbolSize(16)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        // Without an explicit inset Charts runs the plot to the frame edge,
        // so the endpoint marker was half-clipped by the card's rounded corner.
        .chartPlotStyle { plot in
            plot.padding(.vertical, 6)
        }
    }

    private func trendLine(_ points: [E1RMPoint]) -> String? {
        guard let first = points.first?.value, let last = points.last?.value,
              first > 0, points.count >= 2 else { return nil }
        let delta = last - first
        guard abs(delta) >= 0.5 else { return "Holding steady across \(points.count) sessions" }
        let pct = delta / first * 100
        let arrow = delta > 0 ? "↑" : "↓"
        return "\(arrow) \(abs(delta).wholeOrOne)kg (\(abs(pct).wholeOrOne)%) over \(points.count) sessions"
    }

    // MARK: - Recovery

    /// Heart rate falling in real time is the one number that is genuinely
    /// *happening* during rest — everything else on this screen is static.
    /// Which makes it the one number that must never pretend: a value the
    /// Watch recorded eight minutes ago is not the current heart rate, and
    /// this card used to present the two identically.
    private func recoveryCard(_ stats: RestStats) -> some View {
        statCard("HEART RATE") {
            if let monitor = stats.heartRate, let bpm = monitor.currentBPM {
                // Ticks so the age of the reading stays honest while the
                // card sits on screen. The ring's TimelineView doesn't
                // extend down here, and nothing else re-renders per second.
                TimelineView(.periodic(from: tickEpoch, by: 1)) { context in
                    let lagging = monitor.isLagging(at: context.date)
                    let stalled = monitor.hasStalled(at: context.date)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(bpm)")
                                .font(.numMD)
                                .foregroundStyle(lagging ? Color.fg2 : Color.fg0)
                                .monospacedDigit()
                            Text("BPM")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.fg2)
                            Spacer(minLength: 0)
                            // A training zone is a claim about right now. On
                            // a stalled feed that claim is unsupported, so
                            // report the age of the reading instead.
                            // Behind-real-time is normal on a batching bridge, so
                            // the age reads as neutral information. Only a feed
                            // that has actually stopped gets the alarm colour.
                            Text(lagging ? ageLabel(monitor, now: context.date)
                                         : monitor.zoneLabel(for: bpm))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(stalled ? Color.ember : Color.fg2)
                        }

                        hrTrace(monitor, now: context.date)
                            .frame(height: 44)
                            .padding(.top, 2)

                        hrFootnote(monitor, now: context.date,
                                   lagging: lagging, stalled: stalled)
                    }
                }
            } else {
                Text("No heart-rate signal — needs the Watch on and streaming.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ageLabel(_ monitor: HeartRateMonitor, now: Date) -> String {
        guard let age = monitor.sampleAge(at: now) else { return "no signal" }
        if age < 90 { return "\(Int(age))s ago" }
        return "\(Int(age / 60))m ago"
    }

    /// What the athlete is actually asking during a rest: is it coming down.
    ///
    /// The previous version answered a different question — "290 samples ·
    /// last 1s ago" is instrumentation, written while the feed was broken and
    /// the only thing worth knowing was whether data was arriving at all. It
    /// stopped earning its place the moment the feed was fixed.
    ///
    /// The diagnostics are not deleted, only demoted: they still say exactly
    /// what they used to, but now only when the feed is behind or stopped,
    /// which is when the distinction between a delivery problem and a heart
    /// problem matters. A healthy feed spends that line on recovery instead.
    @ViewBuilder
    private func hrFootnote(_ monitor: HeartRateMonitor, now: Date,
                            lagging: Bool, stalled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if lagging || stalled {
                if let lo = monitor.minBPM, let hi = monitor.maxBPM {
                    Text(hi > lo
                         ? "Session \(lo)–\(hi) bpm · \(rateSummary(monitor, now: now))"
                         : "Session flat at \(lo) bpm · \(rateSummary(monitor, now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg2)
                }
            } else {
                recoveryLine(monitor, now: now)
            }
            if stalled {
                // No instruction to start a Watch workout: this fires while one
                // is running, and telling the athlete to do what he has already
                // done is how the card lost its credibility the first time.
                Text("No new readings for a few minutes — the Watch has stopped sending.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sample count, plus how long since the last batch landed.
    ///
    /// Deliberately NOT a session-average cadence. That average was the same
    /// mistake in a new place: 112 samples over seventeen minutes reads as
    /// "one every 9s" and looks perfectly healthy, while in fact every one of
    /// them arrived in the first six minutes and nothing has come since. Time
    /// since the last delivery cannot be flattered that way.
    private func rateSummary(_ monitor: HeartRateMonitor, now: Date) -> String {
        let count = "\(monitor.sampleCount) samples"
        guard let gap = monitor.deliveryAge(at: now) else { return count }
        if gap < 90 { return "\(count) · last \(Int(gap))s ago" }
        return "\(count) · last \(Int(gap / 60))m ago"
    }

    /// Window the trace and the recovery figure both read from.
    ///
    /// Three minutes holds the working set's peak and the descent after it, so
    /// the line reads as a recovery curve. The whole session was the wrong
    /// window: thirty minutes of climbs and falls compressed into one card is
    /// a texture, not a signal, and it told the athlete nothing he could act on.
    private static let hrWindow: TimeInterval = 180

    /// How far the heart rate has fallen from the peak of the last set.
    ///
    /// This is the number that answers "am I ready for the next set" — the
    /// same quantity as clinical heart-rate recovery, which is one of the
    /// better-validated fitness markers there is. A rate that is not falling
    /// is worth saying out loud rather than leaving as an absence.
    @ViewBuilder
    private func recoveryLine(_ monitor: HeartRateMonitor, now: Date) -> some View {
        if let peak = monitor.peak(inLast: Self.hrWindow, at: now),
           let drop = monitor.dropFromPeak(inLast: Self.hrWindow, at: now) {
            // Two states, not three. The peak is the maximum of the same
            // window the current reading sits in, so the drop cannot come out
            // negative — a "still climbing" branch would never have run.
            // Being within a few bpm of the peak IS still climbing, and says
            // so without pretending to measure a rise it cannot see.
            if drop >= 3 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rateText(monitor, drop: drop, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg2)
                    // The comparison is the point. A raw drop answers nothing
                    // on its own — 35 bpm is good or bad depending entirely on
                    // how long it took and what this athlete usually does. Held
                    // back until two rests are on record, because "faster than
                    // usual" against a sample of one is noise wearing a verdict.
                    if let verdict = recoveryVerdict(monitor, drop: drop, now: now) {
                        Text(verdict.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(verdict.tint)
                    }
                }
            } else {
                Text("At \(peak) — hasn't started dropping")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.amber)
            }
        }
    }

    /// "−35 bpm · 34/min". Kept terse because this card sits in a horizontal
    /// strip and the previous wording was already being clipped.
    private func rateText(_ monitor: HeartRateMonitor, drop: Int, now: Date) -> String {
        guard let elapsed = monitor.secondsSincePeak(inLast: Self.hrWindow, at: now),
              elapsed >= 10 else {
            return "−\(drop) bpm"
        }
        let perMinute = Int((Double(drop) * 60 / elapsed).rounded())
        return "−\(drop) bpm · \(perMinute)/min"
    }

    /// Compares this rest against the session's own median rate.
    ///
    /// Deliberately not compared to a population norm or a clinical HRR band.
    /// Those describe resting-state autonomic function measured under
    /// controlled conditions, not a lifter between sets with a phone in one
    /// hand — the only honest reference point is what this athlete has been
    /// doing for the last hour. A rate falling away across a session is the
    /// signal worth having: it is what accumulating fatigue looks like.
    private func recoveryVerdict(
        _ monitor: HeartRateMonitor, drop: Int, now: Date
    ) -> (text: String, tint: Color)? {
        guard let typical = monitor.typicalRecoveryRate,
              let elapsed = monitor.secondsSincePeak(inLast: Self.hrWindow, at: now),
              elapsed >= 20, typical > 0 else { return nil }
        let rate = Double(drop) * 60 / elapsed
        // A 15% band either side. Tighter than that and the label flickers
        // between rests for no reason the athlete can act on.
        if rate > typical * 1.15 { return ("recovering faster than usual", .mint) }
        if rate < typical * 0.85 { return ("slower than usual — fatigue building", .amber) }
        return ("in line with today", .fg2)
    }

    @ViewBuilder
    private func hrTrace(_ monitor: HeartRateMonitor, now: Date) -> some View {
        let window = monitor.samples(inLast: Self.hrWindow, at: now)
        // Falls back to the raw trace early in a session, when three minutes
        // has not happened yet and windowing would leave nothing to draw.
        let samples = window.count >= 3 ? window.map(\.bpm) : monitor.trace
        if samples.count < 3 {
            // Under three real deliveries there is no shape to show. Says so
            // plainly instead of drawing a flat line, which read as a broken
            // chart rather than as missing data.
            Text("Building trace — the Watch delivers a sample every few seconds.")
                .font(.system(size: 11))
                .foregroundStyle(Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let lo = Double(samples.min() ?? 0)
            let hi = Double(samples.max() ?? 1)
            // Enforce a floor on the visible span. Scaling the axis to the
            // data range meant a 2 bpm drift was stretched to fill the card,
            // drawing a dramatic wave over a feed that had barely moved — the
            // chart looked alive precisely when the data was stuck. Against a
            // fixed 30 bpm window a flat trace reads flat, and a real climb
            // through a working set still has somewhere to go.
            let mid = (lo + hi) / 2
            let half = max((hi - lo) / 2 * 1.2, 15)
            let peakIndex = samples.firstIndex(of: Int(hi)) ?? 0
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { i, bpm in
                    // The fill is what makes a descent read as a descent at
                    // this size. A bare 2pt line over 44pt of card is legible
                    // as a squiggle and not much else.
                    AreaMark(
                        x: .value("Sample", i),
                        y: .value("BPM", bpm)
                    )
                    .foregroundStyle(.linearGradient(
                        colors: [Color.ember.opacity(0.30), Color.ember.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Sample", i),
                        y: .value("BPM", bpm)
                    )
                    .foregroundStyle(Color.ember)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }

                // The two points the athlete is comparing: what the set cost
                // him, and where he is now. Marking them turns the curve into
                // a statement about recovery rather than a decorative line.
                PointMark(
                    x: .value("Sample", peakIndex),
                    y: .value("BPM", samples[peakIndex])
                )
                .foregroundStyle(Color.fg2)
                .symbolSize(26)

                if let current = samples.last {
                    PointMark(
                        x: .value("Sample", samples.count - 1),
                        y: .value("BPM", current)
                    )
                    .foregroundStyle(Color.ember)
                    .symbolSize(64)
                }
            }
            .chartYScale(domain: (mid - half)...(mid + half))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.padding(.vertical, 6)
            }
        }
    }

    /// The live-stats bar exists at the top of the workout screen, but this
    /// overlay covers it — so during rest, the session totals were invisible.
    private func sessionCard(_ stats: RestStats) -> some View {
        statCard("SESSION") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    sessionCell(value: formatTonnage(stats.tonnage), label: "TONNAGE")
                    sessionCell(value: "\(stats.setsDone)", label: "SETS")
                }
                HStack(spacing: 8) {
                    sessionCell(value: formatDuration(stats.duration), label: "TIME")
                    sessionCell(value: stats.heartRate?.currentBPM.map { "\($0)" } ?? "—", label: "BPM")
                }
            }
        }
    }

    private func sessionCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.numMD)
                .foregroundStyle(Color.fg0)
                .monospacedDigit()
            Text(label)
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workingOnly(_ rows: [WorkoutSet]) -> [WorkoutSet] {
        rows.filter { $0.isWarmup != true }
    }

    private func setRows(_ rows: [WorkoutSet], exercise: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.prefix(4)) { row in
                HStack(spacing: 6) {
                    Text("\(ExerciseCatalog.setWeightLabel(row.actualWeightKg ?? 0, exercise: exercise)) × \(row.actualReps ?? 0)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.fg0)
                    if let rpe = row.actualRpe {
                        Text("@\(rpe.wholeOrOne)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fg2)
                    }
                }
            }
            if rows.count > 4 {
                Text("+\(rows.count - 4) more")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.fg2)
            }
        }
    }

    /// Positive-or-silent by design: on a deload the top set is BELOW last
    /// time on purpose, and a red "−17kg" mid-rest would read as a scolding
    /// for correct execution. The rows themselves carry the comparison.
    private func deltaLine(_ stats: RestStats) -> String? {
        let today = workingOnly(stats.todaySets)
        let last = workingOnly(stats.lastSets)
        guard
            let t = today.max(by: { ($0.actualWeightKg ?? 0) < ($1.actualWeightKg ?? 0) }),
            let l = last.max(by: { ($0.actualWeightKg ?? 0) < ($1.actualWeightKg ?? 0) })
        else { return nil }
        let tw = t.actualWeightKg ?? 0
        let lw = l.actualWeightKg ?? 0
        if tw > lw {
            return "Top set +\((tw - lw).wholeOrOne)kg vs last time"
        }
        if tw == lw, let tr = t.actualReps, let lr = l.actualReps {
            if tr > lr {
                return "+\(tr - lr) rep\(tr - lr == 1 ? "" : "s") at \(ExerciseCatalog.setWeightLabel(tw, exercise: stats.exerciseName))"
            }
            if tr == lr { return "Matched last time's top set" }
        }
        return nil
    }

    private func formatTonnage(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1ft", value / 1000) : "\(Int(value))kg"
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }

    // MARK: - Composer

    /// Asking something mid-rest previously meant skipping the timer to reach
    /// the inline chat underneath. Collapsed to a single row so it costs no
    /// attention until it's wanted.
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
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.ink2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            .padding(.horizontal, 22)
        } else {
            Button {
                Haptic.light()
                showChat = true
                chatFocused = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Ask coach")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.fg1)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.ink3))
                .overlay(Capsule().stroke(Color.line2, lineWidth: 1))
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

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.light()
                onExtend(15)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("+15s")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.fg0)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.ink3))
                .overlay(Capsule().stroke(Color.line2, lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())

            Button {
                Haptic.medium()
                onSkip()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "forward.fill")
                    Text("Skip")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.signalInk)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.signal))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    // MARK: - Derived values

    private func remaining(at date: Date) -> Double {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    private func progress(_ remaining: Double) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, remaining / Double(totalSeconds)))
    }

    private func ringColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return .ember }
        if remaining <= 30 { return .amber }
        return .mint
    }

    private func statusText(_ remaining: Double) -> String {
        if remaining <= 10 { return "ALMOST" }
        if remaining <= 30 { return "GET READY" }
        return "RECOVER"
    }

    private func timeString(_ remaining: Double) -> String {
        // Round up so the readout shows "1:00" for the final whole second
        // rather than flicking to "0:00" while time is still left.
        let secs = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
