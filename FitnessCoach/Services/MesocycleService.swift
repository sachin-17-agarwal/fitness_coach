// MesocycleService.swift
// FitnessCoach
//
// Manages mesocycle state stored in the Supabase `memory` key-value table.
// The cycle rotates through Config.cycle (Pull, Push, Legs, Cardio+Abs, Yoga)
// and tracks the current week within the mesocycle.

import Foundation

// MARK: - State

/// Represents the current position within the mesocycle programme.
struct MesocycleState: Sendable {
    /// 1-based day within the week (1...cycleLength).
    var day: Int
    /// 1-based week within the mesocycle.
    var week: Int

    /// The workout type for the current day (e.g. "Pull").
    var todayType: String {
        let index = (day - 1) % Config.cycle.count
        return Config.cycle[index]
    }

    /// `true` when this is the last day of the cycle rotation.
    var isLastDayOfCycle: Bool {
        day == Config.cycleLength
    }
}

// MARK: - Service

final class MesocycleService: Sendable {

    private let client: SupabaseClient

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    // MARK: - Load

    /// Loads the current mesocycle state from the `memory` table.
    /// Falls back to day 1 / week 1 if no rows exist yet.
    func loadState() async throws -> MesocycleState {
        let rows: [MemoryRow] = try await client.fetch(
            "memory",
            query: ["key": "in.(mesocycle_day,mesocycle_week)"]
        )

        var day = 1
        var week = 1

        for row in rows {
            switch row.key {
            case "mesocycle_day":
                day = Int(row.value) ?? 1
            case "mesocycle_week":
                week = Int(row.value) ?? 1
            default:
                break
            }
        }

        return MesocycleState(day: day, week: week)
    }

    // MARK: - Save

    /// Persists the given mesocycle state to the `memory` table.
    func saveState(_ state: MesocycleState) async throws {
        try await setMemory(key: "mesocycle_day", value: String(state.day))
        try await setMemory(key: "mesocycle_week", value: String(state.week))
    }

    // MARK: - Advance

    /// Advances to the next day (and week when a full rotation completes).
    /// Returns the updated state.
    @discardableResult
    func advance() async throws -> MesocycleState {
        var state = try await loadState()

        if state.day >= Config.cycleLength {
            state.day = 1
            state.week += 1
        } else {
            state.day += 1
        }

        try await saveState(state)
        return state
    }

    // MARK: - Helpers

    /// Upserts a single key in the `memory` table.
    private func setMemory(key: String, value: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await client.upsert(
            "memory",
            body: [
                "key": key,
                "value": value,
                "updated_at": now,
            ],
            onConflict: "key"
        )
    }
}

// MARK: - Memory row model (private to this module)

/// Lightweight Codable for rows in the `memory` key-value table.
struct MemoryRow: Codable, Sendable {
    let key: String
    let value: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case key
        case value
        case updatedAt = "updated_at"
    }
}
