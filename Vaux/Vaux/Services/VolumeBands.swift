// VolumeBands.swift
// Vaux
//
// Weekly set targets per muscle for the muscle-gain phase. One home for the
// numbers the Volume and Strength tabs both judge against; keep in sync with
// the coach's system prompt.

import Foundation

enum VolumeBands {
    static func targetRange(for group: String) -> ClosedRange<Int> {
        switch group.lowercased() {
        case "legs", "quads", "hamstrings", "glutes": return 10...16
        case "back", "chest": return 10...16
        case "shoulders": return 8...12
        case "biceps", "triceps": return 8...12
        // Left at 4–8 pending a deliberate programming call; see the
        // discussion in the coach prompt.
        case "rear delts": return 4...8
        case "calves": return 6...10
        case "abs", "core": return 10...16
        default: return 8...12
        }
    }
}
