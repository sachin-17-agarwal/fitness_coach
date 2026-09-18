// CardReferenceTests.swift
// VauxTests
//
// The two reference lines beside the working chip. LAST is the most recent
// session on the lift; BLOCK is the same stamped week of the previous block
// and carries the delta. Both are static functions over rows.

import Testing
@testable import Vaux

@MainActor
struct CardReferenceTests {

    @Test func lastIsTheMostRecentSessionsTopSet() throws {
        let history = [
            Fixtures.set("Leg Press", on: "2026-09-02", weight: 235, reps: 10, rpe: 8),
            Fixtures.set("Leg Press", on: "2026-09-14", number: 1, weight: 245, reps: 15, rpe: 9),
            Fixtures.set("Leg Press", on: "2026-09-14", number: 2, weight: 196, reps: 11, rpe: 8),
        ]
        let ref = try #require(WorkoutViewModel.lastBlockReference(from: history, week: 4))
        #expect(ref.weight == 245)
        #expect(ref.reps == 15)
        #expect(ref.rpe == 9)
        #expect(ref.label == "14 SEP")
    }

    @Test func lastIgnoresWarmups() throws {
        let history = [
            Fixtures.set("Leg Press", on: "2026-09-14", number: 1, warmup: true, weight: 300, reps: 1),
            Fixtures.set("Leg Press", on: "2026-09-14", number: 2, weight: 245, reps: 15, rpe: 9),
        ]
        let ref = try #require(WorkoutViewModel.lastBlockReference(from: history, week: 4))
        #expect(ref.weight == 245)
    }

    @Test func lastIsNilWithNoHistory() {
        #expect(WorkoutViewModel.lastBlockReference(from: [], week: 4) == nil)
    }

    @Test func blockIsTheSameStampedWeekOfThePreviousBlock() throws {
        let prevDeload = UUID(), prevPeak = UUID(), thisPeak = UUID(), thisStart = UUID()
        let sessions = [
            Fixtures.session("Legs", on: "2026-08-15", week: 3, day: 3, id: prevPeak),
            Fixtures.session("Legs", on: "2026-08-20", week: 4, day: 3, id: prevDeload),
            Fixtures.session("Pull", on: "2026-08-24", week: 1, day: 1, id: thisStart),   // this block starts
            Fixtures.session("Legs", on: "2026-09-14", week: 3, day: 3, id: thisPeak),
        ]
        let history = [
            Fixtures.set("Leg Press", on: "2026-08-15", weight: 240, reps: 14, rpe: 9, session: prevPeak),
            Fixtures.set("Leg Press", on: "2026-08-20", weight: 240, reps: 11, rpe: 7, session: prevDeload),
            Fixtures.set("Leg Press", on: "2026-09-14", weight: 245, reps: 15, rpe: 9, session: thisPeak),
        ]
        // Today is week 4 (deload): the reference is last block's deload, not last week's peak.
        let ref = try #require(WorkoutViewModel.sameWeekBlockReference(
            from: history, sessions: sessions, week: 4, today: "2026-09-18"))
        #expect(ref.weight == 240)
        #expect(ref.reps == 11)
        #expect(ref.label == "WK4 · 20 AUG")
    }

    @Test func blockSkipsTheCurrentBlockAndNeedsAStamp() {
        let thisStart = UUID(), thisPeak = UUID()
        let sessions = [
            Fixtures.session("Pull", on: "2026-08-24", week: 1, day: 1, id: thisStart),
            Fixtures.session("Legs", on: "2026-09-14", week: 3, day: 3, id: thisPeak),
        ]
        let history = [Fixtures.set("Leg Press", on: "2026-09-14", weight: 245, reps: 15, rpe: 9, session: thisPeak)]
        // The only week-3 session is in this block: no reference.
        #expect(WorkoutViewModel.sameWeekBlockReference(from: history, sessions: sessions, week: 3, today: "2026-09-18") == nil)
        // No stamped week on the current session: no reference either.
        #expect(WorkoutViewModel.sameWeekBlockReference(from: history, sessions: sessions, week: nil, today: "2026-09-18") == nil)
    }
}
