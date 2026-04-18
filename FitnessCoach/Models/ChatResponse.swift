// ChatResponse.swift
// FitnessCoach

import Foundation

/// Response from the /api/chat backend endpoint.
struct ChatResponse: Codable, Sendable {
    var response: String
    var mesocycleDay: Int?
    var mesocycleWeek: Int?

    enum CodingKeys: String, CodingKey {
        case response
        case mesocycleDay = "mesocycle_day"
        case mesocycleWeek = "mesocycle_week"
    }
}
