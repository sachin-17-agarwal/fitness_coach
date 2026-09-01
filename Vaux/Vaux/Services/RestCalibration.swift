// RestCalibration.swift
// Vaux
//
// "How much rest does THIS lift need?" answered from the athlete's own log,
// not from a heart-rate proxy. Between-set readiness is dominated by local
// muscle recovery (phosphocreatine resynthesis), which no wearable signal
// reports — but its EFFECT is recorded in every session: rest too short and
// the next set's reps drop. Each pair of consecutive working sets carries a
// rest duration (the gap between their logged_at stamps) and an outcome (the
// rep change into the second set), so the log is a labeled dataset.
//
// Deliberately conservative, in the codebase's compute-don't-narrate spirit:
// it reports a threshold only when the split is backed by enough pairs and a
// rep cost of at least one full rep. Anything weaker returns nil and the rest
// screen simply shows the prescribed time with no claim attached. A missing
// calibration is "not enough evidence", never "no effect".

import Foundation

struct RestCalibration: Equatable, Sendable {
    /// Resting less than this many seconds has historically cost reps.
    let thresholdSeconds: Int
    /// Roughly how many reps short rests cost, for the receipt line.
    let repsDropped: Int
    /// How many set pairs the split was computed from.
    let samplePairs: Int

    /// The receipt line under the countdown, e.g.
    /// "UNDER 2:00 THIS LIFT DROPS ~2 REPS".
    var receiptLine: String {
        let m = thresholdSeconds / 60, s = thresholdSeconds % 60
        return String(format: "UNDER %d:%02d THIS LIFT DROPS ~%d REP%@",
                      m, s, repsDropped, repsDropped == 1 ? "" : "S")
    }

    private static let minPairs = 8
    private static let minPerBucket = 3
    private static let minRepCost = 1.0
    // Gaps outside this window aren't rests: under 45s is a logging fumble or
    // a drop set, over 8 minutes is a walk to the water fountain.
    private static let saneGap = 45.0...480.0

    /// One rest→outcome observation: the gap before a working set and how its
    /// reps compared to the set before it.
    struct Pair {
        let gapSeconds: Double
        /// reps(previous set) − reps(this set): positive = reps lost.
        let repDrop: Double
    }

    static func compute(from history: [WorkoutSet]) -> RestCalibration? {
        calibrate(pairs: pairs(from: history))
    }

    /// Extracts consecutive working-set pairs per session day.
    static func pairs(from history: [WorkoutSet]) -> [Pair] {
        let formatter = ISO8601DateFormatter()
        var bySession: [String: [(Date, Int)]] = [:]
        for set in history {
            guard set.isWarmup != true,
                  let date = set.date,
                  let reps = set.actualReps, reps > 0,
                  let stamp = set.loggedAt,
                  let at = formatter.date(from: stamp) else { continue }
            bySession[date, default: []].append((at, reps))
        }

        var out: [Pair] = []
        for (_, rows) in bySession {
            let ordered = rows.sorted { $0.0 < $1.0 }
            for (prev, next) in zip(ordered, ordered.dropFirst()) {
                let gap = next.0.timeIntervalSince(prev.0)
                guard saneGap.contains(gap) else { continue }
                out.append(Pair(gapSeconds: gap, repDrop: Double(prev.1 - next.1)))
            }
        }
        return out
    }

    /// Splits the pairs at their median gap and reports a threshold only when
    /// short rests demonstrably cost reps.
    static func calibrate(pairs: [Pair]) -> RestCalibration? {
        guard pairs.count >= minPairs else { return nil }
        let sorted = pairs.sorted { $0.gapSeconds < $1.gapSeconds }
        let median = sorted[sorted.count / 2].gapSeconds
        let short = sorted.filter { $0.gapSeconds < median }
        let long = sorted.filter { $0.gapSeconds >= median }
        guard short.count >= minPerBucket, long.count >= minPerBucket else { return nil }

        let shortDrop = short.map(\.repDrop).reduce(0, +) / Double(short.count)
        let longDrop = long.map(\.repDrop).reduce(0, +) / Double(long.count)
        let cost = shortDrop - longDrop
        guard cost >= minRepCost else { return nil }

        // Round the threshold to the nearest 15s so the receipt reads like a
        // number a human would set, not a regression artifact.
        let threshold = Int((median / 15).rounded()) * 15
        return RestCalibration(
            thresholdSeconds: max(60, threshold),
            repsDropped: Int(cost.rounded()),
            samplePairs: pairs.count
        )
    }
}
