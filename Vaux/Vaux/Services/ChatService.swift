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

/// `/api/session/open`: the programme's card at once, the coach's review to
/// follow. `status` is "reviewing" (response carries the programme's plan) or
/// "unavailable" (open through /api/chat as before).
struct SessionOpenResponse: Codable, Sendable {
    let status: String
    let response: String?
    let mesocycleDay: Int?
    let mesocycleWeek: Int?

    enum CodingKeys: String, CodingKey {
        case status, response
        case mesocycleDay = "mesocycle_day"
        case mesocycleWeek = "mesocycle_week"
    }
}

/// One exercise the coach's review changed against the programme, with the
/// coach's own reason.
struct PlanChange: Codable, Sendable, Hashable {
    let exercise: String
    let change: String
    let from: String?
    let to: String?
    let why: String?
}

/// `/api/session/status`: none | reviewing | reviewed (+response, changes) | failed.
struct SessionStatusResponse: Codable, Sendable {
    let status: String
    let response: String?
    let changes: [PlanChange]?
    let error: String?
}

/// `/api/block-review`: the latest block review with its status — none |
/// shown | answered. `text` is what the athlete reads; `proposals` the
/// numbered recordable lines an answer refers to.
struct BlockReviewResponse: Codable, Sendable {
    struct Proposal: Codable, Sendable, Hashable {
        let line: String
        let rationale: String?
        /// "decision" or "emphasis"; the lift or muscle; the rest of the line.
        let kind: String?
        let subject: String?
        let detail: String?
    }
    /// One labelled paragraph of the narrative ("STRENGTH", "VOLUME", …).
    struct Section: Codable, Sendable, Hashable {
        let label: String
        let body: String
    }
    struct Window: Codable, Sendable {
        let since: String?
        let until: String?
    }
    /// One lift's block-over-block change, from the fact sheet.
    struct Lift: Codable, Sendable, Hashable {
        let exercise: String
        let deltaPct: Double?
        let verdict: String?
        let thisSet: String?
        let prevSet: String?
        enum CodingKeys: String, CodingKey {
            case exercise, verdict
            case deltaPct = "delta_pct"
            case thisSet = "this_set"
            case prevSet = "prev_set"
        }
    }
    /// One muscle's sets per week against its band.
    struct VolumeRow: Codable, Sendable, Hashable {
        let muscle: String
        let sets: Double?
        let band: String?
        let underBy: Double?
        let overBy: Double?
        enum CodingKeys: String, CodingKey {
            case muscle, sets, band
            case underBy = "under_by"
            case overBy = "over_by"
        }
    }
    let status: String
    let blockStart: String?
    let dryRun: Bool?
    let text: String?
    let proposals: [Proposal]?
    let sections: [Section]?
    let window: Window?
    let lifts: [Lift]?
    let volume: [VolumeRow]?

    enum CodingKeys: String, CodingKey {
        case status, text, proposals, sections, window, lifts, volume
        case blockStart = "block_start"
        case dryRun = "dry_run"
    }

    var isOpen: Bool { status == "shown" }
}

/// `/api/block-review/answer`: what the coach said back, and the new status.
struct BlockReviewAnswerResponse: Codable, Sendable {
    let status: String
    let message: String
}

/// `/api/decision/pending`: a decision the coach proposed in chat that the
/// athlete has not yet recorded or declined. `text` is the line in plain
/// words; `kind` is constraint (a load cap) or emphasis (next block).
struct DecisionCapture: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let line: String
    let kind: String
    let text: String
    let proposedAt: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case id, line, kind, text
        case proposedAt = "proposed_at"
        case sessionId = "session_id"
    }

    var eyebrow: String { kind == "emphasis" ? "DECISION · NEXT BLOCK" : "DECISION · STANDING" }
}

struct DecisionPendingResponse: Codable, Sendable {
    let captures: [DecisionCapture]
}

struct DecisionAnswerResponse: Codable, Sendable {
    let status: String
    let message: String
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
            if let v = ReadinessStore.today { snap["readiness"] = v }
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
        do {
            return try await callBackend(text)
        } catch let error where Self.deliveryUnknown(error) {
            // Backgrounding the app while the coach is thinking kills the
            // connection, and the athlete sees "The network connection was
            // lost". But the backend does not stop: handle_incoming_message
            // persists BOTH turns to `conversations` before it answers, so by
            // the time this fires the reply usually exists and only its
            // delivery was lost.
            //
            // Retrying is not the fix and was already tried — an identical
            // second POST made the coach see its own message twice. Recover
            // the reply that is already there instead.
            if let recovered = await recoverReply(to: text) {
                return recovered
            }
            throw error
        }
    }

    /// Whether a failure says nothing about whether the server acted.
    ///
    /// The write may have been delivered and completed, so this is exactly the
    /// class that must not be retried — and exactly the class worth recovering.
    private static func deliveryUnknown(_ error: Error) -> Bool {
        // Cast before matching: a case pattern cannot be applied to an `Error`
        // existential directly.
        if let retryError = error as? RetryableRequestError,
           case .allAttemptsFailed(let underlying) = retryError {
            return deliveryUnknown(underlying)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .resourceUnavailable,
             .cancelled, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    /// Poll today's conversation for the answer to `text`.
    ///
    /// A long prompt can take Claude 30-50s, so the reply may not be written
    /// yet when the connection drops. Backs off rather than giving up on the
    /// first look; returns nil if nothing arrives, and the caller then surfaces
    /// the original error rather than inventing a reply.
    private func recoverReply(to text: String) async -> ChatResponse? {
        let sent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for delaySeconds in [2.0, 4.0, 8.0, 16.0] {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let messages = try? await loadTodayConversation() else { continue }
            // The reply is the first assistant turn AFTER the message just
            // sent. Matching on the text rather than the tail of the list so a
            // reply to some earlier message is never mistaken for this one.
            guard let sentIndex = messages.lastIndex(where: {
                $0.isUser &&
                $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == sent
            }) else { continue }
            let reply = messages[messages.index(after: sentIndex)...]
                .first { $0.role == "assistant" }
            if let reply {
                return ChatResponse(
                    response: reply.content,
                    mesocycleDay: nil,
                    mesocycleWeek: nil,
                    prescription: nil,
                    prs: nil
                )
            }
        }
        return nil
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
    /// Base URL without a pasted /api/chat suffix; every endpoint shares it.
    private var backendBase: String {
        var raw = Config.backendURL
        if let r = raw.range(of: "/api/chat") { raw = String(raw[..<r.lowerBound]) }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// START pressed: the programme's plan at once. The coach's review runs
    /// on the server; poll `sessionStatus()` for it.
    func openSession(type: String, message: String, sessionId: String?) async throws -> SessionOpenResponse {
        let urlString = "\(backendBase)/api/session/open"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        var payload: [String: Any] = ["session_type": type, "message": message]
        if let sessionId { payload["session_id"] = sessionId }
        if let recovery = await recoverySnapshot() { payload["recovery"] = recovery }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
        do { return try JSONDecoder().decode(SessionOpenResponse.self, from: data) }
        catch { throw ChatServiceError.decodingFailed(error) }
    }

    /// Where the coach's review of today's opening stands.
    func sessionStatus() async throws -> SessionStatusResponse {
        let urlString = "\(backendBase)/api/session/status"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
        do { return try JSONDecoder().decode(SessionStatusResponse.self, from: data) }
        catch { throw ChatServiceError.decodingFailed(error) }
    }

    /// The latest block review for the Home card. Preparing it, the morning
    /// after a block rolls over, happens on the server inside this call.
    func blockReview() async throws -> BlockReviewResponse {
        let urlString = "\(backendBase)/api/block-review"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60   // the first call after rollover writes the review
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
        do { return try JSONDecoder().decode(BlockReviewResponse.self, from: data) }
        catch { throw ChatServiceError.decodingFailed(error) }
    }

    /// Answer the open review in the same grammar chat accepts: "approve all",
    /// "yes to 1 and 3", "no".
    func answerBlockReview(_ text: String) async throws -> BlockReviewAnswerResponse {
        let urlString = "\(backendBase)/api/block-review/answer"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
        do { return try JSONDecoder().decode(BlockReviewAnswerResponse.self, from: data) }
        catch { throw ChatServiceError.decodingFailed(error) }
    }

    /// Proposals the coach made in chat that are still waiting for an answer.
    func pendingDecisions() async throws -> [DecisionCapture] {
        let urlString = "\(backendBase)/api/decision/pending"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
        do { return try JSONDecoder().decode(DecisionPendingResponse.self, from: data).captures }
        catch { throw ChatServiceError.decodingFailed(error) }
    }

    /// Record or decline one proposal. Record applies it through the same
    /// path a `Decision:` line in chat takes.
    func answerDecision(id: Int, record: Bool) async throws -> DecisionAnswerResponse {
        let urlString = "\(backendBase)/api/decision/answer"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "answer": record ? "record" : "decline"])
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
        do { return try JSONDecoder().decode(DecisionAnswerResponse.self, from: data) }
        catch { throw ChatServiceError.decodingFailed(error) }
    }

    /// The Strength tab's block number, handed to the backend so the widget
    /// shows the same figure without the app running. Fire-and-forget.
    func postWidgetStrength(medianGainPct: Double?, lifts: Int, block: Int, week: Int) async throws {
        let urlString = "\(backendBase)/api/widget/strength"
        guard let url = URL(string: urlString) else { throw ChatServiceError.invalidURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Config.appAPIToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["lifts": lifts, "block": block, "week": week]
        if let medianGainPct { body["median_gain_pct"] = medianGainPct }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.backendError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8) ?? "(no body)")
        }
    }

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

        // Not idempotent: this appends to the conversation and bills a Claude
        // call. Backgrounding the app mid-request drops the connection or
        // runs out the timeout while the backend goes on to finish the work,
        // so retrying on those sent the identical message a second time —
        // the coach saw its own log twice and replied "same message coming
        // through twice". Only pre-delivery failures are retried now.
        let (data, response) = try await withRetry(idempotent: false) {
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

        // Same hazard as the chat endpoint — a briefing writes to the
        // conversation and costs a Claude call.
        let (data, response) = try await withRetry(idempotent: false) {
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
