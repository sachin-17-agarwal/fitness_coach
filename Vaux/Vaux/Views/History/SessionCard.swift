// SessionCard.swift
// Vaux
//
// Collapsible workout session card — status badge, tonnage, and grouped sets.

import SwiftUI

struct SessionCard: View {
    /// Every session row for one date and type. Usually one, but a
    /// Cardio+Abs day is logged as two — the cardio is finished before the
    /// ab work is started, so `startOrResumeWorkout` finds no in-progress
    /// session to rejoin and opens a second row. They are one training day
    /// and are shown as one card, with the sets and tonnage combined.
    let sessions: [WorkoutSession]

    /// Bumped by the parent screen every time it reloads.
    ///
    /// The card fetches its sets once, on first expand, and caches them in
    /// `@State` keyed on the card's identity ("date|type") — which is stable
    /// across reloads. Nothing invalidated that cache, so a card opened
    /// part-way through a workout kept showing the snapshot it took then
    /// while the tonnage in its own header refreshed from the session row
    /// around it: a Pull day reading 7850kg over a list of three sets.
    /// Watching this token is what lets a pull-to-refresh reach inside an
    /// already-open card.
    let reloadToken: Int

    init(sessions: [WorkoutSession], reloadToken: Int = 0, onSetsChanged: @escaping () -> Void = {}) {
        self.sessions = sessions
        self.reloadToken = reloadToken
        self.onSetsChanged = onSetsChanged
    }

    init(session: WorkoutSession, reloadToken: Int = 0, onSetsChanged: @escaping () -> Void = {}) {
        self.sessions = [session]
        self.reloadToken = reloadToken
        self.onSetsChanged = onSetsChanged
    }

    /// Called after a set is corrected or removed so the surrounding screen
    /// can refresh totals it derived from the old numbers.
    var onSetsChanged: () -> Void = {}

    @State private var sets: [WorkoutSet] = []
    @State private var hasLoadedSets = false
    /// Set when a fetch came back short — either it threw outright, or one of
    /// a multi-row day's sessions failed while the others succeeded. Without
    /// it, `try?` swallowed the error and the partial result was cached as if
    /// it were the whole session, with no path back to a complete list.
    @State private var loadFailed = false
    @State private var isExpanded = false
    /// The set currently open for correction, if any.
    @State private var editingSet: WorkoutSet?
    /// Set once an edit lands, so the header stops showing the stale
    /// denormalised total while the parent list is still holding old rows.
    @State private var recalculatedTonnage: Double?

    private let workoutService = WorkoutService()

    /// Representative row for the day's date, type and icon.
    private var session: WorkoutSession { sessions[0] }

    private var combinedTonnage: Double {
        if let recalculatedTonnage { return recalculatedTonnage }
        return sessions.reduce(0) { $0 + ($1.tonnageKg ?? 0) }
    }

    /// A day counts as still in progress while any of its rows is.
    private var combinedStatus: SessionStatus {
        sessions.contains { !SessionStatus($0.status).isFinished } ? .open : .finished
    }

    private var accent: Color { Color.forSession(session.type) }

    private var sessionIcon: String {
        switch session.type {
        case "Pull": return "arrow.down.to.line"
        case "Push": return "dumbbell.fill"
        case "Legs": return "figure.strengthtraining.functional"
        case "Cardio+Abs": return "heart.circle.fill"
        case "Yoga": return "figure.mind.and.body"
        default: return "figure.strengthtraining.traditional"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                if !sets.isEmpty {
                    setsList
                    if loadFailed { retryNotice }
                } else if loadFailed {
                    retryNotice
                } else if hasLoadedSets {
                    // Distinct from the loading state: deleting the last set
                    // used to leave the spinner up forever, because empty and
                    // not-yet-fetched looked identical from here.
                    Text("No sets logged for this session.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textTertiary)
                        .padding(.top, 4)
                } else {
                    HStack {
                        ProgressView().tint(Color.textSecondary).scaleEffect(0.8)
                        Text("Loading sets…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ink2.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), accent.opacity(0.25), Color.line],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.light()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
            if isExpanded && (sets.isEmpty || loadFailed) {
                Task { await loadSets() }
            }
        }
        .onChange(of: reloadToken) { _, _ in
            // The freshly fetched session rows carry the authoritative
            // tonnage, so the local override from an edit has done its job
            // and would only keep an older number alive past the refresh.
            recalculatedTonnage = nil
            // An open card re-reads immediately so the rows on screen match
            // the header above them. A closed one just drops its cache, so
            // the next expand fetches rather than replaying an old snapshot.
            if isExpanded {
                Task { await loadSets() }
            } else {
                sets = []
                hasLoadedSets = false
                loadFailed = false
            }
        }
        .sheet(item: $editingSet) { target in
            EditSetSheet(
                set: target,
                onSave: { weight, reps, rpe in
                    Task { await applyEdit(target, weight: weight, reps: reps, rpe: rpe) }
                },
                onDelete: {
                    Task { await applyDelete(target) }
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: sessionIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.type)
                    .font(.uiStrong)
                    .foregroundStyle(Color.fg0)
                Text(prettyDate(session.date))
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.fg2)
            }

            Spacer()

            if combinedTonnage > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(combinedTonnage.weightString)
                        .font(.numSM)
                        .foregroundStyle(Color.fg0)
                    Text("TONNAGE")
                        .font(.eyebrowSmall)
                        .kerning(1.0)
                        .foregroundStyle(Color.fg2)
                }
            }

            statusBadge(combinedStatus)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.fg2)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    /// A Button rather than plain text, for the same reason the set rows are:
    /// the card's own `onTapGesture` would otherwise take the tap and simply
    /// collapse the card, so "tap to retry" would do anything but.
    ///
    /// Ember, not amber, and deliberately: `LoadErrorState` and
    /// `LoadErrorBanner` already established ember as the colour of a failed
    /// load, while `statusBadge` a few lines below uses amber for a session
    /// still in progress. Amber here would put two meanings on one colour
    /// inside a single card.
    private var retryNotice: some View {
        Button {
            Haptic.light()
            Task { await loadSets() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(sets.isEmpty ? "Couldn't load sets — tap to retry."
                                  : "This list may be incomplete — tap to retry.")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.ember)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    private var setsList: some View {
        // Group case-insensitively so "Leg Press" and "Leg press" collapse
        // into one block. Keep the first-seen display form (and prefer a
        // non-warmup label when one exists) to avoid an all-lowercase header.
        var order: [String] = []
        var display: [String: String] = [:]
        var buckets: [String: [WorkoutSet]] = [:]
        for set in sets {
            let key = set.exercise.lowercased()
            if buckets[key] == nil {
                order.append(key)
                display[key] = set.exercise
                buckets[key] = []
            } else if set.isWarmup != true, display[key]?.first?.isLowercase == true {
                display[key] = set.exercise
            }
            buckets[key]?.append(set)
        }

        // Number warm-ups and working sets in separate sequences. The stored
        // set_number is a single running count per exercise, so three warm-ups
        // pushed the actual working sets to "#4" and "#5" — the numbers the
        // athlete cares about read as if two sets were missing.
        var numbered: [String: [(label: String, set: WorkoutSet)]] = [:]
        for key in order {
            var rows: [(label: String, set: WorkoutSet)] = []
            var warmups = 0
            var working = 0
            for s in buckets[key] ?? [] {
                if s.isWarmup == true {
                    warmups += 1
                    rows.append((label: "W\(warmups)", set: s))
                } else {
                    working += 1
                    rows.append((label: "\(working)", set: s))
                }
            }
            numbered[key] = rows
        }

        return VStack(alignment: .leading, spacing: 12) {
            Divider().background(Color.cardBorder)

            ForEach(order, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(display[key] ?? key.capitalized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array((numbered[key] ?? []).enumerated()), id: \.offset) { _, entry in
                            // A Button rather than a tap gesture: the whole
                            // card already carries an `onTapGesture` for
                            // expand/collapse, and a button reliably takes the
                            // tap ahead of it instead of racing it.
                            if isEditable(entry.set) {
                                Button {
                                    Haptic.light()
                                    editingSet = entry.set
                                } label: {
                                    setRow(entry.set, label: entry.label)
                                }
                                .buttonStyle(.plain)
                            } else {
                                setRow(entry.set, label: entry.label)
                            }
                        }
                    }
                }
            }
        }
    }

    private func setRow(_ set: WorkoutSet, label: String) -> some View {
        let isWarmup = set.isWarmup == true
        let kind = entryKind(set)
        return HStack(spacing: 10) {
            Text(label)
                .font(.eyebrowSmall)
                .foregroundStyle(isWarmup ? Color.fg2.opacity(0.7) : Color.fg2)
                .frame(width: 26, alignment: .leading)

            switch kind {
            case .cardio, .yoga:
                if let minutes = set.actualReps {
                    Text("\(minutes) min")
                        .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.fg0)
                }
                Text(kind == .yoga ? "YOGA" : "CARDIO")
                    .font(.eyebrowSmall)
                    .kerning(0.5)
                    .foregroundStyle(Color.forSession(kind == .yoga ? "Yoga" : "Cardio+Abs"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.ink3))
            case .strength:
                if let w = set.actualWeightKg, let r = set.actualReps {
                    Text("\(ExerciseCatalog.setWeightLabel(w, exercise: set.exercise)) × \(r)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                        .foregroundStyle(isWarmup ? Color.fg1 : Color.fg0)
                }

                if isWarmup {
                    Text("WARM-UP")
                        .font(.eyebrowSmall)
                        .kerning(0.5)
                        .foregroundStyle(Color.fg2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.ink3))
                }
            }

            Spacer()
            if let rpe = set.actualRpe {
                Text("RPE \(rpe.oneDecimal)")
                    .font(.eyebrowSmall)
                    .foregroundStyle(Color.fg1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.ink3))
            }
        }
    }

    /// Only strength sets are editable. `EditSetSheet` steps weight, reps and
    /// RPE, none of which describe a cardio or yoga entry — those store minutes
    /// in `actual_reps` and would be nonsense to edit through it. A set with no
    /// id can't be addressed in the database either.
    private func isEditable(_ set: WorkoutSet) -> Bool {
        set.id != nil && entryKind(set) == .strength
    }

    private func applyEdit(_ set: WorkoutSet, weight: Double, reps: Int, rpe: Double?) async {
        guard let id = set.id else { return }
        _ = try? await workoutService.updateSet(
            id: id, weight: weight, reps: reps, rpe: set.isWarmup == true ? nil : rpe
        )
        await refreshAfterChange()
    }

    private func applyDelete(_ set: WorkoutSet) async {
        guard let id = set.id else { return }
        try? await workoutService.deleteSet(id: id)
        await refreshAfterChange()
    }

    /// Re-reads the sets, then repairs the denormalised session tonnage so the
    /// header total matches the rows listed under it. The coach needs no
    /// notification here — its context block re-reads the last 30 days from
    /// the database on every message, so a corrected row is picked up on its
    /// own the next time they speak.
    private func refreshAfterChange() async {
        await loadSets()
        for id in sessions.compactMap(\.id) {
            _ = try? await workoutService.recalculateTonnage(sessionId: id)
        }
        recalculatedTonnage = sets.reduce(0.0) { total, set in
            total + ((set.actualWeightKg ?? 0) * Double(set.actualReps ?? 0))
        }
        onSetsChanged()
    }

    private enum EntryKind { case strength, cardio, yoga }

    /// Cardio/yoga entries are tagged via the `notes` column on write
    /// (see `CardioYogaLogView`). Treat anything else as a strength set so
    /// legacy rows keep rendering as "weight × reps".
    private func entryKind(_ set: WorkoutSet) -> EntryKind {
        let note = (set.notes ?? "").lowercased()
        if note.hasPrefix("yoga") || note.contains(" yoga") { return .yoga }
        if note.hasPrefix("cardio") || note.contains(" cardio") { return .cardio }
        return .strength
    }

    /// Takes the normalised state, not the raw column. Echoing the string was
    /// how a backend-ended session came out as amber "COMPLETE" next to green
    /// "COMPLETED" ones — the same state, spelled differently.
    private func statusBadge(_ status: SessionStatus) -> some View {
        let color: Color = status.isFinished ? .mint : .amber
        return Text(status.label)
            .font(.eyebrowSmall)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.5))
    }

    private func prettyDate(_ dateString: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return dateString }
        let out = DateFormatter()
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    /// Loads every row's sets and concatenates them in session order, so a
    /// Cardio+Abs card lists the cardio entry followed by the ab work rather
    /// than splitting them across two cards.
    private func loadSets() async {
        var combined: [WorkoutSet] = []
        var failed = false
        for id in sessions.compactMap(\.id) {
            if let rows = try? await workoutService.fetchSets(sessionId: id) {
                combined += rows
            } else {
                failed = true
            }
        }

        // Never trade a list we already have for nothing. If every fetch
        // failed, keep what's on screen and flag it rather than blanking a
        // card into "No sets logged", which reads as data loss.
        if failed && combined.isEmpty && !sets.isEmpty {
            loadFailed = true
            return
        }

        sets = combined
        hasLoadedSets = true
        loadFailed = failed
    }
}
