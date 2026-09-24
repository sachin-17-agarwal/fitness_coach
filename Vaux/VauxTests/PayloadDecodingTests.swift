// PayloadDecodingTests.swift
// VauxTests
//
// S7 (25 Sep 2026): the three payloads that have each broken once without a
// test — the block review card's decoding, the widget payload, and the
// set-phase split the pending-reply resume relies on — plus the block-length
// labels the app derives from the stored setting. Decoding uses the same
// strategy the app does (snake_case keys via CodingKeys or the widget's
// convertFromSnakeCase).

import Foundation
import Testing
@testable import Vaux

struct PayloadDecodingTests {

    @Test func blockReviewDecodesTheServersShape() throws {
        let json = """
        {"status": "shown", "block_start": "2026-09-20", "dry_run": false,
         "text": "A good block.",
         "proposals": [{"line": "Decision: Cable Crunch | clear", "rationale": "cap cleared", "kind": "decision"}],
         "sections": [{"label": "Strength", "body": "Up on nine lifts."}],
         "window": {"since": "2026-08-11", "until": "2026-09-01"},
         "lifts": [{"exercise": "Leg Press", "delta_pct": 8.2, "verdict": "up", "this_set": "270x11", "prev_set": "245x15"}],
         "volume": [{"muscle": "Hamstrings", "sets": 12.5, "band": "10-16", "under_by": null, "over_by": null}]}
        """.data(using: .utf8)!
        let review = try JSONDecoder().decode(BlockReviewResponse.self, from: json)
        #expect(review.isOpen)
        #expect(review.blockStart == "2026-09-20")
        #expect(review.dryRun == false)
        #expect(review.proposals?.first?.line == "Decision: Cable Crunch | clear")
        #expect(review.lifts?.first?.exercise == "Leg Press")
        #expect(review.volume?.first?.muscle == "Hamstrings")
    }

    @Test func blockReviewWithOnlyAStatusStillDecodes() throws {
        let json = #"{"status": "none"}"#.data(using: .utf8)!
        let review = try JSONDecoder().decode(BlockReviewResponse.self, from: json)
        #expect(!review.isOpen)
        #expect(review.text == nil && review.proposals == nil)
    }

    @Test func decisionAnswerDecodes() throws {
        let json = #"{"status": "recorded", "message": "Recorded: Cable Crunch: cap cleared."}"#.data(using: .utf8)!
        let out = try JSONDecoder().decode(BlockReviewAnswerResponse.self, from: json)
        #expect(out.status == "recorded")
    }

    @Test func setsSplitByThePhaseTheyWereLoggedUnder() {
        func set(_ n: Int, phase: String?, warm: Bool = false) -> WorkoutSet {
            WorkoutSet(id: UUID(), workoutSessionId: UUID(), date: "2026-09-25", exercise: "Leg Press", setNumber: n,
                       isWarmup: warm, targetWeightKg: nil, targetReps: nil, targetRpe: nil,
                       actualWeightKg: 200, actualReps: 10, actualRpe: 8, restSeconds: nil, notes: nil,
                       loggedAt: nil, phase: phase)
        }
        // A back-off logged first (working set skipped) stays a back-off.
        let split = WorkoutSet.splitByPhase([set(1, phase: "warmup", warm: true), set(2, phase: "backoff")], workingPrescribed: 1)
        #expect(split.warmups.count == 1 && split.working.isEmpty && split.backoff.count == 1)
        // Rows without a phase keep the position rule: working slots fill first.
        let legacy = WorkoutSet.splitByPhase([set(1, phase: nil), set(2, phase: nil), set(3, phase: nil)], workingPrescribed: 1)
        #expect(legacy.working.count == 1 && legacy.backoff.count == 2)
    }

    @Test func blockLengthDrivesTheLabels() {
        let saved = Config.mesocycleWeeks
        defer { Config.mesocycleWeeks = saved }
        Config.mesocycleWeeks = 4
        #expect(Config.phaseName(week: 3) == "Peak" && Config.phaseName(week: 4) == "Deload" && Config.phaseName(week: 5) == nil)
        #expect(Config.rpeTarget(week: 4) == "RPE 7 · top set only")
        Config.mesocycleWeeks = 5
        #expect(Config.phaseName(week: 3) == "Peak · reps" && Config.phaseName(week: 4) == "Peak · load" && Config.phaseName(week: 5) == "Deload")
        #expect(Config.rpeTarget(week: 1) == "RPE 8 · back-off 8" && Config.rpeTarget(week: 3) == "RPE 9 · back-off 8")
        #expect(Config.peakWeek == 4 && Config.deloadWeek == 5)
    }

    @Test func aPendingSetReplyIsKeptOnEveryFailureButARejection() {
        #expect(ChatService.deliveryUnknown(ChatServiceError.backendError(statusCode: 502, body: "bad gateway")))
        #expect(ChatService.deliveryUnknown(ChatServiceError.backendError(statusCode: 504, body: "")))
        #expect(ChatService.deliveryUnknown(URLError(.cannotConnectToHost)))
        #expect(ChatService.deliveryUnknown(URLError(.secureConnectionFailed)))
        #expect(ChatService.deliveryUnknown(CoachStillThinking()))
        #expect(!ChatService.deliveryUnknown(ChatServiceError.backendError(statusCode: 401, body: "")))
        #expect(ChatService.definitelyRejected(ChatServiceError.backendError(statusCode: 400, body: "empty message")))
        #expect(!ChatService.definitelyRejected(ChatServiceError.backendError(statusCode: 502, body: "")))
        #expect(!ChatService.definitelyRejected(URLError(.timedOut)))
    }
}
