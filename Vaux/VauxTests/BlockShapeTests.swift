// BlockShapeTests.swift
// VauxTests
//
// U6 (26 Sep 2026): a block's shape comes from its own stamps. Last block
// ran four weeks (its peak week 3, its deload week 4); the block in progress
// runs five. Read through the setting alone, last block's deload was PEAK.

import Foundation
import Testing
@testable import Vaux

struct BlockShapeTests {

    private func sessions() -> [WorkoutSession] {
        var out: [WorkoutSession] = []
        let types = ["Pull", "Push", "Legs", "Cardio+Abs"]
        // Last block: four weeks, 11 Aug – 1 Sep (dates only need to be ordered).
        var day = 11
        for w in 1...4 { for d in 1...4 { out.append(Fixtures.session(types[d - 1], on: String(format: "2026-08-%02d", day), week: w, day: d)); day += 1 } }
        // This block: five weeks, six sessions in so far.
        let sep = [(1, 1, "02"), (1, 2, "03"), (1, 3, "04"), (1, 4, "06"), (2, 1, "07"), (2, 2, "08")]
        for (w, d, dd) in sep { out.append(Fixtures.session(types[d - 1], on: "2026-09-\(dd)", week: w, day: d)) }
        return out
    }

    @Test func lastBlockKeepsItsFourWeekShape() {
        let saved = Config.mesocycleWeeks
        defer { Config.mesocycleWeeks = saved }
        Config.mesocycleWeeks = 5
        let all = sessions()
        let cal = BlockCalendar(sessions: all, state: MesocycleState(day: 3, week: 2))
        #expect(cal.weeks(in: -1) == 4 && cal.peakWeek(in: -1) == 3)
        #expect(cal.weeks(in: 0) == 5 && cal.peakWeek(in: 0) == 4)
        let augWeek3 = all.first { $0.date == "2026-08-19" }!   // week 3 day 1 of last block
        let augWeek4 = all.first { $0.date == "2026-08-23" }!   // week 4 day 1
        #expect(cal.position(of: augWeek3)?.isPeak == true)
        #expect(cal.position(of: augWeek4)?.isDeload == true)
        #expect(cal.position(of: augWeek4)?.phaseLabel == "DELOAD")
        #expect(cal.position(of: augWeek3)?.phaseLabel == "PEAK")
    }

    @Test func aPositionIsABlockAndAWeekWhateverItsShape() {
        #expect(BlockPosition(block: -1, week: 3) == BlockPosition(block: -1, week: 3, weeks: 4))
        #expect(BlockPosition(block: -1, week: 3, weeks: 4).hashValue == BlockPosition(block: -1, week: 3, weeks: 5).hashValue)
        #expect(BlockPosition.peakWeek(weeks: 4) == 3 && BlockPosition.peakWeek(weeks: 5) == 4 && BlockPosition.peakWeek(weeks: 3) == 3)
    }
}
