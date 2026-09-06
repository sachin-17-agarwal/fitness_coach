// SessionPlan.swift
// Vaux
//
// What each session type IS, at the level the home screen needs before the
// coach has prescribed anything: how many working sets, what it trains, how
// long the cardio block runs. These are programme design facts — the same
// standing as Config.cycle — and mirror the session templates in
// system_prompt.txt. They are not logged loads and must never carry one.

import Foundation

enum SessionPlan {
    /// Prescribed working-set count for a strength session.
    static func setCount(for type: String) -> Int? {
        switch type {
        case "Push": return 19
        case "Pull": return 16
        case "Legs": return 17
        default: return nil
        }
    }

    /// One-line preview shown under today's session title.
    static func preview(for type: String) -> String {
        switch type {
        case "Push": return "19 WORKING SETS · CHEST · SHOULDERS · TRICEPS"
        case "Pull": return "16 WORKING SETS · BACK · REAR DELTS · BICEPS"
        case "Legs": return "19 WORKING SETS · QUADS · HAMS · CALVES"
        case "Cardio+Abs": return "25–30 MIN ZONE 2 · 10 AB SETS · WEAK-POINT BLOCK"
        case "Yoga": return "ACTIVE RECOVERY · MOBILITY · NO LOADING"
        case "Rest": return "FULL REST · NO SESSION · ROTATION RESUMES TOMORROW"
        default: return type.uppercased()
        }
    }

    /// Compact form for the "tomorrow" card: "PULL · 16 SETS".
    static func shortLine(for type: String) -> String {
        if let sets = setCount(for: type) {
            return "\(type.uppercased()) · \(sets) SETS"
        }
        return type.uppercased()
    }
}
