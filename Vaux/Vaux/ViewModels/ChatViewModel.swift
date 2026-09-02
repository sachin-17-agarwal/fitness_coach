// ChatViewModel.swift
// FitnessCoach

import Foundation
import Observation

@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText = ""
    var isLoading = false
    var errorMessage: String?

    /// What the coach is looking at today, shown under the header so the
    /// athlete sees the same context the coach reasons from.
    var mesocycle: MesocycleState?
    var readinessScore: Int?

    private let chatService = ChatService()
    private let mesocycleService = MesocycleService()
    private let recoveryService = RecoveryService()

    /// "TUESDAY · PULL · WEEK 1 BASELINE" — the day always renders; the
    /// session and block appear once the mesocycle state has loaded.
    var contextLine: String {
        var parts = [Date().formatted(.dateTime.weekday(.wide))]
        if let mesocycle {
            parts.append(mesocycle.sessionType)
            var block = "Week \(mesocycle.week)"
            if let phase = Self.phaseLabel(week: mesocycle.week) { block += " \(phase)" }
            parts.append(block)
        }
        return parts.joined(separator: " · ")
    }

    var readinessLabel: String? {
        readinessScore.map { "Ready \($0)%" }
    }

    private static func phaseLabel(week: Int) -> String? {
        switch week {
        case 1: return "Baseline"
        case 2: return "Volume"
        case 3: return "Peak"
        case 4: return "Deload"
        default: return nil
        }
    }

    /// Loads the header context. Failures leave the line at the day alone —
    /// this is decoration on a chat screen, never a reason to show an error.
    func loadContext() async {
        async let state = mesocycleService.loadState()
        async let latest = recoveryService.fetchLatest()
        async let averages = recoveryService.fetch7DayAverages()

        if let loaded = try? await state {
            mesocycle = loaded
        }
        let recovery = (try? await latest) ?? nil
        let avgs = try? await averages
        if let recovery {
            readinessScore = recovery.compositeScore(hrv7DayAvg: avgs?.hrvAvg, rhr7DayAvg: avgs?.rhrAvg)
        }
    }

    func loadConversation() async {
        do {
            messages = try await chatService.loadTodayConversation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMessage = ChatMessage(
            id: UUID(),
            date: RecoveryService.todayString(),
            role: "user",
            content: text,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(userMessage)
        inputText = ""
        isLoading = true

        do {
            let response = try await chatService.sendMessage(text)

            // PR celebrations come back as a separate `prs` array on the
            // ChatResponse. Inject one synthetic "pr" bubble per PR so the
            // chat shows the celebration above the coach's text response.
            for pr in response.prs ?? [] {
                let prMessage = ChatMessage(
                    id: UUID(),
                    date: RecoveryService.todayString(),
                    role: "pr",
                    content: "",
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    pr: pr
                )
                messages.append(prMessage)
                Haptic.success()
            }

            let assistantMessage = ChatMessage(
                id: UUID(),
                date: RecoveryService.todayString(),
                role: "assistant",
                content: response.response,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(assistantMessage)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func sendMorningBriefing() async {
        isLoading = true
        errorMessage = nil

        // Insert a placeholder user message so the chat shows what the user
        // tapped. The backend constructs the real prompt using the saved
        // briefing_style so this string is purely cosmetic.
        let placeholder = ChatMessage(
            id: UUID(),
            date: RecoveryService.todayString(),
            role: "user",
            content: "Morning briefing",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(placeholder)

        do {
            let response = try await chatService.runMorningBriefing()

            for pr in response.prs ?? [] {
                let prMessage = ChatMessage(
                    id: UUID(),
                    date: RecoveryService.todayString(),
                    role: "pr",
                    content: "",
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    pr: pr
                )
                messages.append(prMessage)
                Haptic.success()
            }

            let assistantMessage = ChatMessage(
                id: UUID(),
                date: RecoveryService.todayString(),
                role: "assistant",
                content: response.response,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(assistantMessage)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
