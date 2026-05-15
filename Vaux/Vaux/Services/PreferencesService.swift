// PreferencesService.swift
// Vaux
//
// Read/write small per-user preferences that live in the Supabase `memory`
// table. Keeping them server-side means the morning Telegram briefing and
// the in-app Briefing button always agree on the user's chosen style.

import Foundation

/// Available coach personalities for the morning briefing.
enum BriefingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case concise = "concise"
    case detailed = "detailed"
    case drillSergeant = "drill_sergeant"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concise:       return "Concise"
        case .detailed:      return "Detailed"
        case .drillSergeant: return "Drill Sergeant"
        }
    }

    var blurb: String {
        switch self {
        case .concise:       return "4-6 bullets. Headline numbers only."
        case .detailed:      return "Full breakdown: recovery, sets, RPE, progression."
        case .drillSergeant: return "No-nonsense. Direct, demanding, zero fluff."
        }
    }
}

/// Row shape for the `memory` table — `(key, value, updated_at)`.
private struct MemoryRow: Decodable {
    let key: String
    let value: String
}

final class PreferencesService: Sendable {
    private let client: SupabaseClient

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    func loadBriefingStyle() async -> BriefingStyle {
        do {
            let rows: [MemoryRow] = try await client.fetch(
                "memory",
                query: ["key": "eq.briefing_style"],
                limit: 1
            )
            if let raw = rows.first?.value,
               let style = BriefingStyle(rawValue: raw) {
                return style
            }
        } catch {
            print("[PreferencesService] loadBriefingStyle failed: \(error.localizedDescription)")
        }
        return .detailed
    }

    func saveBriefingStyle(_ style: BriefingStyle) async throws {
        let body: [String: Any] = [
            "key": "briefing_style",
            "value": style.rawValue,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        _ = try await client.upsert("memory", body: body, onConflict: "key")
    }
}
