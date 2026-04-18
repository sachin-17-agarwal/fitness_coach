// WorkoutSummary.swift
// FitnessCoach

import Foundation

/// Summary displayed after ending a workout session.
struct WorkoutSummary: Sendable {
    var tonnage: Double
    var totalSets: Int
    var duration: TimeInterval
    var prs: [PRResult]
}
