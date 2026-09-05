// CardioYogaLogView.swift
// Vaux
//
// The non-strength day as a two-part day, in the scheme. Cardio comes in
// from the Watch and is imported as ruled rows; abs is a coached session like
// any other, started from a pinned START ABS. Manual cardio logging is there
// for what the Watch missed, folded behind a text action so it never leads.
// Yoga uses the same page with one half.

import SwiftUI
import HealthKit

struct CardioYogaLogView: View {
    let sessionType: String
    /// "Week 1 · Day 4 · Baseline" from the parent, which owns the block state.
    var blockLine: String? = nil
    /// Starts the strength flow for the ab work on a Cardio+Abs day.
    var onStartStrengthSession: (() -> Void)? = nil
    /// Whether today's session is already a manual swap rather than the
    /// schedule's choice.
    var isOverridden: Bool = false
    /// Swaps today's session for another, or restores the schedule when passed
    /// nil. Omitted by callers that don't own the schedule.
    var onChangeSession: ((String?) -> Void)? = nil

    @State private var healthWorkouts: [HKWorkout] = []
    @State private var isLoadingHK = false
    @State private var hkError: String?

    @State private var todaysSession: WorkoutSession?
    /// Today's cardio entries (tagged in `notes`), imported or manual.
    @State private var loggedEntries: [WorkoutSet] = []
    /// Today's ab work, logged through the strength flow.
    @State private var absSets: [WorkoutSet] = []
    @State private var lastAbs: AbsRecap?
    @State private var isLoadingSession = true
    @State private var errorMessage: String?

    @State private var manualOpen = false
    @State private var selectedActivity: String
    @State private var durationMinutes: Int = 30
    @State private var intensity: Double = 7.0
    @State private var notes: String = ""
    @State private var isLogging = false

    private let workoutService = WorkoutService()
    private let health = HealthKitManager.shared

    init(
        sessionType: String,
        blockLine: String? = nil,
        onStartStrengthSession: (() -> Void)? = nil,
        isOverridden: Bool = false,
        onChangeSession: ((String?) -> Void)? = nil
    ) {
        self.sessionType = sessionType
        self.blockLine = blockLine
        self.onStartStrengthSession = onStartStrengthSession
        self.isOverridden = isOverridden
        self.onChangeSession = onChangeSession
        _selectedActivity = State(initialValue: Self.defaultActivity(for: sessionType))
    }

    // MARK: - Activity options

    private static let cardioActivities = [
        "Boxing", "Running", "Treadmill", "Cycling", "Rowing",
        "Stairs", "Elliptical", "Swimming", "Jump Rope", "Hiking", "Other"
    ]
    private static let yogaActivities = [
        "Vinyasa", "Hatha", "Power", "Yin", "Restorative", "Ashtanga", "Flow", "Other"
    ]

    private var activityOptions: [String] {
        isYoga ? Self.yogaActivities : Self.cardioActivities
    }

    private var isYoga: Bool { sessionType == "Yoga" }
    private var isCardioAbs: Bool { sessionType == "Cardio+Abs" }

    private static func defaultActivity(for type: String) -> String {
        switch type {
        case "Yoga": return "Vinyasa"
        case "Cardio+Abs": return "Boxing"
        default: return "Other"
        }
    }

    /// Tag persisted in `notes` so the History view can render these entries
    /// as "30 min · Boxing" rather than "0kg × 30".
    private var entryTag: String { isYoga ? "yoga" : "cardio" }

    /// The last completed ab work, for the ABS section before today's starts.
    struct AbsRecap {
        var date: String
        var exercises: [String]
        var sets: Int
        var minutes: Int?
        var rpeLow: Double?
        var rpeHigh: Double?
    }

    // MARK: - Derived

    private var cardioMinutes: Int { loggedEntries.reduce(0) { $0 + ($1.actualReps ?? 0) } }
    private var manualEntries: [WorkoutSet] {
        loggedEntries.filter { !($0.notes ?? "").contains("hk:") }
    }
    private var absDone: Bool { !absSets.isEmpty }

    /// Ab exercises in the order they were done, each with its sets.
    private var absByExercise: [(name: String, sets: [WorkoutSet])] {
        var order: [String] = []
        var grouped: [String: [WorkoutSet]] = [:]
        for set in absSets where set.isWarmup != true {
            if grouped[set.exercise] == nil { order.append(set.exercise) }
            grouped[set.exercise, default: []].append(set)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.ink0.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    hero
                    dayRow

                    if let error = errorMessage {
                        errorStrip(error)
                    }

                    cardioSection
                    if manualOpen {
                        manualFold
                    }
                    if !manualEntries.isEmpty {
                        loggedSection
                    }
                    if isCardioAbs {
                        absSection
                    }
                    Spacer(minLength: 40)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCardioAbs, onStartStrengthSession != nil {
                    pinnedButton
                }
            }
        }
        .task {
            await loadTodaysSession()
            await loadHealthWorkouts()
            if isCardioAbs { await loadLastAbs() }
        }
    }

    // MARK: - Header

    private var topBar: some View {
        HStack {
            EditorialEyebrow(text: isOverridden ? "Train · Today · Changed" : "Train · Today")
            Spacer()
            if let onChangeSession {
                SessionSwapButton(
                    currentType: sessionType,
                    isOverridden: isOverridden,
                    onChange: onChangeSession
                )
            }
        }
        .frame(height: 44)
        .padding(.horizontal, Editorial.gutter)
    }

    private var title: String {
        isCardioAbs ? "CARDIO+ABS" : sessionType.uppercased()
    }

    private var focusLine: String {
        isYoga ? "Mobility · Stretching" : "Zone 2 · Core · 30–45 min"
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let blockLine {
                EditorialEyebrow(text: blockLine, color: .mint, size: 10, kerning: 2.5)
            }
            Text(title)
                .font(.display(68))
                .foregroundStyle(Color.fg0)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            EditorialEyebrow(text: focusLine, color: Editorial.mid, size: 10.5, kerning: 2.5)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 36)
    }

    // MARK: - Day row

    private var cardioState: (value: String, sub: String, color: Color) {
        if cardioMinutes > 0 {
            let first = loggedEntries.first
            let how = (first?.notes ?? "").contains("hk:") ? "Imported" : "Logged"
            return ("\(cardioMinutes) min", "\(first?.exercise ?? "Cardio") · \(how)", .mint)
        }
        if isLoadingHK { return ("Reading", "Apple Watch", Editorial.muted) }
        if !healthWorkouts.isEmpty {
            return ("On Watch", "\(healthWorkouts.count) to import", Color.fg0)
        }
        return ("Waiting", "From Watch", Editorial.muted)
    }

    private var absState: (value: String, sub: String, color: Color) {
        if absDone {
            let sets = absSets.filter { $0.isWarmup != true }.count
            if let minutes = Self.spanMinutes(absSets) {
                return ("\(sets) sets", "\(minutes) min · \(absByExercise.count) movements", .mint)
            }
            return ("\(sets) sets", "\(absByExercise.count) movements", .mint)
        }
        if let lastAbs {
            return ("Not started", "\(lastAbs.exercises.count) movements", Color.fg0)
        }
        return ("Not started", "Strength mode", Color.fg0)
    }

    private var dayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            dayCell(index: "01", name: isYoga ? "Yoga" : "Cardio", state: cardioState, first: true)
            if isCardioAbs {
                dayCell(index: "02", name: "Abs", state: absState, first: false)
            }
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter)
        }
        .padding(.top, 30)
    }

    private func dayCell(index: String, name: String,
                         state: (value: String, sub: String, color: Color),
                         first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                EditorialEyebrow(text: index, color: Editorial.muted, size: 9, kerning: 1.8)
                EditorialEyebrow(text: name, color: Color.fg0, size: 9, kerning: 1.8)
            }
            Text(state.value.uppercased())
                .font(.display(22))
                .foregroundStyle(state.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            EditorialEyebrow(text: state.sub, color: Editorial.muted, size: 8.5, kerning: 1.2)
        }
        .padding(.leading, first ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if !first { Rectangle().fill(Color.line).frame(width: 1) }
        }
    }

    // MARK: - Cardio from the Watch

    private var cardioSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(isYoga ? "Yoga" : "Cardio", right: "From Apple Watch")

            if isLoadingHK {
                stateLine("Reading the Watch…", body: nil)
            } else if let err = hkError {
                stateLine("Watch unavailable", body: err, color: .ember)
            } else if healthWorkouts.isEmpty {
                stateLine("Nothing on the Watch yet",
                          body: "Record it on the Watch and it lands here. Pull down to sync.")
            } else {
                ForEach(Array(healthWorkouts.enumerated()), id: \.element.uuid) { index, workout in
                    healthWorkoutRow(workout, first: index == 0)
                }
            }

            Button {
                Haptic.light()
                withAnimation(Motion.snappy) { manualOpen.toggle() }
            } label: {
                EditorialEyebrow(
                    text: manualOpen ? "↘ Log \(isYoga ? "yoga" : "cardio") manually" : "↗ Log \(isYoga ? "yoga" : "cardio") manually",
                    color: manualOpen ? Editorial.mid : .signal, size: 10, kerning: 2
                )
                .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 4)
        }
    }

    private func stateLine(_ headline: String, body: String?, color: Color = Editorial.muted) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorialEyebrow(text: headline, color: color, size: 10, kerning: 2.2)
            if let body {
                Text(body)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(color == .ember ? Color.ember : Editorial.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private func healthWorkoutRow(_ workout: HKWorkout, first: Bool) -> some View {
        let name = Self.displayName(for: workout.workoutActivityType)
        let minutes = Int((workout.duration / 60).rounded())
        let alreadyImported = loggedEntries.contains { set in
            (set.notes ?? "").contains(workout.uuid.uuidString)
        }
        var facts = ["\(minutes) min", Self.timeFormatter.string(from: workout.startDate)]
        if let kcal = Self.kcal(workout) { facts.append("\(kcal) kcal") }
        if let bpm = Self.averageHR(workout) { facts.append("\(bpm) bpm") }

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(name.uppercased())
                    .font(.display(22))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                EditorialEyebrow(text: facts.joined(separator: " · "), color: Editorial.muted, size: 9, kerning: 1.4)
            }
            Spacer()
            if alreadyImported {
                EditorialEyebrow(text: "✓ Imported", color: .mint, size: 10, kerning: 2)
            } else {
                Button {
                    Haptic.medium()
                    Task { await importWorkout(workout, displayName: name, minutes: minutes) }
                } label: {
                    EditorialEyebrow(text: "Import", color: .signal, size: 10, kerning: 2)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                // Gated on the initial fetch, not on a session existing: the
                // session is created lazily by `ensureSession()` on first log.
                .disabled(isLogging || isLoadingSession)
                .accessibilityLabel("Import \(name) from Apple Watch")
            }
        }
        .frame(minHeight: 60)
        .padding(.horizontal, Editorial.gutter)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter) }
        }
    }

    // MARK: - Manual fold

    private var manualFold: some View {
        VStack(alignment: .leading, spacing: 0) {
            activityWords
                .padding(.top, 6)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    EditorialEyebrow(text: "Duration", color: Editorial.muted, size: 9, kerning: 1.8)
                    durationStepper
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    EditorialEyebrow(text: "Intensity · RPE", color: Editorial.muted, size: 9, kerning: 1.8)
                    rpeScale
                }
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Color.line).frame(width: 1) }
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 22)

            HStack {
                TextField("Notes", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.fg0)
                if notes.isEmpty {
                    EditorialEyebrow(text: "Optional", color: Editorial.muted, size: 8.5, kerning: 1.5)
                }
            }
            .frame(minHeight: 48)
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 18)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter)
            }

            HStack {
                Spacer()
                Button {
                    Haptic.medium()
                    Task { await submitManualEntry() }
                } label: {
                    HStack(spacing: 8) {
                        if isLogging {
                            ProgressView().tint(Color.signal).scaleEffect(0.7)
                        }
                        EditorialEyebrow(text: "+ Log entry", color: .signal, size: 10.5, kerning: 2)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(isLogging || isLoadingSession)
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 6)
        }
        .transition(.opacity)
    }

    /// The activity as a horizontal run of display words — chosen in lime.
    private var activityWords: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                ForEach(activityOptions, id: \.self) { option in
                    let chosen = option == selectedActivity
                    Button {
                        Haptic.selection()
                        withAnimation(Motion.snappy) { selectedActivity = option }
                    } label: {
                        Text(option.uppercased())
                            .font(.display(chosen ? 26 : 20))
                            .foregroundStyle(chosen ? Color.signal : Color.fg3)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, Editorial.gutter)
        }
    }

    private var durationStepper: some View {
        HStack(spacing: 12) {
            roundButton("minus") {
                durationMinutes = max(5, durationMinutes - 5)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(durationMinutes)")
                    .font(.display(34))
                    .foregroundStyle(Color.fg0)
                    .contentTransition(.numericText())
                    .frame(minWidth: 44, alignment: .leading)
                EditorialEyebrow(text: "min", color: Editorial.muted, size: 9, kerning: 1.5)
            }
            roundButton("plus") {
                durationMinutes = min(180, durationMinutes + 5)
            }
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.light()
            withAnimation(Motion.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.fg1)
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(Color.line2, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
    }

    /// RPE 5–10 as a typographic scale, the same one the workout dock uses.
    private var rpeScale: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(5...10, id: \.self) { n in
                let chosen = Int(intensity.rounded()) == n
                Button {
                    Haptic.selection()
                    withAnimation(Motion.snappy) { intensity = Double(n) }
                } label: {
                    Text("\(n)")
                        .font(.display(chosen ? 26 : 18))
                        .foregroundStyle(chosen ? Color.signal : Color.fg3)
                        .frame(minWidth: 18, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("RPE \(n)")
            }
        }
    }

    // MARK: - Logged today (manual entries)

    private var loggedSection: some View {
        let minutes = manualEntries.reduce(0) { $0 + ($1.actualReps ?? 0) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Logged today", right: "\(manualEntries.count) entr\(manualEntries.count == 1 ? "y" : "ies") · \(minutes) min")
            ForEach(Array(manualEntries.enumerated()), id: \.offset) { index, entry in
                let rpe = entry.actualRpe.map { " · RPE \($0.wholeOrOne)" } ?? ""
                ledgerRow(entry.exercise, sub: "\(entry.actualReps ?? 0) min\(rpe)", first: index == 0) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.mint)
                }
            }
        }
    }

    // MARK: - Abs

    @ViewBuilder
    private var absSection: some View {
        if absDone {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Abs", right: Self.doneLabel(absSets))
                ForEach(Array(absByExercise.enumerated()), id: \.offset) { index, group in
                    ledgerRow(group.name, sub: Self.setSummary(group.sets), first: index == 0) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.mint)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Abs", right: "A session like any other")
                if let lastAbs {
                    VStack(alignment: .leading, spacing: 6) {
                        EditorialEyebrow(text: "Last time · \(Self.shortDate(lastAbs.date))", color: Editorial.muted, size: 9, kerning: 1.8)
                        Text(lastAbs.exercises.map { $0.uppercased() }.joined(separator: " · "))
                            .font(.display(22))
                            .foregroundStyle(Color.fg0)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        EditorialEyebrow(text: Self.recapFacts(lastAbs), color: Editorial.muted, size: 8.5, kerning: 1.2)
                    }
                    .padding(.horizontal, Editorial.gutter)
                    .padding(.top, 18)
                } else if isLoadingSession {
                    stateLine("Opening today…", body: nil)
                } else {
                    stateLine("First ab session in the log",
                              body: "The coach writes the movements when you start; they log as sets like any other day.")
                }
            }
        }
    }

    private var pinnedButton: some View {
        Group {
            if absDone {
                HStack(spacing: 12) {
                    Text("DAY COMPLETE")
                        .font(.display(24))
                        .kerning(0.6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(Color.mint)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.line2, lineWidth: 1))
                .accessibilityLabel("Day complete")
            } else {
                Button {
                    Haptic.medium()
                    onStartStrengthSession?()
                } label: {
                    HStack(spacing: 12) {
                        Text("START ABS")
                            .font(.display(24))
                            .kerning(0.6)
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(Color.signalInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.signal))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(isLoadingSession)
            }
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            LinearGradient(colors: [Color.ink0.opacity(0), Color.ink0, Color.ink0],
                           startPoint: .top, endPoint: .bottom)
        )
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
        .padding(.top, 30)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter)
        }
    }

    private func ledgerRow<Right: View>(_ name: String, sub: String, first: Bool,
                                        @ViewBuilder right: () -> Right) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(name.uppercased())
                    .font(.display(22))
                    .foregroundStyle(Color.fg0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                EditorialEyebrow(text: sub, color: Editorial.muted, size: 9, kerning: 1.4)
            }
            Spacer()
            right()
        }
        .frame(minHeight: 60)
        .padding(.horizontal, Editorial.gutter)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color.line).frame(height: 1).padding(.horizontal, Editorial.gutter) }
        }
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.ember).frame(width: 6, height: 6)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ember)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 18)
    }

    // MARK: - Formatting

    private static func kcal(_ workout: HKWorkout) -> Int? {
        workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie()).map { Int($0.rounded()) }
    }

    private static func averageHR(_ workout: HKWorkout) -> Int? {
        let unit = HKUnit.count().unitDivided(by: .minute())
        return workout.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: unit).map { Int($0.rounded()) }
    }

    /// Minutes between the first and last logged set, when both are stamped.
    private static func spanMinutes(_ sets: [WorkoutSet]) -> Int? {
        let stamps = sets.compactMap { $0.loggedAt }.compactMap(TranscriptTurn.parseTimestamp)
        guard let first = stamps.min(), let last = stamps.max(), last > first else { return nil }
        return max(1, Int((last.timeIntervalSince(first) / 60).rounded()))
    }

    private static func doneLabel(_ sets: [WorkoutSet]) -> String {
        let stamps = sets.compactMap { $0.loggedAt }.compactMap(TranscriptTurn.parseTimestamp)
        if let last = stamps.max() {
            return "Done · \(last.formatted(.dateTime.hour().minute()))"
        }
        return "Done"
    }

    /// "3 × 12 · 27.5 kg · RPE 8" from an exercise's working sets.
    private static func setSummary(_ sets: [WorkoutSet]) -> String {
        guard let top = sets.max(by: { ($0.actualWeightKg ?? 0) < ($1.actualWeightKg ?? 0) }) else { return "" }
        var parts = ["\(sets.count) × \(top.actualReps ?? 0)"]
        if let w = top.actualWeightKg, w > 0 { parts.append("\(w.wholeOrOne) kg") }
        if let rpe = top.actualRpe { parts.append("RPE \(rpe.wholeOrOne)") }
        return parts.joined(separator: " · ")
    }

    private static func recapFacts(_ recap: AbsRecap) -> String {
        var parts = ["\(recap.sets) sets"]
        if let minutes = recap.minutes { parts.append("\(minutes) min") }
        if let low = recap.rpeLow, let high = recap.rpeHigh {
            parts.append(low == high ? "RPE \(low.wholeOrOne)" : "RPE \(low.wholeOrOne)–\(high.wholeOrOne)")
        }
        return parts.joined(separator: " · ")
    }

    private static func shortDate(_ iso: String) -> String {
        guard let date = dateFormatter.date(from: iso) else { return iso }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - Last ab work

    /// The most recent Cardio+Abs day that carried strength sets.
    private func loadLastAbs() async {
        do {
            let sessions: [WorkoutSession] = try await SupabaseClient.shared.fetch(
                "workout_sessions",
                query: ["type": "eq.\(sessionType)", "date": "lt.\(Self.todayString())"],
                order: "date.desc",
                limit: 4
            )
            for session in sessions {
                guard let id = session.id else { continue }
                let sets = (try? await workoutService.fetchSets(sessionId: id)) ?? []
                let work = sets.filter { !($0.notes ?? "").contains(entryTag) && $0.isWarmup != true }
                guard !work.isEmpty else { continue }
                var names: [String] = []
                for set in work where !names.contains(set.exercise) { names.append(set.exercise) }
                let rpes = work.compactMap(\.actualRpe)
                lastAbs = AbsRecap(date: session.date, exercises: names, sets: work.count,
                                   minutes: Self.spanMinutes(work),
                                   rpeLow: rpes.min(), rpeHigh: rpes.max())
                return
            }
        } catch {
            // A missing recap is not an error the athlete needs; the section
            // reads as a first session.
        }
    }

    // MARK: - Session bootstrapping

    /// Finds today's in-progress session for this type (if any) and re-uses it
    /// so multiple entries don't fragment into separate session rows. Creates
    /// a fresh session when nothing exists yet.
    private func loadTodaysSession() async {
        isLoadingSession = true
        defer { isLoadingSession = false }

        do {
            let today = Self.todayString()
            let existing: [WorkoutSession] = try await SupabaseClient.shared.fetch(
                "workout_sessions",
                query: [
                    "date": "eq.\(today)",
                    "type": "eq.\(sessionType)",
                ],
                order: "start_time.desc",
                limit: 1
            )

            if let session = existing.first {
                todaysSession = session
                if let id = session.id {
                    let sets = (try? await workoutService.fetchSets(sessionId: id)) ?? []
                    loggedEntries = sets.filter { ($0.notes ?? "").contains(entryTag) }
                    absSets = sets.filter { !($0.notes ?? "").contains(entryTag) }
                }
            }
            // Deliberately does NOT create one. `startSession` writes an
            // `in_progress` row AND repoints the workout-state memory keys at
            // it, so merely opening this screen used to mint a session that
            // nothing ever closed — and, on a day whose type had rolled over,
            // could hijack the state belonging to a session still in progress.
            // Creation is deferred to `ensureSession()`, on the first entry.
        } catch {
            errorMessage = "Couldn't open today's session: \(error.localizedDescription)"
        }
    }

    /// Returns today's session, creating it on first use. Called from the
    /// logging paths so a session only exists once there's something in it.
    private func ensureSession() async -> WorkoutSession? {
        if let todaysSession { return todaysSession }
        do {
            let created = try await workoutService.startSession(type: sessionType)
            todaysSession = created
            return created
        } catch {
            errorMessage = "Couldn't open today's session: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - HealthKit loading

    private func loadHealthWorkouts(forceRefresh: Bool = false) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            hkError = "HealthKit isn't available on this device."
            return
        }
        isLoadingHK = true
        hkError = nil
        defer { isLoadingHK = false }

        do {
            try await health.requestAuthorization()
            healthWorkouts = try await health.fetchTodaysWorkouts()
        } catch {
            hkError = "HealthKit error: \(error.localizedDescription)"
        }
    }

    // MARK: - Logging

    private func submitManualEntry() async {
        guard let session = await ensureSession(), let id = session.id else { return }
        isLogging = true
        defer { isLogging = false }

        do {
            let entry = try await logEntry(
                sessionId: id,
                exercise: selectedActivity,
                minutes: durationMinutes,
                rpe: intensity,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            loggedEntries.append(entry)
            notes = ""
            await closeSessionIfNothingFollows(id)
        } catch {
            errorMessage = "Couldn't save entry: \(error.localizedDescription)"
        }
    }

    private func importWorkout(_ workout: HKWorkout, displayName: String, minutes: Int) async {
        guard let session = await ensureSession(), let id = session.id else { return }
        isLogging = true
        defer { isLogging = false }

        let kcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let note = "hk:\(workout.uuid.uuidString)" + (kcal.map { " · \(Int($0))kcal" } ?? "")

        do {
            let entry = try await logEntry(
                sessionId: id,
                exercise: displayName,
                minutes: minutes,
                rpe: nil,
                notes: note
            )
            loggedEntries.append(entry)
            await closeSessionIfNothingFollows(id)
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    /// A Yoga day is over once it's logged — there is no resistance work to
    /// follow, and nothing else ever marks the row complete, so it sat in
    /// history as `in_progress` indefinitely. Cardio+Abs is left open on
    /// purpose: the ab work comes next and logs into the same day.
    private func closeSessionIfNothingFollows(_ id: UUID) async {
        guard sessionType == "Yoga" else { return }
        try? await workoutService.completeSession(id: id)
    }

    private func logEntry(
        sessionId: UUID,
        exercise: String,
        minutes: Int,
        rpe: Double?,
        notes: String
    ) async throws -> WorkoutSet {
        let setNumber = loggedEntries.count + 1
        let tag = entryTag
        let combinedNotes = notes.isEmpty ? tag : "\(tag) · \(notes)"

        let today = Self.todayString()
        let now = ISO8601DateFormatter().string(from: Date())

        var body: [String: Any] = [
            "workout_session_id": sessionId.uuidString,
            "date": today,
            "exercise": PrescriptionParser.normalizeExerciseName(exercise),
            "set_number": setNumber,
            "actual_weight_kg": 0,
            "actual_reps": minutes,
            "is_warmup": false,
            "notes": combinedNotes,
            "logged_at": now,
        ]
        if let rpe {
            body["actual_rpe"] = rpe
        }

        return try await SupabaseClient.shared.insertAndDecode("workout_sets", body: body)
    }

    // MARK: - Formatting helpers

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func todayString() -> String {
        dateFormatter.string(from: Date())
    }

    // MARK: - HKWorkoutActivityType display

    private static func displayName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .rowing: return "Rowing"
        case .swimming: return "Swimming"
        case .boxing, .kickboxing: return "Boxing"
        case .stairs, .stairClimbing: return "Stairs"
        case .elliptical: return "Elliptical"
        case .traditionalStrengthTraining: return "Strength"
        case .functionalStrengthTraining: return "Functional"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .flexibility: return "Flexibility"
        case .jumpRope: return "Jump Rope"
        case .hiking: return "Hiking"
        case .highIntensityIntervalTraining: return "HIIT"
        case .mixedCardio: return "Mixed Cardio"
        case .coreTraining: return "Core"
        case .mindAndBody: return "Mind & Body"
        default: return "Workout"
        }
    }
}
