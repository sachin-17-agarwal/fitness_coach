// PRResult.swift
// FitnessCoach

import Foundation

/// Result of a PR check after logging a set.
struct PRResult: Sendable {
    var exercise: String
    var isPR: Bool
    var estimated1RM: Double?
    var previous1RM: Double?
}
