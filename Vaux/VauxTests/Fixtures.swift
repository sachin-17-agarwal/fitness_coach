// Fixtures.swift
// VauxTests
//
// Builders for the rows the pure calculations read, so a test states only
// what matters to it. Dates are strings in the app's own "yyyy-MM-dd" form.

import Foundation
@testable import Vaux

enum Fixtures {
    static func set(_ exercise: String, on date: String, number: Int = 1, warmup: Bool = false,
                    weight: Double, reps: Int, rpe: Double? = nil, session: UUID? = nil) -> WorkoutSet {
        WorkoutSet(id: UUID(), workoutSessionId: session, date: date, exercise: exercise, setNumber: number,
                   isWarmup: warmup, actualWeightKg: weight, actualReps: reps, actualRpe: rpe)
    }

    static func session(_ type: String, on date: String, week: Int? = nil, day: Int? = nil,
                        status: String = "completed", id: UUID = UUID()) -> WorkoutSession {
        WorkoutSession(id: id, date: date, type: type, status: status, mesocycleWeek: week, mesocycleDay: day)
    }

    static func recovery(_ date: String, sleep: Double? = nil, hrv: Double? = nil, rhr: Double? = nil,
                         weight: Double? = nil) -> Recovery {
        Recovery(date: date, sleepHours: sleep, hrv: hrv, restingHr: rhr, weightKg: weight)
    }

    static func point(block: Int, week: Int, e1rm: Double, weight: Double? = nil, reps: Int = 8,
                      rpe: Double? = 8) -> (BlockPosition, LiftBlockPoint) {
        let pos = BlockPosition(block: block, week: week)
        return (pos, LiftBlockPoint(position: pos, e1rm: e1rm, weight: weight ?? e1rm * 0.8, reps: reps, rpe: rpe))
    }

    static func date(_ ymd: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: ymd)!
    }
}
