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
    /// 1...weeks within the block.
    let week: Int
    /// Weeks in this position's block: from the block's own stamps when the
    /// calendar placed it (U6, 26 Sep 2026), the setting otherwise. Blocks
    /// differ — four weeks to 1 Sep 2026, five from 2 Sep — and reading every
    /// block through the current setting labelled last block's deload PEAK.
    /// Not part of equality or hashing: a position is a block and a week.
    let weeks: Int

    init(block: Int, week: Int, weeks: Int = Config.weeksPerBlock) {
        self.block = block
        self.week = week
        self.weeks = weeks
    }

    static func == (a: BlockPosition, b: BlockPosition) -> Bool { a.block == b.block && a.week == b.week }
    func hash(into hasher: inout Hasher) { hasher.combine(block); hasher.combine(week) }

    static func < (a: BlockPosition, b: BlockPosition) -> Bool {
        a.block != b.block ? a.block < b.block : a.week < b.week
    }

    /// The peak is the week before the deload once a block has one.
    static func peakWeek(weeks: Int) -> Int { weeks >= 4 ? weeks - 1 : weeks }
    var peakWeek: Int { Self.peakWeek(weeks: weeks) }
    var isDeload: Bool { week == weeks }
    var isPeak: Bool { week == peakWeek }

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
        if week == peakWeek { return "PEAK" }
        if week == weeks { return "DELOAD" }
        return "BUILD"
    }
}

extension Config {
    /// Derived from `mesocycleWeeks` (the setting): the deload is the last
    /// week, the peak the one before it.
    static var weeksPerBlock: Int { mesocycleWeeks }
    static var peakWeek: Int { mesocycleWeeks - 1 }
    static var deloadWeek: Int { mesocycleWeeks }

    /// The week's name for the block length in force. Nil outside the block.
    static func phaseName(week: Int) -> String? {
        switch week {
        case 1: return "Baseline"
        case 2: return "Volume"
        case deloadWeek: return "Deload"
        case peakWeek: return weeksPerBlock >= 5 ? "Peak · load" : "Peak"
        case peakWeek - 1 where weeksPerBlock >= 5: return "Peak · reps"
        default: return nil
        }
    }

    /// The week's RPE targets, as the card's header shows them.
    static func rpeTarget(week: Int) -> String? {
        guard phaseName(week: week) != nil else { return nil }
        if week == deloadWeek { return "RPE 7 · top set only" }
        if week >= peakWeek - (weeksPerBlock >= 5 ? 1 : 0) { return "RPE 9 · back-off 8" }
        return "RPE 8 · back-off 8"
    }
}

struct BlockCalendar: Sendable {
    /// The position of the session about to be trained (or in progress).
    let current: BlockPosition
    private let bySession: [UUID: BlockPosition]
    /// Position of each training day, keyed by "yyyy-MM-dd".
    private let byDate: [String: BlockPosition]
    /// Training dates ascending, for nearest-previous lookups.
    private let orderedDates: [String]
    /// Weeks in each placed block, from its own stamps (U6).
    private let weeksInBlock: [Int: Int]

    static let empty = BlockCalendar(current: BlockPosition(block: 0, week: 1), bySession: [:], byDate: [:], orderedDates: [], weeksInBlock: [:])

    /// Weeks in `block`: its last stamped week when the window shows four or
    /// more, else the setting (a block cut off by the window, or the one in
    /// progress).
    func weeks(in block: Int) -> Int { weeksInBlock[block] ?? Config.weeksPerBlock }
    func peakWeek(in block: Int) -> Int { BlockPosition.peakWeek(weeks: weeks(in: block)) }
    /// A position carrying its block's real shape.
    func position(block: Int, week: Int) -> BlockPosition { BlockPosition(block: block, week: week, weeks: weeks(in: block)) }
    func position(ordinal: Int) -> BlockPosition {
        let p = BlockPosition.from(ordinal: ordinal)
        return position(block: p.block, week: p.week)
    }

    private init(current: BlockPosition, bySession: [UUID: BlockPosition], byDate: [String: BlockPosition], orderedDates: [String],
                 weeksInBlock: [Int: Int]) {
        self.current = current
        self.bySession = bySession
        self.byDate = byDate
        self.orderedDates = orderedDates
        self.weeksInBlock = weeksInBlock
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

        // Each block's shape from what was placed in it: the highest week
        // seen. Fewer than four weeks means the window cut the block off (or
        // it is the one in progress), and the setting stands for it.
        var seen: [Int: Int] = [:]
        for p in sessionMap.values { seen[p.block] = max(seen[p.block] ?? 0, p.week) }
        for p in dateMap.values { seen[p.block] = max(seen[p.block] ?? 0, p.week) }
        seen[0] = max(seen[0] ?? 0, week0)
        var shapes: [Int: Int] = [:]
        for (b, w) in seen where b < 0 && w >= 4 { shapes[b] = w }
        func shaped(_ p: BlockPosition) -> BlockPosition {
            BlockPosition(block: p.block, week: p.week, weeks: shapes[p.block] ?? Config.weeksPerBlock)
        }
        self.weeksInBlock = shapes
        self.current = BlockPosition(block: 0, week: week0)
        self.bySession = sessionMap.mapValues(shaped)
        self.byDate = dateMap.mapValues(shaped)
        self.orderedDates = dateMap.keys.sorted()
    }

    /// First and last training dates placed in `block`, as "yyyy-MM-dd".
    /// nil when no session in the window landed in that block.
    func dateRange(ofBlock block: Int) -> (start: String, end: String)? {
        let dates = byDate.filter { $0.value.block == block }.keys.sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return (first, last)
    }

    /// "12 MAY – 8 JUN" (or "12 – 30 MAY" within one month) for a block range.
    ///
    /// `nonisolated` because it is pure formatting and is passed as a function
    /// value to `Optional.map` — under the project's main-actor default it
    /// would otherwise be an isolated method handed to a nonisolated closure,
    /// which the compiler rejects wherever the caller cannot hop.
    nonisolated static func shortRange(_ range: (start: String, end: String)) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let a = f.date(from: range.start), let b = f.date(from: range.end) else { return "" }
        let day = Date.FormatStyle().day()
        let dayMonth = Date.FormatStyle().day().month(.abbreviated)
        let sameMonth = Calendar.current.isDate(a, equalTo: b, toGranularity: .month)
        let text = sameMonth ? "\(a.formatted(day)) – \(b.formatted(dayMonth))" : "\(a.formatted(dayMonth)) – \(b.formatted(dayMonth))"
        return text.uppercased()
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
