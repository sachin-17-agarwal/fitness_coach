// Config.swift
// FitnessCoach

import Foundation

struct Config {
    // MARK: - Supabase

    static var supabaseURL: String {
        ProcessInfo.processInfo.environment["SUPABASE_URL"]
            ?? UserDefaults.standard.string(forKey: "supabaseURL")
            ?? "https://your-project.supabase.co"
    }

    static var supabaseKey: String {
        ProcessInfo.processInfo.environment["SUPABASE_KEY"]
            ?? UserDefaults.standard.string(forKey: "supabaseKey")
            ?? "your-supabase-anon-key"
    }

    // MARK: - Backend (Railway)

    static var backendURL: String {
        ProcessInfo.processInfo.environment["BACKEND_URL"]
            ?? UserDefaults.standard.string(forKey: "backendURL")
            ?? "https://your-app.railway.app/api/chat"
    }

    static var appAPIToken: String {
        ProcessInfo.processInfo.environment["APP_API_TOKEN"]
            ?? UserDefaults.standard.string(forKey: "appAPIToken")
            ?? "your-bearer-token"
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
