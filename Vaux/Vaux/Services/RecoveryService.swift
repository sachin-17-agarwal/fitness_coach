// RecoveryService.swift
// FitnessCoach
//
// Reads and writes recovery data from the Supabase `recovery` table.

import Foundation

final class RecoveryService: Sendable {

    private let client: SupabaseClient

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    // MARK: - Fetch latest recovery row (most recent up to today)

    /// Returns the single most-recent recovery row whose date <= today, or `nil`
    /// if the table is empty.
    func fetchLatest() async throws -> Recovery? {
        let today = Self.todayString()
        let rows: [Recovery] = try await client.fetch(
            "recovery",
            query: ["date": "lte.\(today)"],
            order: "date.desc",
            limit: 1
        )
        return rows.first
    }

    // MARK: - Fetch history

    /// Returns recovery rows for the last `days` calendar days, newest first.
    func fetchHistory(days: Int) async throws -> [Recovery] {
        let since = Self.dateString(daysAgo: days)
        let rows: [Recovery] = try await client.fetch(
            "recovery",
            query: ["date": "gte.\(since)"],
            order: "date.desc"
        )
        return rows
    }

    // MARK: - 7-day averages

    /// Returns the 7-day rolling average for HRV and resting heart rate.
    /// `nil` components mean no data was available.
    func fetch7DayAverages() async throws -> (hrvAvg: Double?, rhrAvg: Double?) {
        let rows = try await fetchHistory(days: 7)

        let hrvValues = rows.compactMap(\.hrv)
        let rhrValues = rows.compactMap(\.restingHr)

        let hrvAvg: Double? = hrvValues.isEmpty
            ? nil
            : hrvValues.reduce(0, +) / Double(hrvValues.count)

        let rhrAvg: Double? = rhrValues.isEmpty
            ? nil
            : rhrValues.reduce(0, +) / Double(rhrValues.count)

        return (hrvAvg, rhrAvg)
    }

    // MARK: - Save / upsert

    /// Upserts a recovery row.  Uses `date` as the conflict key so a second
    /// sync on the same day merges rather than duplicates. Nil fields are
    /// skipped so partial updates (e.g. a manual weight entry) don't clobber
    /// unrelated columns already stored on that row.
    func saveRecovery(_ data: Recovery) async throws {
        var body: [String: Any] = ["date": data.date]

        if let v = data.sleepHours       { body["sleep_hours"] = v }
        if let v = data.hrv              { body["hrv"] = v }
        if let v = data.hrvStatus        { body["hrv_status"] = v }
        if let v = data.restingHr        { body["resting_hr"] = v }
        if let v = data.heartRate        { body["heart_rate"] = v }
        if let v = data.steps            { body["steps"] = v }
        if let v = data.activeEnergyKcal { body["active_energy_kcal"] = v }
        if let v = data.weightKg         { body["weight_kg"] = v }
        if let v = data.bodyFatPct       { body["body_fat_pct"] = v }
        if let v = data.exerciseMinutes  { body["exercise_minutes"] = v }
        if let v = data.respiratoryRate  { body["respiratory_rate"] = v }
        if let v = data.vo2Max           { body["vo2_max"] = v }

        try await client.upsert("recovery", body: body, onConflict: "date")
    }

    /// Upsert path used by HealthKit day-sync. Unlike `saveRecovery`, this
    /// version always sends `weight_kg` and `body_fat_pct` — explicitly NULL
    /// when the target day has no HealthKit sample — so a stale value left
    /// behind by a previous (unscoped) sync gets cleared instead of lingering
    /// forever. Other fields still respect the "only write non-nil" rule so
    /// an unrelated missing metric (e.g. an hour with no RHR yet) doesn't
    /// wipe a value that already landed earlier.
    func saveHealthKitSync(_ data: Recovery) async throws {
        var body: [String: Any] = ["date": data.date]

        if let v = data.sleepHours       { body["sleep_hours"] = v }
        if let v = data.hrv              { body["hrv"] = v }
        if let v = data.hrvStatus        { body["hrv_status"] = v }
        if let v = data.restingHr        { body["resting_hr"] = v }
        if let v = data.heartRate        { body["heart_rate"] = v }
        if let v = data.steps            { body["steps"] = v }
        if let v = data.activeEnergyKcal { body["active_energy_kcal"] = v }
        body["weight_kg"] = data.weightKg ?? NSNull()
        body["body_fat_pct"] = data.bodyFatPct ?? NSNull()
        if let v = data.exerciseMinutes  { body["exercise_minutes"] = v }
        if let v = data.respiratoryRate  { body["respiratory_rate"] = v }
        if let v = data.vo2Max           { body["vo2_max"] = v }

        try await client.upsert("recovery", body: body, onConflict: "date")
    }

    // MARK: - Date helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func todayString() -> String {
        dateFormatter.string(from: Date())
    }

    static func dateString(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return dateFormatter.string(from: date)
    }
}
