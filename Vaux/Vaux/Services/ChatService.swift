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
    let prescription: ServerPrescription?
    let prs: [PRInfo]?

    enum CodingKeys: String, CodingKey {
        case response
        case mesocycleDay = "mesocycle_day"
        case mesocycleWeek = "mesocycle_week"
        case prescription
        case prs
    }
}

/// A personal-record event flagged by the backend when a logged set beats
/// the historical estimated 1RM. One PRInfo per set that PR'd in this
/// message (a "warm-up 100 x 8, working 110 x 8" might emit two).
struct PRInfo: Codable, Sendable, Hashable {
    let exercise: String
    let weightKg: Double
    let reps: Int
    let estimated1RM: Double?
    let previousBest: Double?
    let improvementPct: Double?

    enum CodingKeys: String, CodingKey {
        case exercise
        case weightKg = "weight_kg"
        case reps
        case estimated1RM = "estimated_1rm"
        case previousBest = "previous_best"
        case improvementPct = "improvement_pct"
    }
}

/// Server-side parsed prescription — more reliable than client-side regex.
struct ServerPrescription: Codable, Sendable {
    let exercise: String
    let warmup: [ServerSet]?
    let working: [ServerSetWithRPE]?
    let backoff: [ServerSetWithRPE]?
    let form: String?
    let tempo: String?
    let rest: String?
    /// True when the coach marked the block `Revised:` — a deliberate
    /// structure change the app must apply verbatim.
    let revised: Bool?
}

struct ServerSet: Codable, Sendable {
    let weight: Double
    let reps: Int
    /// Top of a prescribed rep range ("x6-8" → reps 6, repsHigh 8). Absent for
    /// single-rep prescriptions.
    let repsHigh: Int?

    enum CodingKeys: String, CodingKey {
        case weight, reps
        case repsHigh = "reps_high"
    }
}

struct ServerSetWithRPE: Codable, Sendable {
    let weight: Double
    let reps: Int
    /// Top of a prescribed rep range; see `ServerSet.repsHigh`.
    let repsHigh: Int?
    let rpe: Double?

    enum CodingKeys: String, CodingKey {
        case weight, reps, rpe
        case repsHigh = "reps_high"
    }
}

/// A single message in the conversation history (maps to the `conversations` table).
///
/// The synthetic `role == "pr"` value is generated client-side from the
/// /api/chat `prs` payload and rendered as a celebration bubble. It is
/// NOT persisted to Supabase.
struct ChatMessage: Codable, Identifiable, Sendable {
    var id: UUID?
    let date: String
    let role: String
    let content: String
    let createdAt: String?
    let pr: PRInfo?

    var isUser: Bool { role == "user" }
    var isPR: Bool { role == "pr" }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case role
        case content
        case createdAt = "created_at"
        case pr
    }

    init(id: UUID? = nil, date: String, role: String, content: String,
         createdAt: String? = nil, pr: PRInfo? = nil) {
        self.id = id
        self.date = date
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.pr = pr
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id)
        self.date = try c.decode(String.self, forKey: .date)
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.pr = try c.decodeIfPresent(PRInfo.self, forKey: .pr)
    }
}

// MARK: - Service

final class ChatService: Sendable {

    private let client: SupabaseClient
    private let recoveryService: RecoveryService

    init(client: SupabaseClient = .shared) {
        self.client = client
        self.recoveryService = RecoveryService(client: client)
    }

    // MARK: - Authoritative recovery snapshot

    /// Builds the recovery snapshot the dashboard is currently showing, to send
    /// alongside chat/briefing requests. The backend coach uses this verbatim
    /// so its "today's recovery" can never disagree with what's on screen —
    /// it's read through the *same* `RecoveryService` the dashboard uses, so
    /// the row, the timezone, and the 7-day averages all match exactly.
    ///
    /// Returns `nil` if it can't be built; the backend then falls back to its
    /// own database-derived snapshot, so chat still works.
    private func recoverySnapshot() async -> [String: Any]? {
        do {
            async let latest = recoveryService.fetchLatest()
            async let averages = recoveryService.fetch7DayAverages()

            guard let rec = try await latest else { return nil }
            let (hrvAvg, rhrAvg) = try await averages

            var snap: [String: Any] = ["date": rec.date]
            if let v = rec.sleepHours       { snap["sleep_hours"] = v }
            if let v = rec.hrv              { snap["hrv"] = v }
            if let v = rec.hrvStatus        { snap["hrv_status"] = v }
            if let v = rec.restingHr        { snap["resting_hr"] = v }
            if let v = rec.heartRate        { snap["heart_rate"] = v }
            if let v = rec.steps            { snap["steps"] = v }
            if let v = rec.activeEnergyKcal { snap["active_energy_kcal"] = v }
            if let v = rec.weightKg         { snap["weight_kg"] = v }
            if let v = rec.bodyFatPct       { snap["body_fat_pct"] = v }
            if let v = rec.exerciseMinutes  { snap["exercise_minutes"] = v }
            if let v = rec.respiratoryRate  { snap["respiratory_rate"] = v }
            if let v = rec.vo2Max           { snap["vo2_max"] = v }
            if let v = hrvAvg               { snap["hrv_avg"] = v }
            if let v = rhrAvg               { snap["resting_hr_baseline"] = v }
            if let score = rec.compositeScore(hrv7DayAvg: hrvAvg, rhr7DayAvg: rhrAvg) {
                snap["recovery_score"] = score
                snap["recovery_zone"] = Self.zone(for: score)
            }
            return snap
        } catch {
            return nil
        }
    }

    /// Mirrors `DashboardViewModel.recoveryColor` so the coach names the same
    /// zone the dashboard paints.
    private static func zone(for score: Int) -> String {
        if score >= 75 { return "GREEN" }
        if score >= 55 { return "YELLOW" }
        return "RED"
    }

    // MARK: - Send message to backend

    /// Posts the user's message to the Railway backend and returns the
    /// assistant's response. The backend persists both messages to the
    /// `conversations` table, so the client does not save them here (doing
    /// so would double-insert every message).
    func sendMessage(_ text: String) async throws -> ChatResponse {
        return try await callBackend(text)
    }

    /// Trigger the backend's morning briefing using the user's saved
    /// `briefing_style` preference. The backend constructs the prompt so
    /// the iOS button and the Telegram morning auto stay in sync.
    func runMorningBriefing() async throws -> ChatResponse {
        return try await callBriefingBackend()
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

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = RetryConfig.chatTimeout

        var payload: [String: Any] = ["message": message]
        if let recovery = await recoverySnapshot() {
            payload["recovery"] = recovery
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let request = req

        // Retry only on transient URLError. HTTP 5xx is NOT retried because
        // the backend may have already persisted the user message + Claude
        // response to the conversations table, and a retry would duplicate.
        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: request)
        }

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

    private func callBriefingBackend() async throws -> ChatResponse {
        let rawURL = Config.backendURL
        let token = Config.appAPIToken

        let base = rawURL.hasSuffix("/") ? String(rawURL.dropLast()) : rawURL
        // Strip a trailing /api/chat if the user pasted the chat URL into
        // settings — both endpoints share the same base.
        let trimmed = base.hasSuffix("/api/chat")
            ? String(base.dropLast("/api/chat".count))
            : base
        let urlString = "\(trimmed)/api/briefing"

        guard let url = URL(string: urlString) else {
            throw ChatServiceError.invalidURL(urlString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = RetryConfig.chatTimeout
        var payload: [String: Any] = [:]
        if let recovery = await recoverySnapshot() {
            payload["recovery"] = recovery
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let request = req

        let (data, response) = try await withRetry {
            try await URLSession.shared.data(for: request)
        }

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw ChatServiceError.backendError(statusCode: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data)
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
