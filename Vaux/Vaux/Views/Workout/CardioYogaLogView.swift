// CardioYogaLogView.swift
// Vaux
//
// Logging surface for sessions that don't fit the sets/reps/weight mould:
// Cardio+Abs (variable cardio + ab work) and Yoga. Supports pulling today's
// Apple Watch workouts from HealthKit and manual entry for activities not
// captured there (stairs, a mixed boxing session, etc.).

import SwiftUI
import HealthKit

struct CardioYogaLogView: View {
    let sessionType: String
    /// Closure invoked when the user taps "Log abs exercise" on a Cardio+Abs
    /// day. Flips the parent view into the regular strength logging flow.
    var onStartStrengthSession: (() -> Void)? = nil

    @State private var healthWorkouts: [HKWorkout] = []
    @State private var isLoadingHK = false
    @State private var hkError: String?

    @State private var todaysSession: WorkoutSession?
    @State private var loggedEntries: [WorkoutSet] = []
    @State private var isLoadingSession = true
    @State private var errorMessage: String?

    @State private var selectedActivity: String
    @State private var durationMinutes: Int = 30
    @State private var intensity: Double = 7.0
    @State private var notes: String = ""
    @State private var isLogging = false

    private let workoutService = WorkoutService()
    private let health = HealthKitManager.shared

    init(sessionType: String, onStartStrengthSession: (() -> Void)? = nil) {
        self.sessionType = sessionType
        self.onStartStrengthSession = onStartStrengthSession
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

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader

                if let error = errorMessage {
                    errorStrip(error)
                }

                appleWatchSection

                manualEntrySection

                if !loggedEntries.isEmpty {
                    loggedEntriesSection
                }

                if isCardioAbs {
                    absCallToAction
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .task {
            await loadOrCreateSession()
            await loadHealthWorkouts()
        }
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        let accent = Color.forSession(sessionType)
        let gradient = Gradients.forSession(sessionType)
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Today's session")
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(gradient)
                        .frame(width: 52, height: 52)
                    Image(systemName: isYoga ? "figure.mind.and.body" : "heart.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionType)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(isYoga ? "Mobility · Stretching" : "Zone 2 · Core")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if isLoadingSession {
                HStack(spacing: 8) {
                    ProgressView().tint(accent).scaleEffect(0.7)
                    Text("Opening today's session…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
    }

    // MARK: - Apple Watch import

    private var appleWatchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "applewatch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                Text("APPLE WATCH")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1.0)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button {
                    Haptic.light()
                    Task { await loadHealthWorkouts(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingHK)
            }

            if isLoadingHK {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.textSecondary).scaleEffect(0.7)
                    Text("Reading today's workouts…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if let err = hkError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recoveryRed)
            } else if healthWorkouts.isEmpty {
                Text("No workouts recorded on your Watch today. Record one or log manually below.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(healthWorkouts, id: \.uuid) { workout in
                        healthWorkoutRow(workout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private func healthWorkoutRow(_ workout: HKWorkout) -> some View {
        let name = Self.displayName(for: workout.workoutActivityType)
        let minutes = Int((workout.duration / 60).rounded())
        let start = Self.timeFormatter.string(from: workout.startDate)
        let alreadyImported = loggedEntries.contains { set in
            (set.notes ?? "").contains(workout.uuid.uuidString)
        }
        return HStack(spacing: 12) {
            Image(systemName: Self.icon(for: workout.workoutActivityType))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.surface))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(minutes) min · \(start)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()

            Button {
                Haptic.medium()
                Task { await importWorkout(workout, displayName: name, minutes: minutes) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: alreadyImported ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(alreadyImported ? "Imported" : "Import")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(alreadyImported ? Color.recoveryGreen : Color.signalInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(alreadyImported ? Color.recoveryGreen.opacity(0.12) : Color.signal)
                )
            }
            .buttonStyle(.plain)
            .disabled(alreadyImported || isLogging || todaysSession == nil)
        }
    }

    // MARK: - Manual entry

    private var manualEntrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOG \(isYoga ? "YOGA" : "CARDIO") MANUALLY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(1.0)
                .foregroundStyle(Color.textSecondary)

            // Activity picker — horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(activityOptions, id: \.self) { option in
                        activityChip(option)
                    }
                }
            }

            // Duration stepper
            HStack {
                Text("Duration")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button {
                    Haptic.light()
                    durationMinutes = max(5, durationMinutes - 5)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)

                Text("\(durationMinutes) min")
                    .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 70)

                Button {
                    Haptic.light()
                    durationMinutes = min(180, durationMinutes + 5)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
            }

            // Intensity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Intensity")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text("RPE \(intensity.oneDecimal)")
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.forSession(sessionType))
                }
                Slider(value: $intensity, in: 1...10, step: 0.5)
                    .tint(Color.forSession(sessionType))
            }

            // Notes
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.surface)
                )
                .lineLimit(1...3)

            // Submit
            Button {
                Haptic.medium()
                Task { await submitManualEntry() }
            } label: {
                HStack(spacing: 6) {
                    if isLogging {
                        ProgressView().tint(.black).scaleEffect(0.8)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text("Log entry")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Gradients.forSession(sessionType))
                )
            }
            .disabled(isLogging || todaysSession == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private func activityChip(_ option: String) -> some View {
        let isSelected = option == selectedActivity
        let accent = Color.forSession(sessionType)
        return Button {
            Haptic.selection()
            selectedActivity = option
        } label: {
            Text(option)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.signalInk : Color.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? accent : Color.surface)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Color.cardBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logged entries

    private var loggedEntriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TODAY'S ENTRIES")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1.0)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text("\(loggedEntries.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            VStack(spacing: 8) {
                ForEach(Array(loggedEntries.enumerated()), id: \.offset) { _, entry in
                    loggedEntryRow(entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard(padding: 14, cornerRadius: 16)
    }

    private func loggedEntryRow(_ entry: WorkoutSet) -> some View {
        let minutes = entry.actualReps ?? 0
        let rpe = entry.actualRpe
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.recoveryGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.exercise)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(minutes) min\(rpe.map { " · RPE \($0.oneDecimal)" } ?? "")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.surface)
        )
    }

    // MARK: - Abs CTA

    private var absCallToAction: some View {
        Button {
            Haptic.medium()
            onStartStrengthSession?()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.signal.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "figure.core.training")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.signal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log abs exercises")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Switch to strength mode for planks, crunches, etc.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.recoveryRed)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.recoveryRed.opacity(0.1))
        )
    }

    // MARK: - Session bootstrapping

    /// Finds today's in-progress session for this type (if any) and re-uses it
    /// so multiple entries don't fragment into separate session rows. Creates
    /// a fresh session when nothing exists yet.
    private func loadOrCreateSession() async {
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
                }
            } else {
                todaysSession = try await workoutService.startSession(type: sessionType)
            }
        } catch {
            errorMessage = "Couldn't open today's session: \(error.localizedDescription)"
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
        guard let session = todaysSession, let id = session.id else {
            errorMessage = "Session not ready yet — try again in a moment."
            return
        }
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
        } catch {
            errorMessage = "Couldn't save entry: \(error.localizedDescription)"
        }
    }

    private func importWorkout(_ workout: HKWorkout, displayName: String, minutes: Int) async {
        guard let session = todaysSession, let id = session.id else {
            errorMessage = "Session not ready yet — try again in a moment."
            return
        }
        isLogging = true
        defer { isLogging = false }

        let kcal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
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
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
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

    private static func icon(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "figure.run"
        case .walking, .hiking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .rowing: return "figure.rower"
        case .swimming: return "figure.pool.swim"
        case .boxing, .kickboxing: return "figure.boxing"
        case .stairs, .stairClimbing: return "figure.stairs"
        case .elliptical: return "figure.elliptical"
        case .yoga, .mindAndBody: return "figure.mind.and.body"
        case .pilates: return "figure.pilates"
        case .flexibility: return "figure.flexibility"
        case .jumpRope: return "figure.jumprope"
        case .highIntensityIntervalTraining: return "figure.highintensity.intervaltraining"
        case .coreTraining: return "figure.core.training"
        case .mixedCardio: return "heart.circle.fill"
        default: return "figure.mixed.cardio"
        }
    }
}
