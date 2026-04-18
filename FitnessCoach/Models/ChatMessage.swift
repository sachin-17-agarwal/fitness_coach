// ChatMessage.swift
// FitnessCoach

import Foundation

/// A single chat message stored in the Supabase `chat_messages` table.
struct ChatMessage: Codable, Identifiable, Sendable {
    var id: UUID?
    var date: String
    var role: String
    var content: String
    var createdAt: String?

    /// `true` when this message was sent by the user (as opposed to the assistant).
    var isUser: Bool { role == "user" }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case role
        case content
        case createdAt = "created_at"
    }
}
