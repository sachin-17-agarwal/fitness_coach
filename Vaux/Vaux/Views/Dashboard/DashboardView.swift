// DashboardView.swift
// Vaux
//
// The home screen as verdict → action → ledger, in the same poster language
// as the rest screen: one hero number whose COLOR is the readiness verdict,
// a consequence line that flows straight into today's session and its single
// loud action, the coach's daily note, and a flat four-column weekly ledger.
//
// What this replaced, and why:
// - A recovery card that stated one verdict four ways (chip, zone label,
//   prose, ring color) and never as a training consequence. The verdict is
//   now the numeral's color plus one line, and it changes what the START
//   control looks like.
// - A card carousel and a "This week" grid that showed sleep and resting HR
//   twice each. Every metric appears exactly once.
// - No coach presence on home. The daily briefing note — already generated
//   and cached each morning — takes the slot under the action.
// - A screen that asked you to START at 9pm with the session already logged.
//   Once today's session is finished it shows the recap, previews tomorrow,
//   and drops the swap control, which is moot.

import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var showWeightSheet = false
    @State private var showBriefing = false
    /// Block review card: proposal numbers tapped for a partial answer, and
    /// whether the numbers behind the proposals are unfolded.
    @State private var selectedProposals: Set<Int> = []
    @State private var showReviewNumbers = false
    @AppStorage(Config.displayNameKey) private var displayName: String = ""

    var switchToChatTab: (() -> Void)? = nil
    /// Starting a session goes to the Train tab, where the workout is the
    /// root of its own stack. Pushing it from here left a live session one
    /// edge-swipe from being popped, and a drag while scrolling the rest
    /// screen dragged the whole page sideways.
    var switchToTrainTab: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ink0.ignoresSafeArea()

                // Three states, not two. A failed load with nothing cached
                // used to fall through to `content`, which rendered a
                // dashboard of em-dashes and zeroes — indistinguishable from a
                // genuinely empty account, and offering no way to try again.
                if viewModel.isLoading && viewModel.recovery == nil {
                    loadingState
                } else if let error = viewModel.errorMessage, viewModel.recovery == nil {
                    LoadErrorState(message: error, isRetrying: viewModel.isLoading) {
                        Task { await viewModel.load() }
                    }
                } else {
                    content
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showWeightSheet) {
                WeightLogSheet(initialWeight: viewModel.latestWeightKg) {
                    Task { await viewModel.load() }
                }
            }
            .sheet(isPresented: $showBriefing) {
                MorningBriefingView(
                    onStartWorkout: { _ in
                        showBriefing = false
                        switchToTrainTab?()
                    },
                    onOpenChat: {
                        showBriefing = false
                        switchToChatTab?()
                    }
                )
            }
            .task { await viewModel.load() }
            .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
                Task { await viewModel.refreshMesocycle() }
            }
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 18) {
            VauxLogo(size: 34, color: .signal)
            Text("SYNCING RECOVERY DATA")
                .font(.eyebrowSmall)
                .kerning(1.6)
                .foregroundStyle(Color.fg2)
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 4)
                    .riseIn()

                // Reaching `content` with an error set means the load failed
                // but earlier data survived, so this is a caveat on what's
                // below rather than a replacement for it.
                if let error = viewModel.errorMessage {
                    LoadErrorBanner(message: error)
                        .padding(.top, 14)
                        .riseIn(delay: 0.03)
                }

                readinessBlock
                    .padding(.top, 22)
                    .riseIn(delay: 0.06)

                if let review = viewModel.blockReview, review.isOpen {
                    blockReviewCard(review)
                        .padding(.top, 22)
                        .riseIn(delay: 0.09)
                } else if let reply = viewModel.blockReviewReply {
                    blockReviewReplyCard(reply)
                        .padding(.top, 22)
                        .riseIn(delay: 0.09)
                }

                hairline.padding(.top, 22)

                todayBlock
                    .padding(.top, 18)
                    .riseIn(delay: 0.12)

                if let note = viewModel.briefingNote,
                   !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    coachBlock(note)
                        .padding(.top, 18)
                        .riseIn(delay: 0.16)
                }

                hairline.padding(.top, 22)

                ledger
                    .padding(.top, 16)
                    .riseIn(delay: 0.2)

                if let digest = viewModel.digest {
                    digestCard(digest)
                        .padding(.top, 22)
                        .riseIn(delay: 0.24)
                }

                // Decisions the coach proposed in chat, waiting for a tap.
                // Under the digest, as designed: passive, never mid-session.
                ForEach(viewModel.decisions) { capture in
                    decisionCard(capture)
                        .padding(.top, 14)
                        .riseIn(delay: 0.26)
                }
                if viewModel.decisions.isEmpty, let reply = viewModel.decisionReply {
                    decisionReplyCard(reply)
                        .padding(.top, 14)
                        .riseIn(delay: 0.26)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .vauxRefreshable { await viewModel.load() }
    }

    // MARK: - Header — editorial masthead

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    VauxLogo(size: 16, color: .fg1)
                    Text("VAUX")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(3)
                        .foregroundStyle(Color.fg1)
                }
                Spacer()
                if viewModel.currentStreak > 0 {
                    streakPill
                }
            }

            // The masthead in the app's own display face, like the session
            // name below it and every tab title. The light serif it used to
            // wear was the one place on Home speaking a different language.
            Text(greeting.uppercased())
                .font(.display(30))
                .kerning(1)
                .foregroundStyle(Color.fg0)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 18)

            Text(formattedDate.uppercased())
                .font(.system(size: 10, weight: .medium))
                .kerning(2.5)
                .foregroundStyle(Color.fg3)
                .padding(.top, 8)
        }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · MMM d"
        return f.string(from: Date())
    }

    private var streakPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.amber)
            Text("\(viewModel.currentStreak)D STREAK")
                .font(.system(size: 10, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.amber)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(Capsule().stroke(Color.amber.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Readiness

    private var level: DashboardViewModel.RecoveryLevel { viewModel.recoveryColor }

    /// The verdict color. Lime is reserved for "go": it is the readiness
    /// number on a green day, the START bar, and nothing else.
    private var stateColor: Color {
        switch level {
        case .green: return .signal
        case .yellow: return .amber
        case .red: return .ember
        case .unknown: return .fg2
        }
    }

    private var readinessBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(level == .unknown ? "—" : "\(viewModel.recoveryScore)")
                        .font(.display(128))
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if level != .unknown {
                        Text("%")
                            .font(.display(30))
                            .foregroundStyle(stateColor.opacity(0.55))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(level == .unknown ? "Readiness unknown" : "Readiness \(viewModel.recoveryScore) percent")

                Spacer(minLength: 12)

                metricsColumn
                    .padding(.bottom, 8)
            }

            Text(verdictText)
                .font(.system(size: 11.5, weight: .semibold))
                .kerning(2.5)
                .foregroundStyle(stateColor)
                .padding(.top, 12)

            historyStrip
                .padding(.top, 16)
        }
    }

    /// HRV · sleep · RHR, each once, beside the score that consumed them.
    /// Deltas are against the 7-day baseline; a delta that is bad news takes
    /// the verdict color so the mixed-signal case (green score, sinking HRV)
    /// is visible instead of hidden.
    private var metricsColumn: some View {
        VStack(alignment: .trailing, spacing: 7) {
            metricLine("HRV", value: viewModel.recovery?.hrv.map { "\(Int($0))" },
                       delta: hrvDelta, badWhenPositive: false)
            metricLine("SLEEP", value: viewModel.recovery?.sleepHours.map({ Self.clock($0) }), delta: nil, badWhenPositive: false)
            metricLine("RHR", value: viewModel.recovery?.restingHr.map { "\(Int($0))" },
                       delta: rhrDelta, badWhenPositive: true)
        }
        .font(.system(size: 10.5, weight: .medium))
        .kerning(1.2)
        .foregroundStyle(Color.fg2)
    }

    private func metricLine(_ label: String, value: String?, delta: Int?, badWhenPositive: Bool) -> Text {
        var text = Text("\(label) \(value ?? "—")")
        if let delta, delta != 0 {
            let isBad = badWhenPositive ? delta > 0 : delta < 0
            let arrow = delta > 0 ? "▴" : "▾"
            let deltaText = Text(" \(arrow)\(abs(delta))")
                .foregroundColor(isBad && level != .green ? stateColor : Color.fg3)
            text = Text("\(text)\(deltaText)")
        }
        return text
    }

    private var hrvDelta: Int? {
        guard let hrv = viewModel.recovery?.hrv, let avg = viewModel.hrvAvg else { return nil }
        return Int((hrv - avg).rounded())
    }

    private var rhrDelta: Int? {
        guard let rhr = viewModel.recovery?.restingHr, let avg = viewModel.rhrAvg else { return nil }
        return Int((rhr - avg).rounded())
    }

    private var verdictText: String {
        let done = viewModel.todayFinishedSession != nil
        let verdict: String
        switch level {
        case .green: verdict = done ? "READY — SESSION DONE" : "READY — PUSH TODAY"
        case .yellow: verdict = done ? "STEADY — SESSION DONE" : "STEADY — TRAIN AS PLANNED"
        case .red: verdict = done ? "RUN DOWN — REST TONIGHT" : "RUN DOWN — GO EASY TODAY"
        case .unknown: return "NO RECOVERY DATA YET"
        }
        // The score is yesterday's until the Health export delivers today's
        // readings; say so rather than pass it off as this morning's.
        if let read = viewModel.recovery?.date, read != RecoveryService.todayString() {
            return verdict + " · READ " + Self.shortDay(read)
        }
        return verdict
    }

    private static func shortDay(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso.uppercased() }
        let out = DateFormatter()
        out.dateFormat = "EEE d"
        return out.string(from: date).uppercased()
    }

    /// 14 flat bars, each tinted by the zone that day landed in, today in the
    /// full verdict color. Trend and verdict history in one glance.
    private var historyStrip: some View {
        let bars = viewModel.historyBars
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    let isToday = index == bars.count - 1
                    Rectangle()
                        .fill(isToday ? stateColor : Self.tint(for: bar.level))
                        .frame(height: max(3, 30 * CGFloat(bar.score) / 100))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30, alignment: .bottom)

            HStack {
                Text("14 DAYS · COLOR = THAT DAY'S ZONE")
                Spacer()
                Text("TODAY")
            }
            .font(.system(size: 9, weight: .medium))
            .kerning(1.5)
            .foregroundStyle(Color.fg3.opacity(0.8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fourteen day readiness history")
    }

    private static func tint(for level: DashboardViewModel.RecoveryLevel) -> Color {
        switch level {
        case .green: return Color.mint.opacity(0.26)
        case .yellow: return Color.amber.opacity(0.34)
        case .red: return Color.ember.opacity(0.38)
        case .unknown: return Color.ink3
        }
    }

    // MARK: - Today

    private var hairline: some View {
        Rectangle().fill(Color.line).frame(height: 1)
    }

    private var isDeload: Bool { viewModel.mesocycle.week == Config.mesocycleWeeks }

    private var todayBlock: some View {
        let meso = viewModel.mesocycle
        let finished = viewModel.todayFinishedSession
        // Once a session is finished the mesocycle has already advanced to
        // the next slot, so the schedule's "today" is tomorrow's session.
        // Name what was actually trained.
        let type = finished?.type ?? meso.todayType

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                mesocycleWave(current: meso.week, accent: finished == nil ? stateColor : Color.line2)
                Text(eyebrowText(meso: meso, finished: finished))
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(Color.fg2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if finished == nil {
                    SessionSwapButton(
                        currentType: type,
                        isOverridden: meso.isOverridden,
                        onChange: { newType in Task { await viewModel.setTodayOverride(newType) } }
                    )
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(type.uppercased())
                    .font(.display(44))
                    .foregroundStyle(finished == nil ? Color.fg0 : Color.fg2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if finished != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.mint)
                }
            }
            .padding(.top, 10)

            Text(finished.map(summaryLine) ?? SessionPlan.preview(for: type))
                .font(.system(size: 10.5, weight: .medium))
                .kerning(1.2)
                .foregroundStyle(Color.fg2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)

            if finished == nil {
                startButton
                    .padding(.top, 14)
            } else {
                tomorrowCard
                    .padding(.top, 14)
            }
        }
    }

    private func eyebrowText(meso: MesocycleState, finished: WorkoutSession?) -> String {
        var week = meso.week
        var day = meso.day
        if let finished {
            // The state has moved on; read the finished session's own stamp,
            // or step back one slot (yoga never consumed one).
            if let w = finished.mesocycleWeek, let d = finished.mesocycleDay {
                week = w; day = d
            } else if !Config.nonSlotSessionTypes.contains(finished.type) {
                if meso.day == 1 {
                    day = Config.cycleLength
                    week = meso.week == 1 ? Config.mesocycleWeeks : meso.week - 1
                } else {
                    day = meso.day - 1
                }
            }
        }
        var parts = ["W\(week)", "D\(day)"]
        if week == Config.mesocycleWeeks { parts.append("DELOAD") }
        if finished != nil { parts.append("DONE") }
        return parts.joined(separator: " · ")
    }

    /// Four segments, one per week of the wave; the current week takes the
    /// verdict color, past weeks dim, future weeks dark. Grey once the day's
    /// session is done — the wave has nothing left to point at today.
    private func mesocycleWave(current: Int, accent: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(1...Config.mesocycleWeeks, id: \.self) { week in
                Rectangle()
                    .fill(week < current ? Color.line2 : (week == current ? accent : Color.ink3))
                    .frame(width: 14, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func summaryLine(_ session: WorkoutSession) -> String {
        var parts: [String] = []
        if let end = session.endTime.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            parts.append("COMPLETED \(f.string(from: end).uppercased())")
        } else {
            parts.append("COMPLETED")
        }
        if let tonnage = session.tonnageKg, tonnage > 0 {
            parts.append(Self.tonnage(tonnage))
        }
        if let start = session.startTime.flatMap({ ISO8601DateFormatter().date(from: $0) }),
           let end = session.endTime.flatMap({ ISO8601DateFormatter().date(from: $0) }),
           end > start {
            let total = Int(end.timeIntervalSince(start))
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        return parts.joined(separator: " · ")
    }

    /// The screen's one loud object. Lime on a green day; on a red day the
    /// same control goes quiet — you can still train, the screen just stops
    /// celebrating it.
    private var startButton: some View {
        let easy = level == .red
        return Button {
            Haptic.medium()
            switchToTrainTab?()
        } label: {
            HStack(spacing: 10) {
                Text(easy ? "START — EASY" : "START SESSION")
                    .font(.display(19))
                    .kerning(2)
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(easy ? Color.fg0 : Color.signalInk)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(easy ? Color.ink3 : Color.signal)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(easy ? Color.line2 : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .accessibilityLabel(easy ? "Start session, take it easy" : "Start session")
    }

    private var tomorrowCard: some View {
        let meso = viewModel.mesocycle
        // Shown only after today's session, when the state already points at
        // the next slot: tomorrow IS the state's current slot (yoga on its
        // day, as ever), not the one after it.
        let nextType = meso.rotationSessionType
        let nextWeek = meso.week
        let nextDay = meso.day
        return VStack(alignment: .leading, spacing: 4) {
            Text("TOMORROW · W\(nextWeek) D\(nextDay)")
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.fg3)
            Text(SessionPlan.shortLine(for: nextType))
                .font(.display(18))
                .kerning(1)
                .foregroundStyle(Color.fg0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    // MARK: - Coach

    private func coachBlock(_ note: String) -> some View {
        let finished = viewModel.todayFinishedSession != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(finished ? "COACH · RECAP" : "COACH")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(Color.fg2)
                Spacer()
                Button {
                    Haptic.light()
                    showBriefing = true
                } label: {
                    Text("BRIEFING →")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(1.5)
                        .foregroundStyle(Color.signal)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open today's briefing")
            }
            .frame(height: 20)

            Text(note)
                .font(.system(size: 14))
                .foregroundStyle(Color.fg1)
                .lineSpacing(4)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Block review

    /// The morning after a block rolls over: the review of the block just
    /// ended, on Home because Home is what gets read. Answered here with the
    /// same words chat accepts, or in chat.
    private func blockReviewCard(_ review: BlockReviewResponse) -> some View {
        let proposals = review.proposals ?? []
        let sections = review.sections ?? []
        let chosen = selectedProposals.filter { $0 <= proposals.count }.sorted()
        return VStack(alignment: .leading, spacing: 0) {
            // Header: what this is, whether it counts, which block.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("BLOCK REVIEW")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(Color.signal)
                if review.dryRun == true {
                    Text("DRY RUN")
                        .font(.system(size: 8, weight: .semibold))
                        .kerning(1.5)
                        .foregroundStyle(Color.fg2)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Color.ink3))
                        .overlay(Capsule().stroke(Color.line2, lineWidth: 1))
                }
                Spacer()
                Text(Self.reviewRange(review))
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(2)
                    .foregroundStyle(Color.fg3)
            }

            // The headline is the ask, not the essay.
            Text(proposals.isEmpty ? "NO CHANGES FOR NEXT BLOCK"
                 : "\(proposals.count) CHANGE\(proposals.count == 1 ? "" : "S") PROPOSED FOR NEXT BLOCK")
                .font(.display(22))
                .foregroundStyle(Color.fg0)
                .padding(.top, 12)
            if proposals.count > 1 {
                Text("Tap a line to answer for that one alone.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg3)
                    .padding(.top, 2)
            }

            // Proposals: numbered rows, each a tap target.
            if !proposals.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(proposals.enumerated()), id: \.offset) { index, proposal in
                        if index > 0 {
                            Rectangle().fill(Color.line).frame(height: 1)
                        }
                        reviewProposalRow(index + 1, proposal, selected: selectedProposals.contains(index + 1))
                    }
                }
                .padding(.top, 10)
            }

            // Answers.
            HStack(spacing: 10) {
                if proposals.isEmpty {
                    reviewAnswerButton("NOTED", text: "no", loud: true)
                } else if chosen.isEmpty {
                    reviewAnswerButton("APPROVE ALL", text: "approve all", loud: true)
                    reviewAnswerButton("NO", text: "no", loud: false)
                } else {
                    reviewAnswerButton("APPROVE \(chosen.map { String($0) }.joined(separator: " & "))",
                                       text: "yes to " + chosen.map { String($0) }.joined(separator: " and "), loud: true)
                    reviewAnswerButton("NO", text: "no", loud: false)
                }
                Spacer()
                Button {
                    Haptic.light()
                    switchToChatTab?()
                } label: {
                    Text("IN CHAT →")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(1.5)
                        .foregroundStyle(Color.signal)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Answer the review in chat")
            }
            .padding(.top, 14)
            .disabled(viewModel.isAnsweringReview)
            .opacity(viewModel.isAnsweringReview ? 0.5 : 1)
            if review.dryRun == true {
                Text("Dry run: your answer is kept to compare, nothing is recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.fg3)
                    .padding(.top, 6)
            }

            // The numbers behind the proposals, folded until asked for.
            if !sections.isEmpty {
                Rectangle().fill(Color.line).frame(height: 1).padding(.top, 14)
                Button {
                    Haptic.light()
                    withAnimation(.easeInOut(duration: 0.2)) { showReviewNumbers.toggle() }
                } label: {
                    HStack {
                        Text(showReviewNumbers ? "HIDE THE NUMBERS" : "READ THE NUMBERS")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(2)
                            .foregroundStyle(Color.fg2)
                        Spacer()
                        Image(systemName: showReviewNumbers ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.fg3)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showReviewNumbers ? "Hide the numbers" : "Read the numbers")
                if showReviewNumbers {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.self) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                if !section.label.isEmpty {
                                    Text(section.label)
                                        .font(.system(size: 9, weight: .semibold))
                                        .kerning(2)
                                        .foregroundStyle(Color.fg3)
                                }
                                Text(section.body)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.fg1)
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.signal.opacity(0.35), lineWidth: 1)
        )
    }

    /// One proposal: its number, what kind and of what, the change, the
    /// reason. Tapping toggles it into a partial answer.
    private func reviewProposalRow(_ number: Int, _ proposal: BlockReviewResponse.Proposal, selected: Bool) -> some View {
        let kind = (proposal.kind ?? "").uppercased()
        let subject = (proposal.subject ?? "").uppercased()
        let eyebrow = [kind, subject].filter { !$0.isEmpty }.joined(separator: " · ")
        let body = (proposal.detail?.isEmpty == false ? proposal.detail : nil) ?? proposal.line
        let rationale = (proposal.rationale ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.display(20))
                .foregroundStyle(selected ? Color.signal : Color.fg3)
                .frame(width: 20, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                if !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(2)
                        .foregroundStyle(selected ? Color.signal : Color.fg3)
                }
                Text(body.prefix(1).uppercased() + String(body.dropFirst()))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.fg0)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.fg2)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(selected ? Color.signal : Color.line2)
                .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.light()
            if selected { selectedProposals.remove(number) } else { selectedProposals.insert(number) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    /// "24 AUG – 19 SEP" from the review's window; the block's start alone
    /// when the end is not known.
    private static func reviewRange(_ review: BlockReviewResponse) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        let out = DateFormatter()
        out.dateFormat = "d MMM"
        out.locale = Locale(identifier: "en_US_POSIX")
        func label(_ iso: String?) -> String? {
            guard let iso, let date = parser.date(from: iso) else { return nil }
            return out.string(from: date).uppercased()
        }
        let since = label(review.window?.since) ?? label(review.blockStart)
        let until = label(review.window?.until)
        switch (since, until) {
        case let (s?, u?): return "\(s) – \(u)"
        case let (s?, nil): return "FROM \(s)"
        default: return ""
        }
    }

    private func reviewAnswerButton(_ label: String, text: String, loud: Bool) -> some View {
        Button {
            Haptic.medium()
            selectedProposals = []
            Task { await viewModel.answerBlockReview(text) }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(loud ? Color.signalInk : Color.fg0)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(loud ? Color.signal : Color.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(loud ? Color.clear : Color.line2, lineWidth: 1)
                )
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .accessibilityLabel("Answer \(text)")
    }

    private func blockReviewReplyCard(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLOCK REVIEW · ANSWERED")
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.fg3)
            Text(reply)
                .font(.system(size: 14))
                .foregroundStyle(Color.fg1)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    // MARK: - Decisions proposed in chat

    /// One proposal the coach made in chat, in plain words, with the two
    /// answers. Record applies it through the same path a chat `Decision:`
    /// line takes; Not now leaves it in the log as declined.
    private func decisionCard(_ capture: DecisionCapture) -> some View {
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
                decisionButton("RECORD", loud: true) {
                    Task { await viewModel.answerDecision(capture, record: true) }
                }
                decisionButton("NOT NOW", loud: false) {
                    Task { await viewModel.answerDecision(capture, record: false) }
                }
                Spacer()
            }
            .disabled(viewModel.isAnsweringDecision)
            .opacity(viewModel.isAnsweringDecision ? 0.5 : 1)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.iris.opacity(0.35), lineWidth: 1)
        )
    }

    private func decisionButton(_ label: String, loud: Bool, action: @escaping () -> Void) -> some View {
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
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(loud ? Color.signal : Color.ink3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(loud ? Color.clear : Color.line2, lineWidth: 1)
                )
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .accessibilityLabel(label.capitalized)
    }

    private func decisionReplyCard(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DECISION")
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.fg3)
            Text(reply)
                .font(.system(size: 14))
                .foregroundStyle(Color.fg1)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    // MARK: - Last week

    /// Monday's read of the week just gone: two or three sentences from the
    /// log, no chart, no model. The Recovery tab has the numbers; this is
    /// the line that changes bedtime.
    private func digestCard(_ digest: RecoveryDigest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST WEEK · \(digest.rangeLabel)")
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.fg3)
            Text(digest.sentences.joined(separator: " "))
                .font(.system(size: 14))
                .foregroundStyle(Color.fg1)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Ledger

    private var ledger: some View {
        HStack(alignment: .top, spacing: 0) {
            ledgerColumn(
                "TONNAGE",
                value: viewModel.weekTonnage > 0 ? Self.tonnage(viewModel.weekTonnage) : "—",
                delta: tonnageDeltaText
            )
            ledgerDivider
            ledgerColumn(
                "SESSIONS",
                value: "\(viewModel.sessionsThisWeek)",
                valueSuffix: "/\(Config.cycle.count)",
                delta: (viewModel.sessionsThisWeek >= viewModel.mesocycle.day) ? ("ON PACE", Color.fg3) : ("BEHIND", Color.amber)
            )
            ledgerDivider
            // The 7-day average, not last night — that is in the recovery
            // block above. Unlabelled, the two read as one number disagreeing.
            ledgerColumn(
                "SLEEP · 7-DAY",
                value: viewModel.sleepAvgHours.map({ Self.clock($0) }) ?? "—",
                delta: sleepDeltaText
            )
            ledgerDivider
            Button {
                Haptic.light()
                showWeightSheet = true
            } label: {
                ledgerColumn(
                    "WEIGHT",
                    value: viewModel.latestWeightKg.map { $0.oneDecimal } ?? "—",
                    delta: weightDeltaText ?? ("TAP TO LOG", Color.signal)
                )
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityHint("Opens the weight log")
        }
    }

    private var ledgerDivider: some View {
        Rectangle().fill(Color.line).frame(width: 1).padding(.horizontal, 12)
    }

    private func ledgerColumn(_ label: String, value: String, valueSuffix: String? = nil,
                              delta: (String, Color)?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .kerning(2)
                .foregroundStyle(Color.fg3)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(.display(24))
                    .foregroundStyle(Color.fg0)
                if let valueSuffix {
                    Text(valueSuffix)
                        .font(.display(18))
                        .foregroundStyle(Color.fg3)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let delta {
                Text(delta.0)
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(delta.1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tonnageDeltaText: (String, Color)? {
        guard let pct = viewModel.tonnageDeltaPct else { return nil }
        let rounded = Int(pct.rounded())
        if rounded == 0 { return ("FLAT WK", Color.fg3) }
        return (rounded > 0 ? "▴ \(rounded)% WK" : "▾ \(abs(rounded))% WK", rounded > 0 ? Color.mint : Color.fg3)
    }

    private var sleepDeltaText: (String, Color)? {
        guard let minutes = viewModel.sleepDeltaMinutes, abs(minutes) >= 5 else { return nil }
        let text = String(format: "%@ %d:%02d VS LAST WK", minutes > 0 ? "▴" : "▾", abs(minutes) / 60, abs(minutes) % 60)
        return (text, minutes > 0 ? Color.mint : Color.amber)
    }

    private var weightDeltaText: (String, Color)? {
        guard let delta = viewModel.weightDeltaKg, abs(delta) >= 0.1 else { return nil }
        return (String(format: "%@ %.1f KG", delta > 0 ? "▴" : "▾", abs(delta)), Color.fg3)
    }

    // MARK: - Formatting

    /// Time-of-day greeting, with the athlete's name when one is set.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 5..<12: salutation = "Good morning"
        case 12..<17: salutation = "Good afternoon"
        case 17..<22: salutation = "Good evening"
        default: salutation = "Welcome back"
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? salutation : "\(salutation), \(name)"
    }

    private static func clock(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int(((hours - Double(h)) * 60).rounded())
        return String(format: "%d:%02d", h, m)
    }

    private static func tonnage(_ kg: Double) -> String {
        kg >= 1000 ? String(format: "%.1fT", kg / 1000) : "\(Int(kg))KG"
    }
}

#Preview {
    DashboardView()
}
