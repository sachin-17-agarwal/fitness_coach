// ChatService.swift
// FitnessCoach
//
// Sends messages to the Flask backend on Railway and persists conversation
// history in the Supabase `conversations` table.

import Foundation

// MARK: - Response / Message types

/// Response payload returned by the backend `/api/chat` endpoint.
struct ChatResponse: Codable, Sendable {
    let response: String
    let mesocycleDay: Int?
    let mesocycleWeek: Int?

    enum CodingKeys: String, CodingKey {
        case response
        case mesocycleDay = "mesocycle_day"
        case mesocycleWeek = "mesocycle_week"
    }
}

/// A single message in the conversation history (maps to the `conversations` table).
struct ChatMessage: Codable, Identifiable, Sendable {
    var id: UUID?
    let date: String
    let role: String
    let content: String
    let createdAt: String?

    var isUser: Bool { role == "user" }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case role
        case content
        case createdAt = "created_at"
    }
}

// MARK: - Service

final class ChatService: Sendable {

    private let client: SupabaseClient

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    // MARK: - Send message to backend

    /// Posts the user's message to the Railway backend and returns the
    /// assistant's response.  Also persists both the user and assistant
    /// messages to the `conversations` table.
    func sendMessage(_ text: String) async throws -> ChatResponse {
        // 1. Save user message (best-effort — don't block the backend call)
        try? await saveMessage(role: "user", content: text)

        // 2. Call backend (this is the critical path)
        let chatResponse = try await callBackend(text)

        // 3. Save assistant reply (best-effort)
        try? await saveMessage(role: "assistant", content: chatResponse.response)

        return chatResponse
    }

    // MARK: - Conversation history

    /// Loads today's conversation from Supabase, oldest first.
    func loadTodayConversation() async throws -> [ChatMessage] {
        let today = Self.todayString()
        let messages: [ChatMessage] = try await client.fetch(
            "conversations",
            query: ["date": "eq.\(today)"],
            order: "created_at.asc"
        )
        return messages
    }

    /// Saves a single message to the `conversations` table.
    func saveMessage(role: String, content: String) async throws {
        let today = Self.todayString()
        let now = ISO8601DateFormatter().string(from: Date())
        try await client.insert("conversations", body: [
            "date": today,
            "role": role,
            "content": content,
            "created_at": now,
        ])
    }

    // MARK: - Backend call

    /// Sends a POST request to the Flask backend's `/api/chat` endpoint.
    private func callBackend(_ message: String) async throws -> ChatResponse {
        let rawURL = Config.backendURL
        let token = Config.appAPIToken

        let urlString: String
        if rawURL.contains("/api/chat") {
            urlString = rawURL
        } else {
            let base = rawURL.hasSuffix("/") ? String(rawURL.dropLast()) : rawURL
            urlString = "\(base)/api/chat"
        }

        guard let url = URL(string: urlString) else {
            throw ChatServiceError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let payload: [String: Any] = ["message": message]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw ChatServiceError.backendError(statusCode: http.statusCode, body: body)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ChatResponse.self, from: data)
        } catch {
            throw ChatServiceError.decodingFailed(error)
        }
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }
}

// MARK: - Errors

enum ChatServiceError: LocalizedError {
    case invalidURL(String)
    case backendError(statusCode: Int, body: String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid backend URL: \(url)"
        case .backendError(let code, let body):
            return "Backend error HTTP \(code): \(body)"
        case .decodingFailed(let error):
            return "Failed to decode backend response: \(error.localizedDescription)"
        }
    }
}
