// PrescriptionParserTests.swift
// VauxTests
//
// The parser is the contract between the coach's text and the card. Every
// case here is a shape the coach has actually sent.

import Testing
@testable import Vaux

@MainActor
struct PrescriptionParserTests {

    static let block = """
    Good, knees feel fine. Here is the first lift.

    *Leg Press*
    Warm-up: 132.5kg x10, 180kg x5, 210kg x3
    Working Set: 240kg x12 RPE6 | Rest: 2min
    Back-off: 192kg x9-11 RPE5, 192kg x7-9 RPE5
    Form: Feet mid-plate, full depth without the hips lifting.
    Tempo: 2-0-2

    Rest two minutes and go.
    """

    @Test func aFullBlockParsesEveryPhase() throws {
        let rx = try #require(PrescriptionParser.parse(Self.block).first)
        #expect(rx.exerciseName == "Leg Press")
        #expect(rx.warmupSets.count == 3)
        #expect(rx.warmupSets[0].weight == 132.5 && rx.warmupSets[0].reps == 10)
        #expect(rx.workingSets.count == 1)
        #expect(rx.workingSets[0].weight == 240 && rx.workingSets[0].reps == 12 && rx.workingSets[0].rpe == 6)
        #expect(rx.backoffSets.count == 2)
        #expect(rx.backoffSets[0].reps == 9 && rx.backoffSets[0].repsHigh == 11)
        #expect(rx.backoffSets[1].reps == 7 && rx.backoffSets[1].repsHigh == 9)
        #expect(rx.isRevision == false)
    }

    @Test func straightSetsKeepTheirCount() throws {
        let text = """
        *Machine Calf Raise*
        Warm-up: 90kg x10, 110kg x5
        Working Set: 122.5kg x6 RPE6, 122.5kg x6 RPE6, 122.5kg x6 RPE6, 122.5kg x6 RPE6, 122.5kg x6 RPE6 | Rest: 90s
        """
        let rx = try #require(PrescriptionParser.parse(text).first)
        #expect(rx.workingSets.count == 5)
        #expect(rx.backoffSets.isEmpty)
        #expect(rx.workingSets.allSatisfy { $0.weight == 122.5 && $0.reps == 6 })
    }

    @Test func aRevisedBlockIsMarked() throws {
        let text = """
        *Seated Leg Curl*
        Revised: stack only has 90 and 95 here
        Working Set: 108kg x14 RPE6 | Rest: 2min
        Back-off: 90kg x11-14 RPE5, 90kg x9-12 RPE5
        """
        let rx = try #require(PrescriptionParser.parse(text).first)
        #expect(rx.isRevision)
        #expect(rx.backoffSets.map(\.weight) == [90, 90])
    }

    @Test func twoBlocksInOneReplyBothParse() {
        let text = Self.block + "\n\n*Single Leg Sumo Press*\nWorking Set: 130kg x7 RPE6 | Rest: 2min\nBack-off: 104kg x9-11 RPE5, 104kg x7-9 RPE5"
        let names = PrescriptionParser.parse(text).map(\.exerciseName)
        #expect(names == ["Leg Press", "Single Leg Sumo Press"])
    }

    @Test func theCoachNoteKeepsProseAndDropsTheBlock() throws {
        let note = try #require(PrescriptionParser.extractCoachNote(Self.block))
        #expect(note.contains("knees feel fine"))
        #expect(note.contains("Rest two minutes and go."))
        #expect(!note.contains("Warm-up:"))
        #expect(!note.contains("240kg"))
        #expect(!note.contains("Leg Press"))
        // The paragraph break between the two prose lines survives.
        #expect(note.contains("\n"))
    }

    @Test func exerciseNamesAreNormalisedTheSameWay() {
        #expect(PrescriptionParser.normalizeExerciseName("  seated   leg curl ") == "Seated Leg Curl")
        #expect(PrescriptionParser.normalizeExerciseName("LEG PRESS") == "Leg Press")
        #expect(PrescriptionParser.normalizeExerciseName("Leg Press") == PrescriptionParser.normalizeExerciseName("leg press"))
    }

    // 22 Sep: "Cable Chest Fly isn't next" moved the card back to Cable Chest Fly.
    @Test func aNegatedMentionIsNotAHandoff() {
        let text = "Cable Chest Fly isn't next though — that slot was already covered by the Machine Chest Fly swap earlier this session, so chest is fully done. Move to Face Pulls per the template instead."
        let got = PrescriptionParser.detectExerciseTransition(
            in: text, candidates: ["Cable Chest Fly", "Machine Chest Fly", "Face Pulls", "Tricep Pushdown"])
        #expect(got == "Face Pulls")
    }

    @Test func theHandoffVerbWinsOverAnEarlierMention() {
        let text = "Face Pulls is done; Cable Chest Fly was already covered by your earlier swap to Machine Chest Fly, so move to Tricep Pushdown next per the template."
        let got = PrescriptionParser.detectExerciseTransition(
            in: text, candidates: ["Cable Chest Fly", "Machine Chest Fly", "Tricep Pushdown"])
        #expect(got == "Tricep Pushdown")
    }

    @Test func aPlainHandoffStillMatches() {
        #expect(PrescriptionParser.detectExerciseTransition(
            in: "Good work. Moving to Seated Leg Curl.", candidates: ["Seated Leg Curl", "Machine Calf Raise"]) == "Seated Leg Curl")
    }
}
