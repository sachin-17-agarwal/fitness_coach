// WidgetPayload.swift
// Shared
//
// The widget's one read of GET /api/widget, as a Shared type so the app's
// unit tests decode it the way the widget does (S7, 25 Sep 2026): the
// payload has changed shape three times (strength, week line, stale flag)
// and each change went out untested. The widget's JSONDecoder uses
// convertFromSnakeCase; the test below does the same.

import Foundation

nonisolated struct WidgetStrength: Codable, Hashable, Sendable {
    let medianGainPct: Double?
    let lifts: Int?
}

nonisolated struct WidgetPayload: Codable, Hashable, Sendable {
    let date: String
    /// The date of the readings behind the score; `stale` when it is not
    /// today (a weigh-in wrote today's row before the Health export ran).
    let readDate: String?
    let stale: Bool?
    let score: Int?
    let level: String
    let verdict: String
    let sessionType: String
    let done: Bool
    let week: Int
    let day: Int
    let phase: String
    let hrv: Double?
    let hrvDelta: Int?
    let sleepHours: Double?
    let restingHr: Double?
    let rhrDelta: Int?
    let strength: WidgetStrength?
    /// This ISO week's finished sessions and tonnage, against last week's
    /// (computed on the server at each read, so it is fresh without the app).
    var weekSessions: Int? = nil
    var weekTonnageKg: Double? = nil
    var weekTonnageDeltaPct: Int? = nil

    static let sample = WidgetPayload(
        date: "2026-09-17", readDate: "2026-09-17", stale: false, score: 82, level: "green", verdict: "READY — PUSH TODAY",
        sessionType: "Push", done: false, week: 4, day: 2, phase: "DELOAD",
        hrv: 68, hrvDelta: 4, sleepHours: 7.33, restingHr: 52, rhrDelta: -1,
        strength: WidgetStrength(medianGainPct: 8.1, lifts: 11),
        weekSessions: 4, weekTonnageKg: 61240, weekTonnageDeltaPct: 6)

    /// "4 · 61.2t" — sessions this week and their tonnage.
    var weekLine: String? {
        guard let n = weekSessions, n > 0 else { return nil }
        if let t = weekTonnageKg, t > 0 { return "\(n) · \(String(format: "%.1f", t / 1000))t" }
        return "\(n)"
    }
}

