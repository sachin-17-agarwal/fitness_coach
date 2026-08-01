// Config.swift
// FitnessCoach

import Foundation

struct Config {
    // MARK: - Supabase

    static var supabaseURL: String {
        ProcessInfo.processInfo.environment["SUPABASE_URL"]
            ?? UserDefaults.standard.string(forKey: "supabaseURL")
            ?? "https://zdxbutbfthrozmpexjeg.supabase.co"
    }

    static var supabaseKey: String {
        ProcessInfo.processInfo.environment["SUPABASE_KEY"]
            ?? UserDefaults.standard.string(forKey: "supabaseKey")
            ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpkeGJ1dGJmdGhyb3ptcGV4amVnIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3Mjk5NzgyMCwiZXhwIjoyMDg4NTczODIwfQ.XpZ3G-_AiY7fcgXXNSLzaZX0O4P4GHlbAjUmUMadnXA"
    }

    // MARK: - Backend (Railway)

    static var backendURL: String {
        ProcessInfo.processInfo.environment["BACKEND_URL"]
            ?? UserDefaults.standard.string(forKey: "backendURL")
            ?? "https://fitnesscoach-production-257d.up.railway.app/api/chat"
    }

    static var appAPIToken: String {
        ProcessInfo.processInfo.environment["APP_API_TOKEN"]
            ?? UserDefaults.standard.string(forKey: "appAPIToken")
            ?? "5bc81352-256f-45cb-85c2-33679ab9dd99"
    }

    // MARK: - Mesocycle

    /// The resistance rotation. It rolls continuously — Cardio+Abs is followed
    /// straight back into Pull — and is NOT interrupted by yoga.
    /// Must match `CYCLE` in data.py.
    static let cycle: [String] = [
        "Pull",
        "Push",
        "Legs",
        "Cardio+Abs",
    ]

    /// Number of days in one mesocycle rotation.
    static var cycleLength: Int { cycle.count }

    /// Yoga is active recovery pinned to Sunday, not a rotation position. It
    /// used to be the fifth entry in `cycle`, which made it fire every fifth
    /// day and drift through the week; the athlete trains daily and takes yoga
    /// on Sunday whatever the rotation is showing. Sunday therefore OVERRIDES
    /// the session type without consuming a slot — a Saturday Pull is followed
    /// by a Monday Push, with the yoga day passing over the top.
    /// Mirrors `YOGA_WEEKDAY` / `is_yoga_day` in data.py.
    static let yogaSessionType = "Yoga"

    /// `Calendar` numbers weekdays from 1 = Sunday.
    static func isYogaDay(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.component(.weekday, from: date) == 1
    }

    /// Weeks in one mesocycle: baseline → volume → peak → deload, then the
    /// next cycle restarts at week 1. Must match the server's wrap in
    /// memory.py's advance_mesocycle.
    static let mesocycleWeeks = 4
}
