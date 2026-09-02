// BlockCalendar.swift
// Vaux
//
// Places every session — and any calendar date — inside the mesocycle wave:
// which block (0 = the one in progress, -1 = the last one, ...) and which
// week of that block (1–3 build, 3 peak, 4 deload). History is judged block
// over block, so this is the spine the Strength, Training and Recovery tabs
// all hang from.
//
// Sessions stamped with `mesocycle_week` / `mesocycle_day` are placed by
// their stamp. Older rows are placed by walking the rotation backwards from
// the current `MesocycleState`: the week advances only when a rotation
// completes, so a session's week is never recoverable from its date alone,
// but it IS recoverable from its position in the sequence of sessions.

import Foundation

struct BlockPosition: Hashable, Comparable, Sendable {
    /// 0 is the block in progress, -1 the previous one, and so on.
    let block: Int
    /// 1...4 within the block.
    let week: Int

    static func < (a: BlockPosition, b: BlockPosition) -> Bool {
        a.block != b.block ? a.block < b.block : a.week < b.week
    }

    var isDeload: Bool { week == Config.deloadWeek }
    var isPeak: Bool { week == Config.peakWeek }

    /// Sequential index for charts: block -1 week 4 is one before block 0 week 1.
    var ordinal: Int { block * Config.weeksPerBlock + (week - 1) }

    static func from(ordinal: Int) -> BlockPosition {
        let w = Config.weeksPerBlock
        let block = Int((Double(ordinal) / Double(w)).rounded(.down))
        let week = ordinal - block * w + 1
        return BlockPosition(block: block, week: week)
    }

    /// "THIS BLOCK", "LAST BLOCK", "2 BLOCKS AGO".
    var blockLabel: String {
        switch block {
        case 0: return "THIS BLOCK"
        case -1: return "LAST BLOCK"
        default: return "\(-block) BLOCKS AGO"
        }
    }

    /// Short chart label: "NOW", "B-1", "B-2".
    var shortBlockLabel: String { block == 0 ? "NOW" : "B\(block)" }

    var phaseLabel: String {
        switch week {
        case Config.peakWeek: return "PEAK"
        case Config.deloadWeek: return "DELOAD"
        default: return "BUILD"
        }
    }
}

extension Config {
    static let weeksPerBlock = 4
    static let peakWeek = 3
    static let deloadWeek = 4
}

struct BlockCalendar: Sendable {
    /// The position of the session about to be trained (or in progress).
    let current: BlockPosition
    private let bySession: [UUID: BlockPosition]
    /// Position of each training day, keyed by "yyyy-MM-dd".
    private let byDate: [String: BlockPosition]
    /// Training dates ascending, for nearest-previous lookups.
    private let orderedDates: [String]

    static let empty = BlockCalendar(current: BlockPosition(block: 0, week: 1), bySession: [:], byDate: [:], orderedDates: [])

    private init(current: BlockPosition, bySession: [UUID: BlockPosition], byDate: [String: BlockPosition], orderedDates: [String]) {
        self.current = current
        self.bySession = bySession
        self.byDate = byDate
        self.orderedDates = orderedDates
    }

    /// Builds the calendar from the session rows in a window plus the live
    /// mesocycle state. `sessions` may be in any order.
    init(sessions: [WorkoutSession], state: MesocycleState?) {
        let rotation = Config.cycle
        let week0 = max(1, min(Config.weeksPerBlock, state?.week ?? 1))
        // `state.day` is the 1-based rotation slot of the NEXT session to
        // train. The slot the newest completed session occupies is one
        // before it; an unfinished session sits IN that slot.
        let nextSlot = ((state?.day ?? 1) - 1) % rotation.count

        // One entry per training day + type, newest first. A Cardio+Abs day
        // logs as two rows and must consume one rotation slot, not two.
        var seenKeys = Set<String>()
        var days: [(key: String, date: String, type: String, ids: [UUID], finished: Bool, week: Int?, day: Int?)] = []
        let sortedNewestFirst = sessions.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return (a.startTime ?? "") > (b.startTime ?? "")
        }
        for s in sortedNewestFirst {
            let key = "\(s.date)|\(s.type)"
            if seenKeys.contains(key) {
                if let idx = days.firstIndex(where: { $0.key == key }), let id = s.id {
                    days[idx].ids.append(id)
                    if !SessionStatus(s.status).isFinished { days[idx].finished = false }
                }
                continue
            }
            seenKeys.insert(key)
            days.append((key, s.date, s.type, s.id.map { [$0] } ?? [], SessionStatus(s.status).isFinished, s.mesocycleWeek, s.mesocycleDay))
        }

        var block = 0
        var week = week0
        var slot = nextSlot
        var sessionMap: [UUID: BlockPosition] = [:]
        var dateMap: [String: BlockPosition] = [:]
        var placedFirstRotation = false

        // Yoga (and anything outside the rotation) rides with the most recent
        // rotation position rather than consuming one.
        var carry = BlockPosition(block: 0, week: week0)

        for d in days {
            let inRotation = rotation.contains(d.type)
            if inRotation {
                if !placedFirstRotation {
                    // Step back from the "next" slot unless this one is open.
                    if d.finished {
                        slot -= 1
                        if slot < 0 { slot = rotation.count - 1; week -= 1; if week < 1 { week = Config.weeksPerBlock; block -= 1 } }
                    }
                    placedFirstRotation = true
                } else {
                    slot -= 1
                    if slot < 0 { slot = rotation.count - 1; week -= 1; if week < 1 { week = Config.weeksPerBlock; block -= 1 } }
                }
                // A stamp outranks the walk. Going backwards, a LATER week
                // than the running one means we have crossed into the
                // previous block.
                if let stampedWeek = d.week, (1...Config.weeksPerBlock).contains(stampedWeek) {
                    if stampedWeek > week { block -= 1 }
                    week = stampedWeek
                    if let stampedDay = d.day, (1...rotation.count).contains(stampedDay) { slot = stampedDay - 1 }
                }
                carry = BlockPosition(block: block, week: week)
            }
            for id in d.ids { sessionMap[id] = carry }
            if dateMap[d.date] == nil || inRotation { dateMap[d.date] = carry }
        }

        self.current = BlockPosition(block: 0, week: week0)
        self.bySession = sessionMap
        self.byDate = dateMap
        self.orderedDates = dateMap.keys.sorted()
    }

    func position(of session: WorkoutSession) -> BlockPosition? {
        if let id = session.id, let p = bySession[id] { return p }
        return byDate[session.date]
    }

    /// Position for an arbitrary date: the training day itself, else the most
    /// recent training day before it, else the current position for dates
    /// after the last session.
    func position(onDate date: String) -> BlockPosition? {
        if let p = byDate[date] { return p }
        var best: String?
        for d in orderedDates {
            if d <= date { best = d } else { break }
        }
        if let best { return byDate[best] }
        return nil
    }

    /// Every block that has at least one placed session, oldest first.
    var blocks: [Int] {
        Array(Set(bySession.values.map(\.block)).union(byDate.values.map(\.block))).sorted()
    }
}
