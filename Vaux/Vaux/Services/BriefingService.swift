// BriefingService.swift
// Vaux
//
// Generates and caches the daily morning briefing.  The briefing combines
// locally-sourced data (recovery, mesocycle) with a freshly-generated note
// from Claude so the user gets one cohesive "morning read" each day.

import Foundation

final class BriefingService: Sendable {

    private let chatService: ChatService
    private let recoveryService: RecoveryService
    private let mesocycleService: MesocycleService
    private let defaults: UserDefaults

    init(
        chatService: ChatService = ChatService(),
        recoveryService: RecoveryService = RecoveryService(),
        mesocycleService: MesocycleService = MesocycleService(),
        defaults: UserDefaults = .standard
    ) {
        self.chatService = chatService
        self.recoveryService = recoveryService
        self.mesocycleService = mesocycleService
        self.defaults = defaults
    }

    // MARK: - Public

    /// Build today's briefing. Uses the cached coach note if one already exists
    /// for today; otherwise requests a new one from Claude.
    func load(forceRefresh: Bool = false) async throws -> Briefing {
        let today = RecoveryService.todayString()

        async let recoveryLatest = recoveryService.fetchLatest()
        async let recoveryAvgs = recoveryService.fetch7DayAverages()
        async let meso = mesocycleService.loadState()

        let recovery = try await recoveryLatest
        let (hrvAvg, rhrAvg) = try await recoveryAvgs
        let mesocycle = try await meso

        let note: String
        if !forceRefresh, let cached = cached(for: today) {
            note = cached.coachNote
        } else {
            note = try await generateCoachNote(
                recovery: recovery,
                hrvAvg: hrvAvg,
                rhrAvg: rhrAvg,
                mesocycle: mesocycle
            )
            persist(CachedBriefing(
                date: today,
                coachNote: note,
                generatedAt: Date(),
                shown: false
            ))
        }

        return Briefing(
            date: today,
            recovery: recovery,
            hrv7DayAvg: hrvAvg,
            rhr7DayAvg: rhrAvg,
            mesocycle: mesocycle,
            coachNote: note,
            generatedAt: Date()
        )
    }

    /// Whether the briefing for today has already been shown to the user.
    /// Used by the app shell to auto-present once per day.
    func hasBeenShownToday() -> Bool {
        let today = RecoveryService.todayString()
        return cached(for: today)?.shown ?? false
    }

    /// Mark today's briefing as shown so we don't auto-present again.
    func markShown() {
        let today = RecoveryService.todayString()
        guard var c = cached(for: today) else { return }
        c.shown = true
        persist(c)
    }

    // MARK: - Claude coach note

    private func generateCoachNote(
        recovery: Recovery?,
        hrvAvg: Double?,
        rhrAvg: Double?,
        mesocycle: MesocycleState
    ) async throws -> String {
        var facts: [String] = []
        if let hrv = recovery?.hrv {
            facts.append("HRV today: \(Int(hrv)) ms")
        }
        if let avg = hrvAvg {
            facts.append("HRV 7d avg: \(Int(avg)) ms")
        }
        if let rhr = recovery?.restingHr {
            facts.append("Resting HR: \(Int(rhr)) bpm")
        }
        if let avg = rhrAvg {
            facts.append("RHR 7d avg: \(Int(avg)) bpm")
        }
        if let sleep = recovery?.sleepHours {
            facts.append("Sleep: \(String(format: "%.1f", sleep))h")
        }
        if let weight = recovery?.weightKg {
            facts.append("Weight: \(String(format: "%.1f", weight))kg")
        }
        facts.append("Today: \(mesocycle.sessionType) (week \(mesocycle.week), day \(mesocycle.day))")

        let prompt = """
        Morning briefing request. Context:
        \(facts.joined(separator: "\n"))

        Give me a brief, direct morning read — 3 to 4 short sentences max. \
        Start by calling out how recovery looks today (green/yellow/red), \
        then the training angle for the \(mesocycle.sessionType) session \
        (intensity, load target, anything to be careful about). \
        End with one concrete action. \
        No headers, no bullet points, no markdown — just flowing prose.
        """

        let response = try await chatService.sendMessage(prompt)
        return response.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cache

    private func cacheKey(for date: String) -> String { "briefing_\(date)" }

    private func cached(for date: String) -> CachedBriefing? {
        guard let data = defaults.data(forKey: cacheKey(for: date)) else { return nil }
        return try? JSONDecoder().decode(CachedBriefing.self, from: data)
    }

    private func persist(_ briefing: CachedBriefing) {
        guard let data = try? JSONEncoder().encode(briefing) else { return }
        defaults.set(data, forKey: cacheKey(for: briefing.date))
    }
}
