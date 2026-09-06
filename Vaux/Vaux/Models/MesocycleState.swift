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
    /// A manual replacement for today's computed session, when the athlete has
    /// set one. Outranks both the rotation and the yoga day.
    var todayOverride: String? = nil

    /// Today's session: the rotation, with the yoga day overriding it, and an
    /// explicit override outranking both.
    var sessionType: String {
        if let todayOverride { return todayOverride }
        return Config.isRestDay() ? Config.restSessionType : rotationSessionType
    }

    /// Whether today's session is a manual choice rather than the schedule's.
    var isOverridden: Bool { todayOverride != nil }

    /// Where the resistance rotation is standing, ignoring the yoga override.
    /// On a yoga day this is the session that Sunday passed over and which
    /// therefore comes up next.
    var rotationSessionType: String {
        Config.cycle[(day - 1) % Config.cycle.count]
    }

    /// Tomorrow's session. Three cases: tomorrow is the yoga day; today IS the
    /// yoga day, so the rotation position Sunday passed over is next; or the
    /// ordinary case of stepping one along.
    ///
    /// The middle case keys off what is actually being trained today rather
    /// than the weekday, so an override that replaces a Sunday's yoga with a
    /// rotation session consumes the slot and tomorrow steps along normally.
    /// Mirrors `next_session_type_for` in data.py.
    var nextSessionType: String {
        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        if Config.isRestDay(tomorrow) { return Config.restSessionType }
        if Config.nonSlotSessionTypes.contains(sessionType) { return rotationSessionType }
        return Config.cycle[day % Config.cycle.count]
    }

    var todayType: String { sessionType }

    var isLastDayOfCycle: Bool {
        day == Config.cycle.count
    }
}
