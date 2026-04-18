// ExercisePrescription.swift
// FitnessCoach

import Foundation

/// Parsed exercise prescription from AI coach response.
struct ExercisePrescription: Identifiable, Sendable {
    var id = UUID()
    var exerciseName: String
    var warmupSets: Int
    var workingSets: Int
    var backoffSets: Int
    var targetWeightKg: Double?
    var targetReps: Int?
    var targetRpe: Double?
    var backoffWeightKg: Double?
    var backoffReps: Int?
    var formCue: String?
    var restSeconds: Int?
}
