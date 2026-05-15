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

    private let chatService = ChatService()

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
