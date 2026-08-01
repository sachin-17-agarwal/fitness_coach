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

    /// Today's session: the rotation, with the yoga day overriding it.
    var sessionType: String {
        Config.isYogaDay() ? Config.yogaSessionType : rotationSessionType
    }

    /// Where the resistance rotation is standing, ignoring the yoga override.
    /// On a yoga day this is the session that Sunday passed over and which
    /// therefore comes up next.
    var rotationSessionType: String {
        Config.cycle[(day - 1) % Config.cycle.count]
    }

    /// Tomorrow's session. Three cases: tomorrow is the yoga day; today IS the
    /// yoga day, so the rotation position Sunday passed over is next; or the
    /// ordinary case of stepping one along.
    var nextSessionType: String {
        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        if Config.isYogaDay(tomorrow) { return Config.yogaSessionType }
        if Config.isYogaDay() { return rotationSessionType }
        return Config.cycle[day % Config.cycle.count]
    }

    var todayType: String { sessionType }

    var isLastDayOfCycle: Bool {
        day == Config.cycle.count
    }
}
