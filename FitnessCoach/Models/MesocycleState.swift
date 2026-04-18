// MesocycleState.swift
// FitnessCoach

import Foundation

/// Tracks the current position within the mesocycle programme.
///
/// `week` is 1-based (e.g. week 1 of 4).
/// `day` is 1-based within the overall cycle rotation.
struct MesocycleState {
    var week: Int
    var day: Int

    /// The session type for the current day (e.g. "Pull", "Push", "Legs").
    var sessionType: String {
        Config.cycle[(day - 1) % Config.cycle.count]
    }

    /// The session type for the next day in the rotation.
    var nextSessionType: String {
        Config.cycle[day % Config.cycle.count]
    }
}
