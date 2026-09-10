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

    /// "1h 22": time under the bar, summed across the day's sessions.
    ///
    /// Summed, not spanned. A Cardio+Abs day is two rows — the Apple Watch
    /// import from the morning and the abs session in the evening — and the
    /// span from the first start to the last end read "8h 17" for about an
    /// hour of training.
    var durationLine: String? {
        let mins = sessions.reduce(0) { total, row in
            guard let s = row.startTime.flatMap({ SessionEntry.parse($0) }),
                  let e = row.endTime.flatMap({ SessionEntry.parse($0) }), e > s else { return total }
            return total + Int(e.timeIntervalSince(s) / 60)
        }
        guard mins > 0 else { return nil }
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(String(format: "%02d", mins % 60))"
    }

    /// Working-set tonnage: weight × reps over every set that is not a
    /// warm-up. Computed from the sets rather than read off the session row,
    /// because the row's `tonnage_kg` has meant two different things: the
    /// backend and the in-workout counter exclude warm-ups, the app's END
    /// summed every set. An August Pull read 7.5T above a set list that adds
    /// to 5.4T; a September one read 6.4T and matched. Same lifting, two
    /// numbers. This is the one the athlete watched climb during the session.
    ///
    /// A bodyweight movement's load is the plate plus the athlete's share of
    /// bodyweight on that date (BodyweightLoad), so a set of dips at
    /// bodyweight is a set of work, not a zero.
    static func workingTonnage(_ sets: [WorkoutSet], weighIns: WeighInRecord = .empty) -> Double {
        sets.filter { $0.isWarmup != true }
            .reduce(0) { total, set in
                let load = BodyweightLoad.effective(set.actualWeightKg ?? 0, exercise: set.exercise, bodyweight: weighIns.kg(on: set.date))
                return total + load * Double(set.actualReps ?? 0)
            }
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
    /// "TOP · LEG PRESS 230 × 12 · SEATED LEG CURL 100 × 14": the two
    /// strongest sets of the day by estimated 1RM. It was the two biggest
    /// by weight × reps, which made a back-off of 185 × 15 the "top" over the
    /// 230 × 12 it followed, and a Pull day's TOP line showed both back-offs.
    var summaryLine: String {
        func e1rm(_ s: WorkoutSet) -> Double {
            WorkoutService.epley1RM(weight: s.actualWeightKg ?? 0, reps: s.actualReps ?? 0)
        }
        let tops: [(String, Double, Int, Double)] = exercises.compactMap { name, sets in
            guard let best = sets.filter({ ($0.actualWeightKg ?? 0) > 0 }).max(by: { e1rm($0) < e1rm($1) }) else { return nil }
            return (name, best.actualWeightKg ?? 0, best.actualReps ?? 0, e1rm(best))
        }
        let ranked = tops.sorted { $0.3 > $1.3 }.prefix(2)
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

    func rebuild(sets: [WorkoutSet], sessions: [WorkoutSession], calendar: BlockCalendar,
                 weighIns: WeighInRecord = .empty) {
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
                                tonnage: SessionEntry.workingTonnage(allSets, weighIns: weighIns),
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


// MARK: - Why a week moved

/// The change from one week's sessions to the comparable week's, split into
/// the three things that can move tonnage: sets added or dropped, load, and
/// reps. Tonnage alone rewards more reps at lighter loads and punishes a
/// session cut short; this says which one happened.
struct WeekChange {
    let againstLabel: String
    let setsDelta: Int
    let loadPct: Double?
    let repsPct: Double?

    var line: String {
        var parts: [String] = []
        if setsDelta != 0 { parts.append("\(abs(setsDelta)) \(setsDelta < 0 ? "fewer" : "more") set\(abs(setsDelta) == 1 ? "" : "s")") }
        if let l = loadPct, abs(l) >= 0.5 { parts.append("loads \(Editorial.signedPct(l, decimals: 0))") }
        if let r = repsPct, abs(r) >= 0.5 { parts.append("reps \(Editorial.signedPct(r, decimals: 0))") }
        if parts.isEmpty { parts.append("same sets, loads and reps") }
        return "VS \(againstLabel.uppercased()) · " + parts.joined(separator: " · ").uppercased()
    }
}

extension TrainingBlockViewModel {
    /// This week's sessions against the previous week of the block (or last
    /// block's final loading week when this is week 1), matched by session
    /// type and then by exercise. Per exercise: the set-count difference, and
    /// on the sets both weeks had, the mean load and mean reps change.
    var weekChange: WeekChange? {
        let now = current
        let against: BlockPosition
        let label: String
        if now.week > 1 {
            against = BlockPosition(block: now.block, week: now.week - 1)
            label = "W\(now.week - 1)"
        } else {
            against = BlockPosition(block: now.block - 1, week: Config.peakWeek)
            label = "last block W\(Config.peakWeek)"
        }
        let mine = entries.filter { $0.position == now }
        let theirs = entries.filter { $0.position == against }
        guard !mine.isEmpty, !theirs.isEmpty else { return nil }
        // Only session types both weeks contain, so a week with Legs still to
        // come is not read as having dropped every leg set.
        let types = Set(mine.map(\.type)).intersection(theirs.map(\.type))
        guard !types.isEmpty else { return nil }
        func byExercise(_ es: [SessionEntry]) -> [String: [WorkoutSet]] {
            var out: [String: [WorkoutSet]] = [:]
            for e in es where types.contains(e.type) {
                for (name, sets) in e.exercises { out[name, default: []] += sets }
            }
            return out
        }
        let a = byExercise(mine), b = byExercise(theirs)
        var setsDelta = 0
        var loadRatios: [Double] = [], repRatios: [Double] = []
        for name in Set(a.keys).union(b.keys) {
            let x = a[name] ?? [], y = b[name] ?? []
            setsDelta += x.count - y.count
            guard !x.isEmpty, !y.isEmpty else { continue }
            let lx = x.map { $0.actualWeightKg ?? 0 }.reduce(0, +) / Double(x.count)
            let ly = y.map { $0.actualWeightKg ?? 0 }.reduce(0, +) / Double(y.count)
            let rx = x.map { Double($0.actualReps ?? 0) }.reduce(0, +) / Double(x.count)
            let ry = y.map { Double($0.actualReps ?? 0) }.reduce(0, +) / Double(y.count)
            if ly > 0 { loadRatios.append(lx / ly) }
            if ry > 0 { repRatios.append(rx / ry) }
        }
        let loadPct = loadRatios.isEmpty ? nil : (loadRatios.reduce(0, +) / Double(loadRatios.count) - 1) * 100
        let repsPct = repRatios.isEmpty ? nil : (repRatios.reduce(0, +) / Double(repRatios.count) - 1) * 100
        return WeekChange(againstLabel: label, setsDelta: setsDelta, loadPct: loadPct, repsPct: repsPct)
    }
}
