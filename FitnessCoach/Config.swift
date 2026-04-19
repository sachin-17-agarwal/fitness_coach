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

    /// The five-day rotation used in the mesocycle programme.
    static let cycle: [String] = [
        "Pull",
        "Push",
        "Legs",
        "Cardio+Abs",
        "Yoga",
    ]

    /// Number of days in one mesocycle rotation.
    static var cycleLength: Int { cycle.count }
}
