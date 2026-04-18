// BriefingViewModel.swift
// Vaux

import Foundation
import Observation

@Observable
final class BriefingViewModel {
    var briefing: Briefing?
    var isLoading = false
    var errorMessage: String?

    private let service = BriefingService()

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            briefing = try await service.load()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            briefing = try await service.load(forceRefresh: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func markShown() {
        service.markShown()
    }
}
