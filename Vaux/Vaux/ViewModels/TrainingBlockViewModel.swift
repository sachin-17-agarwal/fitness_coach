// TrainingBlockViewModel.swift
// Vaux
//
// The Training tab's unit is the block: what was lifted this block, how the
// four-week wave actually landed against the plan (and against the block
// before), and every session in the window with its sets ready to unfold.

import Foundation
import Observation

struct WeekTonnage: Identifiable, Hashable {
    let position: BlockPosition
    let tonnage: Double
    let sessions: Int
    var id: BlockPosition { position }
}

struct SessionEntry: Identifiable {
    let id: String
    let date: String
    let type: String
    let sessions: [WorkoutSession]
    let position: BlockPosition?
    let tonnage: Double
    let sets: [WorkoutSet]
    let isOpen: Bool

    var workingSets: [WorkoutSet] { sets.filter { $0.isWarmup != true } }
    var setCount: Int {
        workingSets.filter { s in
            let n = (s.notes ?? "").lowercased()
            return !n.hasPrefix("cardio") && !n.hasPrefix("yoga")
        }.count
    }

    /// "1h 22" from the earliest start to the latest end.
    var durationLine: String? {
        let starts = sessions.compactMap { $0.startTime.flatMap({ SessionEntry.parse($0) }) }
        let ends = sessions.compactMap { $0.endTime.flatMap({ SessionEntry.parse($0) }) }
        guard let s = starts.min(), let e = ends.max(), e > s else { return nil }
        let mins = Int(e.timeIntervalSince(s) / 60)
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(String(format: "%02d", mins % 60))"
    }

    /// Exercises in the order first logged, each with its working sets.
    var exercises: [(name: String, sets: [WorkoutSet])] {
        var order: [String] = []
        var groups: [String: [WorkoutSet]] = [:]
        for s in workingSets.sorted(by: { ($0.loggedAt ?? "") < ($1.loggedAt ?? "") }) {
            let key = PrescriptionParser.normalizeExerciseName(s.exercise)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// One line for the collapsed row: the two heaviest top sets.
    var summaryLine: String {
        let tops: [(String, Double, Int)] = exercises.compactMap { name, sets in
            guard let best = sets.filter({ ($0.actualWeightKg ?? 0) > 0 }).max(by: { ($0.actualWeightKg ?? 0) * Double($0.actualReps ?? 0) < ($1.actualWeightKg ?? 0) * Double($1.actualReps ?? 0) }) else { return nil }
            return (name, best.actualWeightKg ?? 0, best.actualReps ?? 0)
        }
        let ranked = tops.sorted { $0.1 * Double($0.2) > $1.1 * Double($1.2) }.prefix(2)
        if ranked.isEmpty {
            let cardio = workingSets.first { ($0.notes ?? "").lowercased().hasPrefix("cardio") }
            if let c = cardio, let mins = c.actualReps { return "CARDIO \(mins) MIN" }
            return sets.isEmpty ? "NO SETS LOGGED" : "\(workingSets.count) SETS"
        }
        return "TOP · " + ranked.map { "\($0.0.uppercased()) \(SessionEntry.kg($0.1)) × \($0.2)" }.joined(separator: " · ")
    }

    static func kg(_ w: Double) -> String { w == w.rounded() ? String(Int(w)) : String(format: "%.1f", w) }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
}

@Observable
final class TrainingBlockViewModel {
    private(set) var entries: [SessionEntry] = []
    private(set) var currentWave: [WeekTonnage] = []
    private(set) var previousWave: [WeekTonnage] = []
    private(set) var blockTonnage: Double = 0
    private(set) var blockSessions: Int = 0
    private(set) var blockSets: Int = 0
    private(set) var previousBlockTonnage: Double = 0
    private(set) var heaviestWeekEver: Double = 0
    private(set) var current: BlockPosition = BlockPosition(block: 0, week: 1)

    static let windowDays = 90

    func rebuild(sets: [WorkoutSet], sessions: [WorkoutSession], calendar: BlockCalendar) {
        current = calendar.current
        let setsBySession: [UUID: [WorkoutSet]] = Dictionary(grouping: sets.filter { $0.workoutSessionId != nil }, by: { $0.workoutSessionId! })

        // One entry per training day + type, newest first.
        var order: [String] = []
        var groups: [String: [WorkoutSession]] = [:]
        for s in sessions.sorted(by: { a, b in a.date != b.date ? a.date > b.date : (a.startTime ?? "") > (b.startTime ?? "") }) {
            let key = "\(s.date)|\(s.type)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }
        entries = order.compactMap { key in
            guard let rows = groups[key], let first = rows.first else { return nil }
            let allSets = rows.flatMap { $0.id.flatMap { setsBySession[$0] } ?? [] }
            return SessionEntry(id: key, date: first.date, type: first.type, sessions: rows,
                                position: calendar.position(of: first),
                                tonnage: rows.reduce(0) { $0 + ($1.tonnageKg ?? 0) },
                                sets: allSets,
                                isOpen: rows.contains { !SessionStatus($0.status).isFinished })
        }

        func wave(_ block: Int) -> [WeekTonnage] {
            (1...Config.weeksPerBlock).map { w in
                let pos = BlockPosition(block: block, week: w)
                let mine = entries.filter { $0.position == pos }
                return WeekTonnage(position: pos, tonnage: mine.reduce(0) { $0 + $1.tonnage }, sessions: mine.count)
            }
        }
        currentWave = wave(current.block)
        previousWave = wave(current.block - 1)
        let thisBlock = entries.filter { $0.position?.block == current.block }
        blockTonnage = thisBlock.reduce(0) { $0 + $1.tonnage }
        blockSessions = thisBlock.count
        blockSets = thisBlock.reduce(0) { $0 + $1.setCount }
        previousBlockTonnage = previousWave.reduce(0) { $0 + $1.tonnage }
        // Heaviest single week across everything placed in the window.
        var byWeek: [BlockPosition: Double] = [:]
        for e in entries { if let p = e.position { byWeek[p, default: 0] += e.tonnage } }
        heaviestWeekEver = byWeek.values.max() ?? 0
    }

    /// Tonnage so far against last block at the same point: each session
    /// this block has trained is matched to the same-numbered session of its
    /// type in the previous block (second Push against second Push), so a
    /// Wednesday is never judged against a finished week. Falls back to the
    /// k-th session overall when the type has no counterpart.
    var blockDeltaPct: Double? {
        guard previousBlockTonnage > 0, let prevSame = sameToDateTonnage, prevSame > 0 else { return nil }
        return (blockTonnage - prevSame) / prevSame * 100
    }

    /// Last block's tonnage through the same sessions this block has done.
    private var sameToDateTonnage: Double? {
        let thisBlock = entries.filter { $0.position?.block == current.block }.sorted { $0.date < $1.date }
        let lastBlock = entries.filter { $0.position?.block == current.block - 1 }.sorted { $0.date < $1.date }
        guard !thisBlock.isEmpty, !lastBlock.isEmpty else { return nil }
        var seen: [String: Int] = [:]
        var total = 0.0
        var matched = 0
        for (k, e) in thisBlock.enumerated() {
            let n = seen[e.type, default: 0]
            seen[e.type] = n + 1
            let sameType = lastBlock.filter { $0.type == e.type }
            if n < sameType.count { total += sameType[n].tonnage; matched += 1 }
            else if k < lastBlock.count { total += lastBlock[k].tonnage; matched += 1 }
        }
        return matched > 0 ? total : nil
    }

    var peakWeekTonnage: Double? { currentWave.first { $0.position.isPeak && $0.tonnage > 0 }?.tonnage }

    static func diagnosis(_ vm: TrainingBlockViewModel) -> AttributedString {
        guard vm.blockSessions > 0 else {
            return .editorial([("No sessions placed in this block yet. The wave fills in as the rotation completes.", false)])
        }
        var parts: [(String, Bool)] = []
        if let peak = vm.peakWeekTonnage {
            let record = peak >= vm.heaviestWeekEver - 0.5
            parts.append(("Peak week landed at ", false)); parts.append((Editorial.tonnage(peak), true))
            parts.append((record ? ", the heaviest week on record. " : ". ", false))
            let w4 = vm.currentWave.first { $0.position.isDeload }?.tonnage ?? 0
            if vm.current.isDeload {
                parts.append((w4 > 0 && w4 < peak ? "Deload is on plan: same loads, two reps off." : "Deload week is under way.", false))
            }
        } else {
            let n = vm.blockSessions
            parts.append(("Week \(vm.current.week) of \(Config.weeksPerBlock), \(n) session\(n == 1 ? "" : "s") in. ", false))
            if let d = vm.blockDeltaPct {
                parts.append(("Running ", false)); parts.append((Editorial.signedPct(d, decimals: 0), true))
                parts.append((" against the same \(n == 1 ? "session" : "\(n) sessions") of last block — the week's total settles once the week is done.", false))
            }
        }
        return .editorial(parts)
    }
}
