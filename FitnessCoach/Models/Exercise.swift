// Exercise.swift
// FitnessCoach

import Foundation

/// An exercise definition from the Supabase `exercises` table.
struct Exercise: Codable, Identifiable, Sendable {
    var id: UUID?
    var name: String
    var muscleGroup: String?
    var aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case muscleGroup = "muscle_group"
        case aliases
    }
}
