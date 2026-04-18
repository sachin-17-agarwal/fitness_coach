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
        inputText = "Give me my morning briefing. Include my recovery status, today's training session type, and any recommendations based on my metrics."
        await sendMessage()
    }
}
