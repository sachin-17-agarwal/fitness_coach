// SessionRulesTests.swift
// VauxTests
//
// Small rules two codebases share: session status spellings, the rotation,
// the volume bands, the median and the signed percentage the hero prints.

import Testing
@testable import Vaux

@MainActor
struct SessionRulesTests {

    @Test func everySpellingOfFinishedIsFinished() {
        for raw in ["completed", "complete", "COMPLETED", " complete "] {
            #expect(SessionStatus(raw).isFinished, "\(raw) should read as finished")
        }
        for raw in ["in_progress", "active", "", nil] as [String?] {
            #expect(!SessionStatus(raw).isFinished, "\(raw ?? "nil") should read as open")
        }
        #expect(SessionStatus.finishedStored == "completed")
        #expect(SessionStatus.openStored == "in_progress")
    }

    @Test func anAbandonedRowIsNeitherOpenNorFinished() {
        // 25 Sep 2026's hygiene fix wrote `abandoned` on 45 empty rows; History
        // then showed a 15 Sep day as IN PROGRESS because "not finished" was "open".
        let abandoned = SessionStatus("abandoned")
        #expect(!abandoned.isOpen)
        #expect(!abandoned.isFinished)
        #expect(abandoned.label == "ABANDONED")
        #expect(SessionStatus("in_progress").isOpen)
        #expect(!SessionStatus("completed").isOpen)
    }

    @Test func theRotationMatchesTheBackend() {
        // Must match CYCLE in data.py.
        #expect(Config.cycle == ["Pull", "Push", "Legs", "Cardio+Abs"])
        #expect(MesocycleState(day: 1, week: 1).sessionType == "Pull")
        #expect(MesocycleState(day: 2, week: 1).sessionType == "Push")
        #expect(MesocycleState(day: 3, week: 4).sessionType == "Legs")
        #expect(MesocycleState(day: 4, week: 4).sessionType == "Cardio+Abs")
        #expect(MesocycleState(day: 4, week: 4).isLastDayOfCycle)
    }

    @Test func anOverrideOutranksTheRotationForTodayOnly() {
        let state = MesocycleState(day: 3, week: 4, todayOverride: "Push")
        #expect(state.sessionType == "Push")
        #expect(state.isOverridden)
        #expect(state.rotationSessionType == "Legs")
        // The override consumes the slot: tomorrow steps along from day 3.
        #expect(state.nextSessionType == "Cardio+Abs")
    }

    @Test func aRestOrYogaDayDoesNotConsumeASlot() {
        let yoga = MesocycleState(day: 3, week: 4, todayOverride: "Yoga")
        #expect(yoga.nextSessionType == "Legs")
        let rest = MesocycleState(day: 1, week: 1, todayOverride: "Rest")
        #expect(rest.nextSessionType == "Pull")
    }

    @Test func volumeBandsAreTheProgrammes() {
        #expect(VolumeBands.targetRange(for: "hamstrings") == 10...16)
        #expect(VolumeBands.targetRange(for: "calves") == 6...10)
        #expect(VolumeBands.targetRange(for: "rear delts") == 8...14)
        #expect(VolumeBands.targetRange(for: "chest") == 10...16)
    }

    @Test func medianAndSignedPercentage() {
        #expect(ChartMath.median([]) == nil)
        #expect(ChartMath.median([3, 1, 2]) == 2)
        #expect(ChartMath.median([4, 1, 3, 2]) == 2.5)
        #expect(Editorial.signedPct(8.14) == "▴ 8.1%")
        #expect(Editorial.signedPct(-2.5) == "▾ 2.5%")
        #expect(Editorial.signedPct(0) == "0.0%")
    }
}
