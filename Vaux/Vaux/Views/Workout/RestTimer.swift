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
    @State private var showChat: Bool = false
    @FocusState private var chatFocused: Bool
    /// Rolling BPM trace for this rest, sampled once a second. Local to the
    /// timer and discarded when it closes — it describes one recovery
    /// window, not the session, so nothing outside needs it.
    @State private var hrSamples: [Int] = []

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

                        TimelineView(.animation) { context in
                            let remaining = remaining(at: context.date)
                            ringView(remaining: remaining)
                        }
                        .frame(width: 220, height: 220)
                        .scaleEffect(pulse ? 1.02 : 1.0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
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
        // Keyed on nothing so it runs once for the lifetime of this rest and
        // dies with it. `HeartRateMonitor` publishes whatever HealthKit last
        // delivered rather than a stream we can await, so a 1s poll is the
        // only way to build a trace — cheap, and it stops when the view goes.
        .task {
            while !Task.isCancelled {
                if let bpm = stats?.heartRate?.currentBPM {
                    // Skip duplicate consecutive readings: HealthKit often
                    // repeats the same sample for several seconds, and a flat
                    // run of identical points draws a plateau that didn't
                    // happen.
                    if hrSamples.last != bpm { hrSamples.append(bpm) }
                    if hrSamples.count > 90 { hrSamples.removeFirst(hrSamples.count - 90) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
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
                    .font(.system(size: 56, weight: .light, design: .serif).monospacedDigit())
                    .foregroundStyle(Color.fg0)
                Text(statusText(remaining))
                    .font(.eyebrowSmall)
                    .kerning(1.4)
                    .foregroundStyle(color)
            }
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(points.last?.value ?? 0))kg")
                            .font(.numMD)
                            .foregroundStyle(Color.fg0)
                            .monospacedDigit()
                        Text("est. 1RM")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fg2)
                    }

                    sparkline(points)
                        .frame(height: 52)

                    if let trend = trendLine(points) {
                        Text(trend)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.mint)
                            .lineLimit(1)
                            .allowsTightening(true)
                    }
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
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.signal.opacity(0.28), Color.signal.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Session", i),
                    y: .value("e1RM", point.value)
                )
                .foregroundStyle(Color.signal)
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
                .foregroundStyle(Color.signal)
                .symbolSize(60)

                PointMark(
                    x: .value("Session", last.offset),
                    y: .value("e1RM", last.element.value)
                )
                .foregroundStyle(Color.ink0)
                .symbolSize(18)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
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
    /// Samples once a second into a rolling trace for the length of the rest.
    private func recoveryCard(_ stats: RestStats) -> some View {
        statCard("RECOVERY") {
            if let monitor = stats.heartRate, let bpm = monitor.currentBPM {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(bpm)")
                            .font(.numMD)
                            .foregroundStyle(Color.fg0)
                            .monospacedDigit()
                        Text("BPM")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.fg2)
                        Spacer(minLength: 0)
                        if let drop = hrDrop, drop > 0 {
                            Text("−\(drop) since peak")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.mint)
                        }
                    }

                    hrTrace
                        .frame(height: 46)

                    Text(monitor.zoneLabel(for: bpm))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg2)
                }
            } else {
                Text("No heart-rate signal — needs the Watch on and streaming.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var hrTrace: some View {
        if hrSamples.count < 2 {
            // A single sample is a dot, not a trend; say nothing rather than
            // draw a line implying a trajectory that hasn't been measured.
            Text("Tracking…")
                .font(.system(size: 11))
                .foregroundStyle(Color.fg2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let lo = Double(hrSamples.min() ?? 0)
            let hi = Double(hrSamples.max() ?? 1)
            let pad = max((hi - lo) * 0.2, 2)
            Chart {
                ForEach(Array(hrSamples.enumerated()), id: \.offset) { i, bpm in
                    LineMark(
                        x: .value("Second", i),
                        y: .value("BPM", bpm)
                    )
                    .foregroundStyle(Color.ember)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        }
    }

    private var hrDrop: Int? {
        guard let peak = hrSamples.max(), let now = hrSamples.last else { return nil }
        return peak - now
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
                }
                .disabled(!canSend)
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
