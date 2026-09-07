// VolumeBands.swift
// Vaux
//
// Weekly set targets per muscle for the muscle-gain phase. One home for the
// numbers the Volume and Strength tabs both judge against; keep in sync with
// the coach's system prompt.

import Foundation

enum VolumeBands {
    /// Whether a muscle has a weekly target at all. Glutes do not: the
    /// programme trains them only as a synergist (leg press, sumo press, back
    /// extension at half a set each), the coach's prompt lists no glute band,
    /// and the backend ranks weak points over banded muscles only. Judging
    /// them against 10-16 made "glutes 5.5 short" a permanent fixture that
    /// no session in the programme could ever clear.
    static func hasTarget(for group: String) -> Bool {
        group.lowercased() != "glutes"
    }

    static func targetRange(for group: String) -> ClosedRange<Int> {
        switch group.lowercased() {
        case "legs", "quads", "hamstrings", "glutes": return 10...16
        case "back", "chest": return 10...16
        case "shoulders": return 8...12
        case "biceps", "triceps": return 8...12
        // The coach's prompt: "Rear delts 8-14". This sat at 4-8 "pending a
        // programming call" long after the call was made, so the app flagged
        // 11 sets a week as 3 over while the coach read the same number as
        // inside the band. One source of truth: the prompt's sentence.
        case "rear delts": return 8...14
        case "calves": return 6...10
        case "abs", "core": return 10...16
        default: return 8...12
        }
    }
}
