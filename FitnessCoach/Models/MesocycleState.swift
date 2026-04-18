// MesocycleState.swift
// FitnessCoach

import Foundation

/// Tracks the current position within the mesocycle programme.
///
/// `week` is 1-based (e.g. week 1 of 4).
/// `day` is 1-based within the overall cycle rotation.
struct MesocycleState: Sendable {
    var day: Int
    var week: Int

    var sessionType: String {
        Config.cycle[(day - 1) % Config.cycle.count]
    }

    var nextSessionType: String {
        Config.cycle[day % Config.cycle.count]
    }

    var todayType: String { sessionType }

    var isLastDayOfCycle: Bool {
        day == Config.cycle.count
    }
}
