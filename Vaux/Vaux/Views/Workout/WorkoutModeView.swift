// WorkoutModeView.swift
// Vaux

import SwiftUI

struct WorkoutModeView: View {
    @State private var viewModel = WorkoutViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var resolvedSessionType: String = ""
    @State private var didResolveType = false
    /// Set to false while the view is probing Supabase for an in-progress
    /// session on appearance. Shown as a brief loading state so an
    /// accidental back-swipe doesn't flash the "Begin session" screen
    /// before the resume kicks in — that flash made it look like the
    /// workout had been thrown away when it was still on disk.
    @State private var didCheckResume = false
    /// The logged set currently open for correction, if any.
    @State private var editingSet: WorkoutSet?
    /// Whether this view currently owns a screen wake-lock hold.
    @State private var holdsWakeLock = false

    /// Session type passed explicitly (e.g. from the Dashboard CTA). When left
    /// empty — the Train tab mounts this view with no argument — the view
    /// resolves today's type from `MesocycleService` so the tab matches the
    /// Dashboard instead of showing an empty "Full body" placeholder.
    var sessionType: String = ""
    /// "Open in Coach" from the mid-workout sheet.
    var switchToChatTab: (() -> Void)? = nil

    /// Whether today's session is a manual choice rather than the schedule's.
    @State private var isOverridden = false
    /// The calendar day the session type was last resolved for. A swap made on
    /// Saturday used to live on in this view's state into Sunday if the app
    /// was never relaunched, so the tab said CHANGED · CARDIO+ABS on a day
    /// whose stored override had already expired. The type is re-read when
    /// the day changes, not only once per view lifetime.
    @State private var resolvedOn: String = ""
    @State private var blockWeek: Int?
    @State private var blockDay: Int?
    @State private var lastSameSession: WorkoutSession?
    @State private var sessionsThisWeek = 0

    private var effectiveSessionType: String {
        if isOverridden, !resolvedSessionType.isEmpty { return resolvedSessionType }
        return sessionType.isEmpty ? resolvedSessionType : sessionType
    }

    /// Persists a swap (or clears it) and re-reads the state, so what shows
    /// here is what was stored rather than what was asked for.
    /// Today's session type, week and override, read fresh from the state.
    private func resolveToday() async {
        guard let state = try? await MesocycleService().loadState() else { return }
        isOverridden = state.isOverridden
        blockWeek = state.week
        blockDay = state.day
        if sessionType.isEmpty || state.isOverridden {
            resolvedSessionType = state.todayType
        }
        resolvedOn = Config.isoDay()
    }

    private func changeTodaySession(_ type: String?) {
        Task {
            let service = MesocycleService()
            try? await service.setTodayOverride(type)
            guard let state = try? await service.loadState() else { return }
            // The swap outranks a type the Dashboard navigated in with: picking
            // a strength day from the cardio page has to land on the Begin
            // screen in the same tap.
            resolvedSessionType = state.todayType
            isOverridden = state.isOverridden
            blockWeek = state.week
            blockDay = state.day
            resolvedOn = Config.isoDay()
        }
    }

    private var isNonStrengthDay: Bool {
        effectiveSessionType == "Cardio+Abs" || effectiveSessionType == "Yoga"
    }

    var body: some View {
        ZStack {
            TechBackground(accent: Color.forSession(effectiveSessionType.isEmpty ? "Session" : effectiveSessionType))

            if effectiveSessionType == Config.restSessionType && !viewModel.isActive && !viewModel.showSummary {
                restDayView
            } else if isNonStrengthDay && !viewModel.isActive && !viewModel.showSummary {
                CardioYogaLogView(
                    sessionType: effectiveSessionType,
                    blockLine: blockLine,
                    onStartStrengthSession: effectiveSessionType == "Cardio+Abs"
                        ? { Task { await viewModel.startOrResumeWorkout(type: effectiveSessionType) } }
                        : nil,
                    isOverridden: isOverridden,
                    onChangeSession: changeTodaySession
                )
            } else if !viewModel.isActive && !viewModel.showSummary {
                if didCheckResume {
                    startView
                } else {
                    resumeCheckView
                }
            } else {
                activeWorkoutView
            }

            if viewModel.isResting {
                RestTimer(
                    totalSeconds: viewModel.restTotalSeconds,
                    endDate: $viewModel.restEndDate,
                    isActive: $viewModel.isResting,
                    onSkip: { viewModel.skipRest() },
                    onFinished: { viewModel.finishRestRecovery() },
                    onExtend: { viewModel.extendRest(by: $0) },
                    nextSet: viewModel.upcomingSetSummary,
                    coachNote: viewModel.coachNote,
                    isCoachThinking: viewModel.isCoachThinking,
                    chatText: $viewModel.inlineChatText,
                    onSend: { Task { await viewModel.sendInlineMessage() } },
                    stats: RestStats(
                        exerciseName: viewModel.currentPrescription?.exerciseName ?? "",
                        tonnage: viewModel.totalTonnage,
                        setsDone: viewModel.setCount,
                        duration: viewModel.sessionDuration,
                        heartRate: viewModel.heartRateMonitor,
                        todaySets: viewModel.exerciseSetsForCurrentExercise,
                        lastSets: viewModel.lastSessionSets,
                        lastLoaded: viewModel.lastSessionSetsLoaded,
                        strengthHistory: viewModel.strengthHistory,
                        todayE1RM: viewModel.todayE1RM
                    ),
                    sessionType: effectiveSessionType
                )
                .transition(.opacity)
            }

            if viewModel.showPRCelebration, let pr = viewModel.latestPR {
                PRCelebration(
                    exercise: pr.exercise,
                    estimated1RM: pr.estimated1RM,
                    isShowing: $viewModel.showPRCelebration
                )
                .transition(.opacity)
            }
        }
        .task {
            // Loads once per view lifetime. The state is read even when the
            // caller handed us a type, because the swap button still needs to
            // know whether today is already off-schedule; only the resolved
            // type is conditional.
            if !didResolveType {
                didResolveType = true
                await resolveToday()
            }
            // If the user left mid-workout (accidental back-swipe, app
            // backgrounded, etc.) the Supabase session is still `in_progress`
            // — pick it back up automatically instead of showing the start
            // screen, which would otherwise mint a brand-new session on tap.
            if !isNonStrengthDay {
                await viewModel.resumeIfInProgress(type: effectiveSessionType)
            } else if effectiveSessionType == "Cardio+Abs" {
                // Cardio+Abs was excluded from the resume check altogether,
                // so leaving mid-ab-work landed back on the cardio screen with
                // the open session stranded. Rejoin only once ab sets exist —
                // before that, the cardio log is still the right screen.
                await viewModel.resumeIfStrengthWorkStarted(type: effectiveSessionType)
            }
            didCheckResume = true
        }
        // Hold the screen awake for the duration of a session. A set plus its
        // rest is minutes without a touch, which is exactly what auto-lock
        // counts, so the display would go dark over the prescription card and
        // the countdown.
        .onChange(of: viewModel.isActive) { _, active in syncWakeLock(active) }
        .onAppear { syncWakeLock(viewModel.isActive) }
        .onDisappear { syncWakeLock(false) }
        // Rebuild the heart-rate query every time the app comes back to the
        // front. iOS suspends the app when you switch away, which stops the
        // anchored query delivering — and nothing restarted it, so the feed
        // died at whatever moment you first checked a message and stayed dead
        // for the rest of the session. It resumes from its stored anchor, so
        // this costs nothing when the feed was never interrupted.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.heartRateMonitor.resume()
                // A new day since the last read: yesterday's swap is over.
                if resolvedOn != Config.isoDay(), !viewModel.isActive {
                    Task { await resolveToday() }
                }
            }
        }
        .onAppear {
            if didResolveType, resolvedOn != Config.isoDay(), !viewModel.isActive {
                Task { await resolveToday() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mesocycleDidChange)) { _ in
            // Settings (or post-workout advance) changed today's session.
            // Only re-resolve when this view is showing today's auto-picked
            // type — if the Dashboard navigated in with an explicit
            // `sessionType`, that's the workout the user committed to and
            // we shouldn't swap it out mid-flow.
            guard sessionType.isEmpty, !viewModel.isActive else { return }
            Task { await resolveToday() }
        }
        .sheet(item: $editingSet) { set in
            EditSetSheet(
                set: set,
                onSave: { weight, reps, rpe in
                    Task { await viewModel.editLoggedSet(set, weight: weight, reps: reps, rpe: rpe) }
                },
                onDelete: {
                    Task { await viewModel.deleteLoggedSet(set) }
                }
            )
        }
        // The page carries its own header in both states (TRAIN · TODAY and
        // the session name before a session; name, week and END during one),
        // so the bar never shows a title. On the Train tab there is nothing to
        // go back to and the bar hides outright; pushed from the Dashboard it
        // stays for the back button, empty.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // navigationBarHidden, not toolbar(.hidden): the latter let the
        // content run up under the status bar on the Train tab root, so the
        // session name sat behind the clock.
        .navigationBarHidden(viewModel.isActive || sessionType.isEmpty)
        .sheet(isPresented: $viewModel.showSummary) {
            if let summary = viewModel.summary {
                WorkoutSummaryView(summary: summary, sessionType: viewModel.sessionType.isEmpty ? effectiveSessionType : viewModel.sessionType) {
                    viewModel.dismissSummary()
                }
            }
        }
        // Block the swipe-from-edge back gesture while a workout is in
        // progress (or while we're probing for one to resume). The view
        // will auto-resume after an accidental dismissal, but the flash
        // of the start screen looked like the session had been thrown
        // away — disabling the gesture avoids the surprise entirely.
        // Idle state (no active session, resume probe finished) keeps
        // the back-swipe so the Begin screen still feels like a normal
        // push.
        // Hiding the back button is the documented way to suppress the
        // interactive pop gesture, and unlike the UIKit gate below it does not
        // depend on winning a lookup against SwiftUI's controller hierarchy.
        // Two independent mechanisms because one accidental swipe mid-session
        // costs a resume round-trip and a card rebuild, and the gate alone has
        // now failed twice.
        //
        // Nothing is trapped by this: END finishes the session deliberately,
        // and the tab bar is still there to leave it running.
        .navigationBarBackButtonHidden(viewModel.isActive || !didCheckResume)
        .interactivePopGesture(enabled: !viewModel.isActive && didCheckResume)
    }

    /// Brings the wake-lock hold in line with `active`, tracking ownership so
    /// repeated calls are harmless. Needed because the three call sites
    /// overlap: leaving and re-entering the view while a session is still
    /// running would otherwise either double-acquire or drop the hold entirely.
    private func syncWakeLock(_ active: Bool) {
        guard active != holdsWakeLock else { return }
        holdsWakeLock = active
        if active {
            ScreenWakeLock.acquire()
        } else {
            ScreenWakeLock.release()
        }
    }

    // MARK: - Resume probe

    /// Shown for the brief moment between the view appearing and
    /// `resumeIfInProgress` returning. Prevents the "Begin session" screen
    /// from flashing into view when the user is actually re-entering a
    /// workout that's still in progress on the server.
    private var resumeCheckView: some View {
        VStack(spacing: 18) {
            Spacer()
            VauxLogo(size: 30, color: .signal)
                .shadow(color: Color.signal.opacity(0.5), radius: 14)
            HStack(spacing: 8) {
                GlowDot(color: .signal, size: 5)
                Text("SYNCING SESSION STATE")
                    .font(.eyebrowSmall)
                    .kerning(1.6)
                    .foregroundStyle(Color.fg2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Start screen — session brief

    /// The Dashboard's session block, on the Train tab: the block position,
    /// the session name in the display face, its muscles, three facts from
    /// history, and START SESSION. Facts load once; the screen never waits.
    private var startView: some View {
        let type = effectiveSessionType.isEmpty ? "Session" : effectiveSessionType
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                EditorialEyebrow(text: "Train · Today")
                Spacer()
                SessionSwapButton(
                    currentType: effectiveSessionType,
                    isOverridden: isOverridden,
                    onChange: changeTodaySession
                )
            }
            .frame(height: 44)
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 4)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 0) {
                if let blockLine {
                    EditorialEyebrow(text: blockLine, color: .mint, size: 10, kerning: 2.5)
                }
                Text(effectiveSessionType.isEmpty ? "START" : effectiveSessionType.uppercased())
                    .font(.display(88))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 14)
                EditorialEyebrow(text: focusForType(type), color: Editorial.mid, size: 10.5, kerning: 2.5)
                    .padding(.top, 18)
            }
            .padding(.horizontal, Editorial.gutter)

            startFacts
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 36)

            Spacer()

            Button {
                Haptic.medium()
                Task { await viewModel.startOrResumeWorkout(type: effectiveSessionType) }
            } label: {
                HStack(spacing: 12) {
                    if viewModel.isLoading {
                        ProgressView().tint(Color.signalInk)
                    } else {
                        Text("START SESSION")
                            .font(.display(24))
                            .kerning(0.6)
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(Color.signalInk)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.signal))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(viewModel.isLoading)
            .padding(.horizontal, Editorial.gutter)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: effectiveSessionType) { await loadStartFacts() }
    }

    /// "WEEK 1 · DAY 3 · BASELINE"
    private var blockLine: String? {
        guard let blockWeek else { return nil }
        var parts = ["Week \(blockWeek)"]
        if let blockDay { parts.append("Day \(blockDay)") }
        if let phase = Self.phaseName(week: blockWeek) { parts.append(phase) }
        return parts.joined(separator: " · ")
    }

    private static func phaseName(week: Int) -> String? {
        switch week {
        case 1: return "Baseline"
        case 2: return "Volume"
        case 3: return "Peak"
        case 4: return "Deload"
        default: return nil
        }
    }

    private static func rpeTargets(week: Int?) -> (top: String, backoff: String) {
        switch week {
        case 3: return ("9", "Back-off 8")
        case 4: return ("7", "Back-off 6")
        default: return ("8", "Back-off 7")
        }
    }

    /// Three facts: the last session of this type, this week's sessions, and
    /// the RPE targets the block week calls for.
    private var startFacts: some View {
        let targets = Self.rpeTargets(week: blockWeek)
        let type = effectiveSessionType.isEmpty ? "session" : effectiveSessionType
        return HStack(alignment: .top, spacing: 0) {
            startFact(
                label: "Last \(type)",
                value: lastSameSession.map { tonnageString($0.tonnageKg ?? 0) } ?? "—",
                sub: lastSameSession.map { Self.shortDate($0.date) } ?? "No history yet",
                first: true
            )
            startFact(
                label: "This week",
                value: "\(sessionsThisWeek)",
                sub: sessionsThisWeek == 1 ? "session done" : "sessions done",
                first: false
            )
            startFact(label: "Top set RPE", value: targets.top, sub: targets.backoff, first: false)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    private func startFact(label: String, value: String, sub: String, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialEyebrow(text: label, color: Editorial.muted, size: 9, kerning: 1.8)
            Text(value)
                .font(.display(22))
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

    private func loadStartFacts() async {
        let service = WorkoutService()
        guard let sessions = try? await service.fetchSessionHistory(days: 60) else { return }
        let completed = sessions.filter { $0.status == "completed" }
        lastSameSession = completed
            .filter { $0.type == effectiveSessionType }
            .max { $0.date < $1.date }
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let key = Self.dayFormatter.string(from: weekStart)
        sessionsThisWeek = completed.filter { $0.date >= key }.count
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "Sep 1" from a "yyyy-MM-dd" key.
    private static func shortDate(_ key: String) -> String {
        guard let date = dayFormatter.date(from: String(key.prefix(10))) else { return key }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Active workout

    private var activeWorkoutView: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sessionHeader
                    sessionStatRow

                    if viewModel.isCoachThinking {
                        coachThinkingStrip
                            .padding(.horizontal, Editorial.gutter)
                            .padding(.top, 18)
                    } else if let note = viewModel.coachNote {
                        CoachNoteStrip(note: note)
                            .padding(.horizontal, Editorial.gutter)
                            .padding(.top, 18)
                    }

                    if let error = viewModel.errorMessage {
                        errorStrip(error)
                            .padding(.horizontal, Editorial.gutter)
                            .padding(.top, 12)
                    }

                    Group {
                        if viewModel.isLoading && viewModel.currentPrescription == nil {
                            prescriptionPlaceholder
                        } else if let rx = viewModel.currentPrescription {
                            PrescriptionCard(
                                prescription: rx,
                                exerciseSetIndex: viewModel.exerciseSetIndex,
                                loggedSets: viewModel.exerciseSetsForCurrentExercise,
                                currentPhase: viewModel.currentPhase,
                                phaseSetIndex: viewModel.phaseSetIndex,
                                exerciseIndex: viewModel.currentExerciseIndex,
                                exerciseCount: viewModel.allPrescriptions.isEmpty ? nil : viewModel.allPrescriptions.count,
                                lastBlock: viewModel.lastBlockReference,
                                onEditSet: { editingSet = $0 }
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))

                            if viewModel.isCurrentExerciseComplete() {
                                nextExerciseButton
                                    .padding(.top, 12)
                            }

                            if viewModel.upcomingPrescriptions.count > 0 {
                                UpcomingExercisesCard(names: viewModel.upcomingPrescriptions.map(\.exerciseName))
                                    .padding(.top, 12)
                            }
                        } else {
                            emptyPrescriptionCard
                        }
                    }
                    .padding(.horizontal, Editorial.gutter)
                    .padding(.top, 16)

                    if !viewModel.exerciseSetsForCurrentExercise.isEmpty {
                        SetProgressRow(sets: viewModel.exerciseSetsForCurrentExercise, onEdit: { editingSet = $0 })
                            .padding(.horizontal, Editorial.gutter)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 24)
            }

            // Pinned: a set is always loggable without scrolling. Suppressed
            // when there is no prescription to log against.
            if viewModel.currentPrescription != nil {
                WorkoutDock(
                    weight: $viewModel.inputWeight,
                    reps: $viewModel.inputReps,
                    rpe: $viewModel.inputRPE,
                    phase: viewModel.currentPhase,
                    setLabel: dockSetLabel,
                    isBodyweight: ExerciseCatalog.isBodyweight(viewModel.currentPrescription?.exerciseName ?? ""),
                    isLoading: viewModel.isLoggingSet,
                    onLog: { Task { await viewModel.logSet() } },
                    onAskCoach: { viewModel.showInlineChat = true }
                )
            }
        }
        .sheet(isPresented: $viewModel.showInlineChat) {
            WorkoutCoachSheet(
                text: $viewModel.inlineChatText,
                exercise: viewModel.currentPrescription?.exerciseName ?? viewModel.sessionType,
                lastQuestion: viewModel.lastInlineQuestion,
                coachNote: viewModel.coachNote,
                isThinking: viewModel.isCoachThinking,
                onSend: { Task { await viewModel.sendInlineMessage() } },
                openInCoach: openInCoachAction
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink0)
        }
        .onChange(of: viewModel.currentPrescription?.exerciseName) { _, _ in
            viewModel.loadLastSessionSetsIfNeeded()
        }
        .onAppear { viewModel.loadLastSessionSetsIfNeeded() }
    }

    /// Closes the sheet, then hands over to the Coach tab.
    private var openInCoachAction: (() -> Void)? {
        guard let switchToChatTab else { return nil }
        return {
            viewModel.showInlineChat = false
            switchToChatTab()
        }
    }

    /// "WORKING SET 2 OF 2" for the dock's eyebrow.
    private var dockSetLabel: String {
        guard let rx = viewModel.currentPrescription else { return viewModel.currentPhase.rawValue }
        let i = viewModel.phaseSetIndex + 1
        switch viewModel.currentPhase {
        case .warmup: return "Warm-up \(i) of \(max(rx.warmupSets.count, i))"
        case .working: return "Working set \(i) of \(max(rx.workingSets.count, i))"
        case .backoff: return "Back-off \(i) of \(max(rx.backoffSets.count, i))"
        }
    }

    // MARK: - Header and stat row

    /// Session name in the display face with the block week beside it, and
    /// END as a quiet ember-tinted button. Replaces the navigation bar while
    /// a session is running.
    private var sessionHeader: some View {
        HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(viewModel.sessionType.uppercased())
                    .font(.display(44))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let week = viewModel.mesocycleWeek, let phase = viewModel.mesocyclePhaseLabel {
                    EditorialEyebrow(text: "Week \(week) · \(phase)", color: .mint, size: 10, kerning: 2.2)
                }
            }
            Spacer(minLength: 12)
            Button {
                Haptic.warning()
                Task { await viewModel.endWorkout() }
            } label: {
                Text("END")
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(2.5)
                    .foregroundStyle(Color.ember)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ember.opacity(0.14)))
                    .frame(minHeight: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.95))
            .accessibilityLabel("End workout")
            .accessibilityHint("Finishes this session and shows your summary")
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 8)
    }

    /// Time with sets done, tonnage, heart rate with its state.
    private var sessionStatRow: some View {
        let bpm = viewModel.heartRateMonitor.hasStalled() ? nil : viewModel.heartRateMonitor.currentBPM
        let planned = viewModel.plannedSetTotal
        let done = viewModel.setCount + viewModel.warmupCount
        return HStack(alignment: .top, spacing: 0) {
            statCell(label: "Time", value: viewModel.formattedDuration,
                     sub: planned > done ? "\(done) of \(planned) sets" : "\(done) sets", subColor: Editorial.muted, first: true)
            statCell(label: "Tonnage", value: tonnageString(viewModel.totalTonnage),
                     sub: "This session", subColor: Editorial.muted, first: false)
            statCell(label: "Heart", value: bpm.map { "\($0)" } ?? "—",
                     sub: viewModel.heartStateLabel ?? "No signal", subColor: Editorial.muted, first: false)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 20)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter)
        }
    }

    private func statCell(label: String, value: String, sub: String, subColor: Color, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialEyebrow(text: label, color: Editorial.muted, size: 9, kerning: 1.8)
            Text(value)
                .font(.display(28))
                .foregroundStyle(Color.fg0)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            EditorialEyebrow(text: sub, color: subColor, size: 9, kerning: 1.2)
        }
        .padding(.leading, first ? 0 : 12)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if !first { Rectangle().fill(Color.line).frame(width: 1).padding(.top, 16) }
        }
    }

    private func tonnageString(_ t: Double) -> String {
        if t >= 1000 { return String(format: "%.1fT", t / 1000) }
        return "\(Int(t)) kg"
    }

    // MARK: - Coach feedback strips

    /// Same shape as the quote it will become: the lime mark, three mint dots
    /// where the words will land, COACH · WRITING beneath.
    private var coachThinkingStrip: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("“")
                .font(.display(52))
                .foregroundStyle(Color.signal)
                .frame(height: 30, alignment: .top)
                .offset(y: -4)
            VStack(alignment: .leading, spacing: 12) {
                CoachTypingDots()
                    .padding(.top, 6)
                EditorialEyebrow(text: "Coach · writing", color: Editorial.muted, size: 9.5, kerning: 1.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Coach is writing")
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            EditorialEyebrow(text: "Error", color: .ember, size: 9.5, kerning: 2)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.fg1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    private var emptyPrescriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialEyebrow(text: "No plan yet", color: Editorial.muted, size: 9.5, kerning: 2)
            Text("NOTHING TO LIFT")
                .font(.display(32))
                .foregroundStyle(Color.fg0)
            Text("The coach didn't send exercises for this session. Ask again, or end the session and start a new one.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.fg1)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    Haptic.light()
                    Task { await viewModel.retryPrescription() }
                } label: {
                    EditorialEyebrow(text: "Ask again →", color: .signal, size: 10, kerning: 2.2)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }
            .padding(.top, 4)
            .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ink2.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.line, lineWidth: 1))
    }

    /// The card's silhouette while the first prescription is on its way.
    private var prescriptionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.ink3).frame(width: 110, height: 9)
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(Color.ink3).frame(width: 60, height: 9)
            }
            RoundedRectangle(cornerRadius: 4).fill(Color.ink3).frame(width: 220, height: 30)
            Rectangle().fill(Color.line).frame(height: 1).padding(.top, 6)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 10).fill(Color.ink3).frame(width: 96, height: 44)
                RoundedRectangle(cornerRadius: 10).fill(Color.ink3).frame(width: 96, height: 44)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ink2.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.line, lineWidth: 1))
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading the plan")
    }

    // MARK: - Rest day

    /// A day marked Rest. Nothing to start and nothing to log; the swap
    /// action is there if he changes his mind.
    private var restDayView: some View {
        ZStack {
            Color.ink0.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    EditorialEyebrow(text: isOverridden ? "Train · Today · Changed" : "Train · Today")
                    Spacer()
                    SessionSwapButton(
                        currentType: effectiveSessionType,
                        isOverridden: isOverridden,
                        onChange: changeTodaySession
                    )
                }
                .frame(height: 44)
                .padding(.horizontal, Editorial.gutter)

                VStack(alignment: .leading, spacing: 14) {
                    if let blockLine {
                        EditorialEyebrow(text: blockLine, color: .mint, size: 10, kerning: 2.5)
                    }
                    Text("REST")
                        .font(.display(88))
                        .foregroundStyle(Color.fg0)
                    EditorialEyebrow(text: "Full day off · Nothing to log", color: Editorial.mid, size: 10.5, kerning: 2.5)
                }
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 120)

                VStack(alignment: .leading, spacing: 8) {
                    EditorialEyebrow(text: "Tomorrow", color: Editorial.muted, size: 9, kerning: 1.8)
                    Text(viewModel.mesocycle.rotationSessionType.uppercased())
                        .font(.display(28))
                        .foregroundStyle(Color.fg0)
                    EditorialEyebrow(text: "The rotation picks up where it left off", color: Editorial.muted, size: 8.5, kerning: 1.2)
                }
                .padding(.horizontal, Editorial.gutter)
                .padding(.top, 36)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter).padding(.top, 20)
                }
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func iconForType(_ type: String) -> String {
        switch type {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "dumbbell.fill"
        case "Legs": return "figure.strengthtraining.functional"
        case "Cardio+Abs": return "heart.circle.fill"
        case "Yoga": return "figure.mind.and.body"
        case "Rest": return "moon.zzz"
        default: return "figure.strengthtraining.traditional"
        }
    }

    private func focusForType(_ type: String) -> String {
        switch type {
        case "Pull": return "Back · Rear delts · Biceps"
        case "Push": return "Chest · Shoulders · Triceps"
        case "Legs": return "Quads · Hamstrings · Glutes"
        case "Cardio+Abs": return "Zone 2 · Core"
        case "Yoga": return "Mobility · Stretching"
        case "Rest": return "Full day off"
        default: return "Full body"
        }
    }

    /// Thin context strip under the stats bar: which mesocycle week this is
    /// and the effort it calls for. The week drives every RPE target in the
    /// programme but used to live only in Settings, so a drifting counter
    /// ("week 6 of 4") went unnoticed while it quietly mis-set intensity.
    private func mesocycleStrip(week: Int, phase: String, rpe: String) -> some View {
        let tint: Color = week == 4 ? .amber : (week == 3 ? .signal : .mint)
        return HStack(spacing: 8) {
            Text("WEEK \(week)")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.14)))

            Text(phase)
                .font(.eyebrowSmall)
                .kerning(1.2)
                .foregroundStyle(Color.fg1)

            Spacer(minLength: 0)

            Text(rpe)
                .font(.eyebrowSmall)
                .foregroundStyle(Color.fg2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.ink1.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line).frame(height: 0.5)
        }
    }

    /// Escape hatch off a finished exercise. Names the next exercise when the
    /// plan knows it, so the tap is a confirmation rather than a leap.
    private var nextExerciseButton: some View {
        Button {
            Haptic.medium()
            Task { await viewModel.advanceToNextExercise() }
        } label: {
            HStack(spacing: 8) {
                Text(viewModel.upcomingPrescriptions.first.map { "Next: \($0.exerciseName)" }
                     ?? "Ask coach for the next exercise")
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Color.signalInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.signal))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(viewModel.isCoachThinking)
        .padding(.horizontal, 16)
    }
}

// MARK: - Coach note (pull quote)

/// The coach's latest line as a pull quote: a lime mark, the text, COACH and
/// the time beneath. Long replies show three lines with READ MORE and expand
/// in place.
struct CoachNoteStrip: View {
    let note: String
    @State private var expanded = false

    private var isLong: Bool { note.count > 110 || note.contains("\n") }

    var body: some View {
        Button {
            guard isLong else { return }
            Haptic.selection()
            withAnimation(Motion.smooth) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("“")
                    .font(.display(52))
                    .foregroundStyle(Color.signal)
                    .frame(height: 30, alignment: .top)
                    .offset(y: -4)
                VStack(alignment: .leading, spacing: 8) {
                    // Folded: one flat text so the limit applies to the whole
                    // note, not to each paragraph (which let a six-paragraph
                    // plan fill the screen). Expanded: the rendered markdown.
                    if expanded {
                        MarkdownText(content: note)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(Color.bone)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(MarkdownText.plainText(note).replacingOccurrences(of: ", ", with: " "))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(Color.bone)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack {
                        EditorialEyebrow(text: "Coach", color: Editorial.muted, size: 9.5, kerning: 1.8)
                        Spacer()
                        if isLong {
                            EditorialEyebrow(text: expanded ? "Show less" : "Read more ⌄", color: Editorial.mid, size: 9.5, kerning: 1.8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Coach said: \(MarkdownText.plainText(note))")
    }
}

// MARK: - Logged sets

struct SetProgressRow: View {
    let sets: [WorkoutSet]
    var onEdit: ((WorkoutSet) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                EditorialEyebrow(text: "Logged", color: Editorial.muted, size: 9.5, kerning: 2)
                Spacer()
                EditorialEyebrow(text: "\(sets.count) set\(sets.count == 1 ? "" : "s")", color: Editorial.muted, size: 9.5, kerning: 1.5)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sets.enumerated()), id: \.offset) { idx, set in
                        setChip(index: idx + 1, set: set)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ink2.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.line, lineWidth: 1))
    }

    private func setChip(index: Int, set: WorkoutSet) -> some View {
        let weight = set.actualWeightKg ?? set.targetWeightKg ?? 0
        let reps = set.actualReps ?? set.targetReps ?? 0
        let rpe = set.actualRpe ?? set.targetRpe
        let weightLabel = ExerciseCatalog.setWeightLabel(weight, exercise: set.exercise)
        return Button {
            guard let onEdit, set.id != nil else { return }
            Haptic.light()
            onEdit(set)
        } label: {
            VStack(spacing: 3) {
                EditorialEyebrow(text: "Set \(index)", color: Editorial.muted, size: 8.5, kerning: 1.2)
                Text("\(weightLabel) × \(reps)")
                    .font(.display(15))
                    .foregroundStyle(Color.fg0)
                if let rpe {
                    EditorialEyebrow(text: "RPE \(rpe.wholeOrOne)", color: .mint, size: 9, kerning: 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set \(index): \(weightLabel) by \(reps)")
        .accessibilityHint("Opens this set to correct it")
    }
}

// MARK: - Upcoming exercises

struct UpcomingExercisesCard: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                EditorialEyebrow(text: "Up next", color: Editorial.muted, size: 9.5, kerning: 2)
                Spacer()
                EditorialEyebrow(text: "\(names.count)", color: Editorial.muted, size: 9.5, kerning: 1.5)
            }
            .padding(.bottom, 6)

            ForEach(Array(names.enumerated()), id: \.offset) { idx, name in
                HStack(spacing: 14) {
                    Text("\(idx + 2)")
                        .font(.display(13))
                        .foregroundStyle(Color.fg3)
                        .frame(width: 12, alignment: .leading)
                    Text(name.uppercased())
                        .font(.display(19))
                        .foregroundStyle(idx == 0 ? Color.fg0 : Color.fg1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }
                .frame(height: 40)
                .overlay(alignment: .top) {
                    if idx > 0 { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ink2.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.line, lineWidth: 1))
    }
}
