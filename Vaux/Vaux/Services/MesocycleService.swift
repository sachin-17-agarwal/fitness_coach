// MesocycleService.swift
// FitnessCoach
//
// Manages mesocycle state stored in the Supabase `memory` key-value table.
// The cycle rotates through Config.cycle (Pull, Push, Legs, Cardio+Abs, Yoga)
// and tracks the current week within the mesocycle.

import Foundation

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

        // Self-heal values written before `advance()` wrapped the week: a
        // stored "week 6" is week 2 of the following mesocycle, and the
        // programme (and the coach prompt's "Week N of 4") only has 4 weeks.
        if week > Config.mesocycleWeeks {
            week = ((week - 1) % Config.mesocycleWeeks) + 1
        }

        return MesocycleState(day: day, week: week)
    }

    // MARK: - Save

    /// Persists the given mesocycle state to the `memory` table.
    ///
    /// Posts `.mesocycleDidChange` after a successful write so views that
    /// cached the previous state (Dashboard's session card, the Train tab's
    /// resolved session type) refresh instead of showing stale data. Without
    /// this, Settings → Train and Settings → Dashboard would silently
    /// disagree until the app was relaunched.
    func saveState(_ state: MesocycleState) async throws {
        try await setMemory(key: "mesocycle_day", value: String(state.day))
        try await setMemory(key: "mesocycle_week", value: String(state.week))
        NotificationCenter.default.post(name: .mesocycleDidChange, object: state)
    }

    // MARK: - Advance

    /// Advances to the next day (and week when a full rotation completes).
    /// The week wraps back to 1 after the deload week — the programme is a
    /// repeating 4-week mesocycle, not an ever-growing counter. This must
    /// mirror memory.py's advance_mesocycle, which writes the same keys when
    /// a session is ended via chat; the unwrapped `week += 1` here is how
    /// the athlete ended up being coached for "Week 5 of 4" and "Week 6".
    /// Returns the updated state.
    @discardableResult
    func advance() async throws -> MesocycleState {
        var state = try await loadState()

        if state.day >= Config.cycleLength {
            state.day = 1
            state.week = (state.week % Config.mesocycleWeeks) + 1
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

// MARK: - Notifications

extension Notification.Name {
    /// Fired after the mesocycle state has been persisted, so dependent views
    /// (Dashboard's today card, the Train tab) can refresh their local copy.
    static let mesocycleDidChange = Notification.Name("mesocycleDidChange")
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
