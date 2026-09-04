// StrengthViewModel.swift
// Vaux
//
// Strength lives at the lift, never at the muscle: a "muscle 1RM" mixes
// movements that do not convert. Each lift is judged BLOCK OVER BLOCK — its
// best estimated 1RM in one block's peak week against the block before —
// because session-to-session e1RM is noise at intermediate rates of gain,
// and a deload is a phase of the wave, not a regression.
//
// Muscles then wear the state of their lifts (worst first), plus a separate
// "short on sets" state when the strength read is fine but weekly volume is
// under the band. Everything that cannot be judged says so (NO READ) rather
// than inventing a number.

import Foundation
import Observation

struct LiftBlockPoint: Hashable {
    let position: BlockPosition
    let e1rm: Double
    let weight: Double
    let reps: Int
    let rpe: Double?
}

struct LiftReport: Identifiable, Hashable {
    let name: String
    let muscle: BodyMuscle?
    let sessionType: String?
    /// Weekly best e1RM per block position (any week that had a set).
    let weekly: [BlockPosition: LiftBlockPoint]
    /// The judged block's peak value and the block before it.
    let judged: BlockPosition?
    let peak: LiftBlockPoint?
    let priorPeak: Double?
    let allTimeBest: Double
    let deltaPct: Double?
    let blocksSincePR: Int?
    let state: StrengthState
    var id: String { name }

    var bestSetLine: String {
        guard let p = peak else { return "no loaded set yet" }
        let w = p.weight == p.weight.rounded() ? String(Int(p.weight)) : String(format: "%.1f", p.weight)
        let rpe = p.rpe.map { String(format: " @%g", $0) } ?? ""
        return "best \(w) × \(p.reps)\(rpe)"
    }
}

struct MuscleReport: Identifiable, Hashable {
    let muscle: BodyMuscle
    let state: StrengthState
    /// The lift that decided the state (worst first, then heaviest).
    let drivingLift: LiftReport?
    let setsPerWeek: Double
    let band: ClosedRange<Int>
    var id: BodyMuscle { muscle }

    var stateLine: String {
        switch state {
        case .stall: return "STALLED · \(drivingLift?.blocksSincePR ?? 2) BLOCKS"
        case .drop: return "DROPPING · " + Editorial.signedPct(drivingLift?.deltaPct ?? 0)
        case .none:
            guard let lift = drivingLift, lift.peak != nil else { return "NOT TRAINED THIS BLOCK" }
            return lift.priorPeak == nil ? "FIRST BLOCK · NOTHING TO COMPARE" : "NO READ YET"
        default: return state.label
        }
    }
}

struct BalanceReport: Identifiable, Hashable {
    let title: String
    let leftName: String
    let rightName: String
    let leftValue: Double?
    let rightValue: Double?
    let band: ClosedRange<Int>
    var id: String { title }

    var ratioPct: Double? {
        guard let l = leftValue, let r = rightValue, r > 0 else { return nil }
        return l / r * 100
    }
    var verdict: String {
        guard let p = ratioPct else { return "NO READ YET" }
        if band.contains(Int(p.rounded())) { return "BALANCED" }
        return p < Double(band.lowerBound) ? "UNDER" : "OVER"
    }
}

/// One block's judgement, so the hero can be scrubbed through time.
struct BlockSnapshot: Identifiable, Hashable {
    let judged: BlockPosition
    let lifts: [LiftReport]
    let muscles: [MuscleReport]
    let medianGainPct: Double?
    /// "12 MAY – 8 JUN": the training dates this block covered.
    var dateRange: String? = nil
    var id: Int { judged.block }

    var upCount: Int { lifts.filter { $0.state == .pr || $0.state == .up }.count }
    var prCount: Int { lifts.filter { $0.state == .pr }.count }
    var stalledCount: Int { lifts.filter { $0.state == .stall || $0.state == .drop }.count }
    var judgedCount: Int { lifts.filter { $0.state != StrengthState.none }.count }
    var muscleStates: [BodyMuscle: StrengthState] {
        Dictionary(uniqueKeysWithValues: muscles.map { ($0.muscle, $0.state) })
    }
}

@Observable
final class StrengthViewModel {
    private(set) var snapshots: [BlockSnapshot] = []
    private(set) var balance: [BalanceReport] = []
    private(set) var allLiftNames: [String] = []
    private(set) var errorMessage: String?
    private(set) var hasLoadedOnce = false

    /// The block currently shown in the hero; defaults to the latest judged.
    var shownIndex: Int = 0

    var shown: BlockSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        return snapshots[min(max(0, shownIndex), snapshots.count - 1)]
    }
    var latest: BlockSnapshot? { snapshots.last }

    /// Points the hero at `block` if a snapshot for it exists.
    func show(block: Int) {
        if let i = snapshots.firstIndex(where: { $0.judged.block == block }) { shownIndex = i }
    }

    // Thresholds. One rep at 8–12 moves an Epley e1RM ~3%, and machine
    // stacks differ between gyms, so anything inside ±1% is "holding" and a
    // drop has to clear 5% before it is called one.
    static let progressPct = 1.0
    static let dropPct = -5.0
    static let stallBlocks = 2
    static let maxRepsForE1RM = 12
    static let windowDays = 16 * 7

    private static let balancePairs: [(title: String, left: [String], right: [String], band: ClosedRange<Int>)] = [
        ("ROW : CHEST PRESS", ["cable row"], ["chest press"], 80...105),
        ("OVERHEAD : CHEST", ["shoulder press"], ["chest press"], 55...75),
        ("HAMSTRING : QUAD", ["leg curl"], ["leg extension"], 50...80),
    ]

    /// Recomputes every report from raw rows. Pure, so the same inputs give the
    /// same reading in tests and on device.
    func rebuild(sets: [WorkoutSet], sessions: [WorkoutSession], calendar: BlockCalendar) {
        let sessionById = Dictionary(sessions.compactMap { s in s.id.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        // lift → position → best point
        var weekly: [String: [BlockPosition: LiftBlockPoint]] = [:]
        var liftSession: [String: String] = [:]
        // Working sets per muscle in each block, fractionally attributed, and
        // the training weeks each block actually had — so "sets/wk" is that
        // block's own average, not the last fortnight zeroed out on older ones.
        var setsByBlock: [Int: [BodyMuscle: Double]] = [:]
        var weeksByBlock: [Int: Set<Int>] = [:]

        for set in sets where set.isWarmup != true {
            if Self.isCardioOrYoga(set) { continue }
            let name = PrescriptionParser.normalizeExerciseName(set.exercise)
            guard !name.isEmpty else { continue }
            let session = set.workoutSessionId.flatMap { sessionById[$0] }
            if let t = session?.type { liftSession[name] = t }

            let position: BlockPosition?
            if let session { position = calendar.position(of: session) }
            else if let d = set.date { position = calendar.position(onDate: d) }
            else { position = nil }
            guard let pos = position else { continue }

            weeksByBlock[pos.block, default: []].insert(pos.week)
            for (group, share) in ExerciseCatalog.shared.muscleContributions(for: set.exercise) {
                if let m = Self.bodyMuscle(forGroup: group) { setsByBlock[pos.block, default: [:]][m, default: 0] += share }
            }

            let weight = set.actualWeightKg ?? 0
            let reps = set.actualReps ?? 0
            guard weight > 0, reps > 0, reps <= Self.maxRepsForE1RM else { continue }
            let e = WorkoutService.epley1RM(weight: weight, reps: reps)
            var byPos = weekly[name] ?? [:]
            if (byPos[pos]?.e1rm ?? 0) < e {
                byPos[pos] = LiftBlockPoint(position: pos, e1rm: e, weight: weight, reps: reps, rpe: set.actualRpe)
            }
            weekly[name] = byPos
        }

        allLiftNames = weekly.keys.sorted()

        // Blocks that can be judged: any block with a peak AND a prior peak.
        let blocks = Set(weekly.values.flatMap { $0.keys.map(\.block) }).sorted()
        var snaps: [BlockSnapshot] = []
        for b in blocks {
            let lifts = weekly.map { name, byPos in
                Self.judge(name: name, byPos: byPos, block: b, sessionType: liftSession[name])
            }
            guard lifts.contains(where: { $0.state != StrengthState.none }) else { continue }
            let muscles = Self.muscleReports(lifts: lifts, setsPerMuscle: Self.weeklyVolume(setsByBlock[b], weeks: weeksByBlock[b]), currentBlock: b == calendar.current.block)
            let deltas = lifts.compactMap { $0.state == StrengthState.none ? nil : $0.deltaPct }
            snaps.append(BlockSnapshot(judged: BlockPosition(block: b, week: Config.peakWeek), lifts: lifts, muscles: muscles, medianGainPct: ChartMath.median(deltas),
                                       dateRange: calendar.dateRange(ofBlock: b).map(BlockCalendar.shortRange)))
        }
        // Always offer the current block even when it cannot be judged yet,
        // so the muscle map still shows volume and the grey states.
        if snaps.last?.judged.block != calendar.current.block {
            let lifts = weekly.map { name, byPos in Self.judge(name: name, byPos: byPos, block: calendar.current.block, sessionType: liftSession[name]) }
            let muscles = Self.muscleReports(lifts: lifts, setsPerMuscle: Self.weeklyVolume(setsByBlock[calendar.current.block], weeks: weeksByBlock[calendar.current.block]), currentBlock: true)
            snaps.append(BlockSnapshot(judged: BlockPosition(block: calendar.current.block, week: calendar.current.week), lifts: lifts, muscles: muscles, medianGainPct: nil,
                                       dateRange: calendar.dateRange(ofBlock: calendar.current.block).map(BlockCalendar.shortRange)))
        }
        snapshots = snaps
        shownIndex = max(0, snaps.count - 1)

        // Balance ratios use the newest peak available for each lift.
        balance = Self.balancePairs.map { pair in
            // Isolated explicitly: a local func does not inherit the enclosing
            // closure's MainActor isolation under SWIFT_DEFAULT_ACTOR_ISOLATION,
            // and BlockPosition's Hashable conformance is MainActor-isolated by
            // that same setting, so keying a dictionary by it needs the actor.
            @MainActor
            func find(_ keys: [String]) -> (String, Double)? {
                for (name, byPos) in weekly {
                    let lower = name.lowercased()
                    if keys.allSatisfy({ lower.contains($0) }) {
                        if let best = Self.latestPeak(byPos) { return (name, best) }
                    }
                }
                return nil
            }
            let l = find(pair.left), r = find(pair.right)
            return BalanceReport(title: pair.title,
                                 leftName: l?.0.uppercased() ?? pair.left.joined(separator: " ").uppercased() + " · NO DATA",
                                 rightName: r?.0.uppercased() ?? pair.right.joined(separator: " ").uppercased() + " · NO DATA",
                                 leftValue: l?.1, rightValue: r?.1, band: pair.band)
        }
        hasLoadedOnce = true
    }

    // MARK: - Judgement

    /// A block's peak: its best e1RM across the build and peak weeks. Week 4
    /// counts only when it is all the block has.
    private static func blockPeak(_ byPos: [BlockPosition: LiftBlockPoint], block: Int) -> LiftBlockPoint? {
        let inBlock = byPos.values.filter { $0.position.block == block }
        let loading = inBlock.filter { !$0.position.isDeload }
        return (loading.isEmpty ? inBlock : loading).max { $0.e1rm < $1.e1rm }
    }

    private static func latestPeak(_ byPos: [BlockPosition: LiftBlockPoint]) -> Double? {
        let blocks = Set(byPos.keys.map(\.block)).sorted()
        for b in blocks.reversed() { if let p = blockPeak(byPos, block: b) { return p.e1rm } }
        return nil
    }

    static func judge(name: String, byPos: [BlockPosition: LiftBlockPoint], block: Int, sessionType: String?) -> LiftReport {
        let muscle = ExerciseCatalog.shared.muscleGroup(for: name).flatMap { bodyMuscle(forGroup: $0) }
        let peak = blockPeak(byPos, block: block)
        let earlier = Set(byPos.keys.map(\.block)).filter { $0 < block }.sorted()
        let priorPeak = earlier.last.flatMap { blockPeak(byPos, block: $0)?.e1rm }
        let allTime = byPos.values.map(\.e1rm).max() ?? 0

        var state: StrengthState = StrengthState.none
        var delta: Double? = nil
        var sincePR: Int? = nil
        if let peak, let prior = priorPeak, prior > 0 {
            delta = (peak.e1rm - prior) / prior * 100
            let bestBefore = earlier.compactMap { blockPeak(byPos, block: $0)?.e1rm }.max() ?? 0
            // Blocks since the last block that beat everything before it.
            var running = 0.0
            var lastPR: Int? = nil
            for b in earlier + [block] {
                if let p = blockPeak(byPos, block: b)?.e1rm {
                    if p > running * 1.005 { lastPR = b }
                    running = max(running, p)
                }
            }
            sincePR = lastPR.map { block - $0 }
            if peak.e1rm > bestBefore * 1.005 { state = .pr }
            else if delta! <= dropPct { state = .drop }
            else if delta! >= progressPct { state = .up }
            else if (sincePR ?? 0) >= stallBlocks { state = .stall }
            else { state = .hold }
        }
        return LiftReport(name: name, muscle: muscle, sessionType: sessionType, weekly: byPos, judged: BlockPosition(block: block, week: Config.peakWeek),
                          peak: peak, priorPeak: priorPeak, allTimeBest: allTime, deltaPct: delta, blocksSincePR: sincePR, state: state)
    }

    /// A block's sets per muscle divided by the training weeks it actually
    /// had, so a block in progress is not judged against four weeks.
    private static func weeklyVolume(_ sets: [BodyMuscle: Double]?, weeks: Set<Int>?) -> [BodyMuscle: Double] {
        guard let sets, let weeks, !weeks.isEmpty else { return [:] }
        let n = Double(weeks.count)
        return sets.mapValues { $0 / n }
    }

    private static func muscleReports(lifts: [LiftReport], setsPerMuscle: [BodyMuscle: Double], currentBlock: Bool) -> [MuscleReport] {
        BodyMuscle.allCases.map { m in
            let mine = lifts.filter { $0.muscle == m }
            let driving = mine.sorted { a, b in
                if a.state.attention != b.state.attention { return a.state.attention < b.state.attention }
                return (a.peak?.e1rm ?? 0) > (b.peak?.e1rm ?? 0)
            }.first
            var state: StrengthState = driving?.state ?? StrengthState.none
            let sets = setsPerMuscle[m] ?? 0
            let band = VolumeBands.targetRange(for: m.rawValue)
            if currentBlock, sets > 0, sets < Double(band.lowerBound), [StrengthState.up, .hold, StrengthState.none].contains(state) {
                state = .short
            }
            return MuscleReport(muscle: m, state: state, drivingLift: driving, setsPerWeek: sets, band: band)
        }
    }

    // MARK: - Mapping

    static func bodyMuscle(forGroup group: String) -> BodyMuscle? {
        switch group.lowercased() {
        case "chest": return .chest
        case "back", "lats", "upper back", "traps": return .back
        case "shoulders", "front delts", "side delts", "delts": return .shoulders
        case "rear delts": return .rearDelts
        case "biceps", "forearms": return .biceps
        case "triceps": return .triceps
        case "legs", "quads": return .quads
        case "hamstrings": return .hamstrings
        case "glutes": return .glutes
        case "calves": return .calves
        case "abs", "core": return .abs
        default: return nil
        }
    }

    private static func isCardioOrYoga(_ set: WorkoutSet) -> Bool {
        let note = (set.notes ?? "").lowercased()
        return note.hasPrefix("yoga") || note.contains(" yoga") || note.hasPrefix("cardio") || note.contains(" cardio")
    }

    // MARK: - Copy

    /// The hero sentence, computed from the snapshot. Never invents a claim
    /// the data cannot support.
    static func diagnosis(_ snap: BlockSnapshot?, focus: BodyMuscle?) -> AttributedString {
        guard let snap, snap.judgedCount > 0 else {
            return .editorial([("Block-over-block strength needs two blocks of stamped sessions. Everything reads grey until the next peak week has been lifted; the muscle map still shows this week's set counts.", false)])
        }
        var parts: [(String, Bool)] = []
        if let focus {
            let mine = snap.lifts.filter { $0.muscle == focus && $0.state != StrengthState.none }.sorted { $0.state.attention < $1.state.attention }
            if mine.isEmpty {
                parts.append(("\(focus.rawValue) has no block-over-block read yet.", false))
            } else {
                parts.append((focus.rawValue, true)); parts.append((": ", false))
                parts.append((mine.map { "\($0.name) \($0.state.label.lowercased()) (\(Editorial.signedPct($0.deltaPct ?? 0)))" }.joined(separator: ", ") + ".", false))
            }
            return .editorial(parts)
        }
        let prs = snap.lifts.filter { $0.state == .pr }.map(\.name)
        let stalls = snap.lifts.filter { $0.state == .stall }.map(\.name)
        let drops = snap.lifts.filter { $0.state == .drop }.map(\.name)
        let shorts = snap.muscles.filter { $0.state == .short }.map { $0.muscle.rawValue.lowercased() }
        parts.append(("Peak week against peak week, \(snap.judged.blockLabel.lowercased()) over the one before. ", false))

        // Names read as a list — "A, B and C", or the first three "and N
        // more" — never a chain of "and"s. Lifts are bold; muscles are not.
        func clause(_ names: [String], bold: Bool, one: String, many: String, sentenceStart: Bool = false) {
            guard !names.isEmpty else { return }
            let (list, rest) = Self.nameList(names)
            let shown = sentenceStart ? list.prefix(1).uppercased() + list.dropFirst() : list
            parts.append((shown, bold))
            if rest > 0 { parts.append((" and \(rest) more", false)) }
            parts.append((names.count == 1 ? one : many, false))
        }
        clause(prs, bold: true, one: " set an all-time best. ", many: " set all-time bests. ")
        clause(stalls, bold: true, one: " has not moved in two blocks. ", many: " have not moved in two blocks. ")
        clause(drops, bold: true, one: " dropped more than 5%. ", many: " dropped more than 5%. ")
        clause(shorts, bold: false, one: " is short on sets, not strength.", many: " are short on sets, not strength.", sentenceStart: true)
        if prs.isEmpty && stalls.isEmpty && drops.isEmpty && shorts.isEmpty { parts.append(("Every judged lift is holding or progressing. Nothing to act on.", false)) }
        return .editorial(parts)
    }

    /// "A, B and C" for up to three names; beyond that the first three and
    /// how many are left, for the caller to append " and N more".
    static func nameList(_ names: [String], limit: Int = 3) -> (shown: String, rest: Int) {
        if names.count <= limit {
            guard names.count > 1 else { return (names.first ?? "", 0) }
            return (names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1], 0)
        }
        return (names.prefix(limit).joined(separator: ", "), names.count - limit)
    }

    static func coachPrompt(_ snap: BlockSnapshot?, focus: BodyMuscle?) -> String? {
        guard let snap, snap.judgedCount > 0 else { return nil }
        var lines = ["Looking at my Strength tab (\(snap.judged.blockLabel.lowercased()), peak week vs the block before):"]
        if let g = snap.medianGainPct { lines.append("- median est. 1RM change across \(snap.judgedCount) lifts: \(Editorial.signedPct(g))") }
        let interesting = snap.lifts.filter { [.pr, .stall, .drop].contains($0.state) }.sorted { $0.state.attention < $1.state.attention }
        for l in interesting { lines.append("- \(l.name): \(l.state.label.lowercased()), \(Editorial.signedPct(l.deltaPct ?? 0)), \(l.bestSetLine)") }
        let shorts = snap.muscles.filter { $0.state == .short }
        for m in shorts { lines.append("- \(m.muscle.rawValue): \(String(format: "%.1f", m.setsPerWeek)) sets/wk against a \(m.band.lowerBound)–\(m.band.upperBound) band") }
        if let focus { lines.append("I want to talk about \(focus.rawValue) specifically.") }
        lines.append("What should change next block?")
        return lines.joined(separator: "\n")
    }
}
