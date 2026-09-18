// StrengthJudgeTests.swift
// VauxTests
//
// The block-over-block verdict on a lift, and the HELD rule from 16 Sep: a
// lift under a standing decision reads HELD, not DROP, unless it set a PR.

import Testing
@testable import Vaux

@MainActor
struct StrengthJudgeTests {

    private func byPos(_ points: [(BlockPosition, LiftBlockPoint)]) -> [BlockPosition: LiftBlockPoint] {
        Dictionary(uniqueKeysWithValues: points)
    }

    @Test func aClearRiseReadsUpOrPR() {
        let pts = byPos([Fixtures.point(block: -1, week: 3, e1rm: 100), Fixtures.point(block: 0, week: 3, e1rm: 110)])
        let report = StrengthViewModel.judge(name: "Leg Press", byPos: pts, block: 0, sessionType: "Legs")
        #expect(report.state == .pr || report.state == .up)
        #expect(report.deltaPct != nil)
        #expect((report.deltaPct ?? 0) > 9)
    }

    @Test func aClearFallReadsDrop() {
        let pts = byPos([Fixtures.point(block: -1, week: 3, e1rm: 110), Fixtures.point(block: 0, week: 3, e1rm: 99)])
        let report = StrengthViewModel.judge(name: "Leg Press", byPos: pts, block: 0, sessionType: "Legs")
        #expect(report.state == .drop)
    }

    @Test func aStandingDecisionReadsHeldNotDrop() {
        let pts = byPos([Fixtures.point(block: -1, week: 3, e1rm: 110), Fixtures.point(block: 0, week: 3, e1rm: 99)])
        let cap = StandingConstraint(exercise: "Machine Shoulder Press", maxLoadKg: 70, note: "shoulder niggle", setOn: "2026-09-13")
        let report = StrengthViewModel.judge(name: "Machine Shoulder Press", byPos: pts, block: 0, sessionType: "Push", held: cap)
        #expect(report.state == .held)
        #expect(report.held?.maxLoadKg == 70)
    }

    @Test func aPRStillReadsPRUnderAHold() {
        let pts = byPos([Fixtures.point(block: -1, week: 3, e1rm: 100), Fixtures.point(block: 0, week: 3, e1rm: 112)])
        let cap = StandingConstraint(exercise: "Machine Shoulder Press", maxLoadKg: 70, note: nil, setOn: "2026-09-13")
        let report = StrengthViewModel.judge(name: "Machine Shoulder Press", byPos: pts, block: 0, sessionType: "Push", held: cap)
        #expect(report.state == .pr)
    }

    @Test func oneBlockAloneHasNoVerdict() {
        let pts = byPos([Fixtures.point(block: 0, week: 3, e1rm: 110)])
        let report = StrengthViewModel.judge(name: "Leg Press", byPos: pts, block: 0, sessionType: "Legs")
        #expect(report.state == StrengthState.none)
        #expect(report.deltaPct == nil)
    }

    @Test func aBuildWeekBestIsNoVerdictUntilThePeakIsLifted() {
        let pts = byPos([Fixtures.point(block: -1, week: 3, e1rm: 110), Fixtures.point(block: 0, week: 2, e1rm: 105)])
        let report = StrengthViewModel.judge(name: "Leg Press", byPos: pts, block: 0, sessionType: "Legs", peakLifted: false)
        #expect(report.state == StrengthState.none)
    }
}
